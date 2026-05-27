// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapHelper
/// @notice Minimal V4 swap helper for testing HypersFunHook.
///
/// ── Why this is needed ─────────────────────────────────────────────────────
/// HypersFunHook's beforeSwap calls poolManager.take(inputToken, hook, amount).
/// pm.take() does a physical ERC20 transfer FROM PM to hook. This requires PM
/// to physically hold inputToken BEFORE the swap callback fires.
///
/// UniversalRouter's action order is [SWAP, SETTLE_ALL, TAKE_ALL] — SETTLE_ALL
/// (which deposits user tokens to PM) runs AFTER the swap. So PM has no tokens
/// when hook tries to take them.
///
/// FIX: Pre-deposit input tokens to PM BEFORE calling pm.swap:
///   1. sync(inputToken) → tell PM which currency is being settled
///   2. inputToken.transfer(PM, amount) → physical deposit
///   3. pm.settle() → PM credits +amount delta to SwapHelper
///   4. pm.swap() → hook's pm.take(inputToken) succeeds (PM has the tokens)
///   5. pm.swap's BalanceDelta includes BeforeSwapDelta's effect:
///      - SwapHelper's inputToken delta = +deposit - swapCharge = 0
///      - SwapHelper's outputToken delta = +outputAmount (to take)
///   6. pm.take(outputToken, recipient) → receive output tokens
///
/// ── Sell limitation ────────────────────────────────────────────────────────
/// The hook's sell has a design conflict:
///   a) pm.take(HFUND, hook, X)   — requires PM to hold X HFUND
///   b) vault.burnShares(seller, X) — burns X from seller's ERC20 balance
/// If we pre-deposit HFUND to PM (so a) works), the pre-depositor's balance
/// becomes 0, so b) fails. This needs a hook contract fix.
/// Current workaround: SELL via direct vault interaction (not V4 swap path).
contract SwapHelper is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    bool private _locked;

    struct CallbackData {
        PoolKey   key;
        bool      zeroForOne;    // true = sell c0 for c1
        uint256   amountIn;      // exact input amount
        address   inputToken;
        address   outputToken;
        address   recipient;
        bytes     hookData;
    }

    constructor(address poolManager_) {
        poolManager = IPoolManager(poolManager_);
    }

    // ─── Permit structs ───────────────────────────────────────────────────────

    struct PermitData {
        uint256 deadline;
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // ─── Buy (input = USDC, output = HFUND) ──────────────────────────────────

    /// @notice Swap inputToken → outputToken via V4 pool.
    /// @param key         V4 PoolKey (must match the hook's pool)
    /// @param zeroForOne  true = swap c0→c1; false = swap c1→c0
    /// @param amountIn    Exact input amount (in inputToken's decimals)
    /// @param inputToken  Token being sold
    /// @param outputToken Token being received
    /// @param minOut      Minimum output tokens (0 = no slippage protection for test)
    /// @param hookData    Optional: abi.encode(address actualUser, uint256 minOut)
    /// @param permit      Optional EIP-2612 permit (deadline=0 to skip)
    /// @return outputReceived Amount of outputToken sent to msg.sender
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        address inputToken,
        address outputToken,
        uint256 minOut,
        bytes calldata hookData,
        PermitData calldata permit
    ) external returns (uint256 outputReceived) {
        require(!_locked, "SwapHelper: reentrant");
        _locked = true;

        // Optional EIP-2612 permit (skipped if deadline == 0).
        // try/catch: if a front-runner submitted the same sig first (consuming the nonce),
        // the permit reverts but allowance is already set — safe to continue.
        if (permit.deadline > 0) {
            try IERC20Permit(inputToken).permit(
                msg.sender, address(this), type(uint256).max,
                permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }

        // Pull input tokens from caller
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amountIn);

        // Execute swap via PM unlock (unlockCallback handles pre-deposit + swap + take)
        bytes memory result = poolManager.unlock(abi.encode(CallbackData({
            key:         key,
            zeroForOne:  zeroForOne,
            amountIn:    amountIn,
            inputToken:  inputToken,
            outputToken: outputToken,
            recipient:   msg.sender,
            hookData:    hookData
        })));

        outputReceived = abi.decode(result, (uint256));
        require(outputReceived >= minOut, "SwapHelper: insufficient output");

        _locked = false;
    }

    // ─── V4 Unlock Callback ───────────────────────────────────────────────────

    /// @notice PM calls this within unlock(). Handles pre-deposit → swap → take.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "SwapHelper: not PM");
        CallbackData memory d = abi.decode(data, (CallbackData));

        // ── Step 1: Pre-deposit input tokens to PM ─────────────────────────────
        //
        // HypersFunHook's beforeSwap calls pm.take(inputToken, hook, amount).
        // pm.take() physically transfers ERC20 from PM to hook, so PM must have
        // the tokens BEFORE pm.swap() is called.
        //
        // V4 settle pattern: sync(currency) → transfer(PM, amount) → settle()
        //   - sync() marks which currency is being settled (stores in transient slot)
        //   - settle() computes PM's balance increase since last sync, credits delta
        poolManager.sync(Currency.wrap(d.inputToken));
        IERC20(d.inputToken).safeTransfer(address(poolManager), d.amountIn);
        poolManager.settle(); // SwapHelper delta: inputToken += +amountIn

        // ── Step 2: Execute V4 swap ─────────────────────────────────────────────
        //
        // Pool calls hook.beforeSwap, which:
        //   - pm.take(inputToken, hook, amountIn) → works! PM has tokens from step 1
        //   - Routes tokens to vault/treasury, mints output tokens
        //   - Returns BeforeSwapDelta(+amountIn, -outputAmount)
        //
        // PM applies BeforeSwapDelta to the locker's BalanceDelta:
        //   swapDelta_for_locker = pool_delta(0,0) - hookDelta
        //   = (0,0) - hookDelta
        //
        // Where hookDelta depends on zeroForOne:
        //   zeroForOne=false (USDC→HFUND, USDC=c1):
        //     hookDelta.c0 = hookDeltaUnspecified = -outputAmount
        //     hookDelta.c1 = hookDeltaSpecified   = +amountIn
        //     swapDelta = (0-(-out), 0-(+amountIn)) = (+out, -amountIn)
        //     → locker delta: c0(HFUND) = +out (take), c1(USDC) = -amountIn (pay)
        //
        // Combined with step 1 (locker settled +amountIn USDC):
        //   locker USDC delta = +amountIn + (-amountIn) = 0 ✓
        //   locker HFUND delta = +outputAmount (must take)
        uint160 sqrtPriceLimit = d.zeroForOne
            ? uint160(4295128740)                                         // near MIN_SQRT_PRICE
            : uint160(1461446703485210103287273052203988822378723970341); // near MAX_SQRT_PRICE

        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne:        d.zeroForOne,
                amountSpecified:   -int256(d.amountIn), // exact input (negative)
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            d.hookData
        );

        // ── Step 3: Take output tokens ─────────────────────────────────────────
        //
        // After BeforeSwapDelta accounting, locker has positive delta for output:
        //   zeroForOne=false: delta.amount0() = +outputAmount (HFUND, c0)
        //   zeroForOne=true:  delta.amount1() = +outputAmount (c1)
        //
        // Take from PM to recipient.
        int128 rawOutput = d.zeroForOne ? delta.amount1() : delta.amount0();

        uint256 outputAmount = 0;
        if (rawOutput > 0) {
            // Positive delta = PM credits us with this much output
            outputAmount = uint128(rawOutput);
            poolManager.take(Currency.wrap(d.outputToken), d.recipient, outputAmount);
        }
        // If rawOutput <= 0: hook may have returned 0 (e.g., BelowMinDeposit revert,
        // TxTooLarge, etc.) — no tokens to take, outputAmount = 0.

        // ── Partial-fill refund (cap-bounded buy near maxSupply) ──────────────
        // If the hook only consumed part of the input (e.g. the buy was capped at
        // maxSupply), the hook returns a BeforeSwapDelta with a smaller specified
        // amount than amountIn. The remaining input is still credited to this
        // contract in PM (from the pre-settle above). Reclaim it for the recipient.
        //
        // inputDelta from the swap = -(amount hook consumed).
        // amountIn (pre-settled) + inputDelta = refund ≥ 0.
        {
            int128 inputDelta = d.zeroForOne ? delta.amount0() : delta.amount1();
            int256 refund = int256(d.amountIn) + int256(inputDelta);
            if (refund > 0) {
                poolManager.take(Currency.wrap(d.inputToken), d.recipient, uint256(refund));
            }
        }

        return abi.encode(outputAmount);
    }

    // ─── Convenience wrappers ─────────────────────────────────────────────────

    /// @notice Buy HFUND with USDC.
    /// @dev Determines zeroForOne automatically from pool key sorting.
    /// @param permit Optional EIP-2612 permit for USDC (deadline=0 to skip)
    function buyHFUND(
        PoolKey calldata key,
        address usdc,
        address hfund,
        uint256 usdcAmount,
        uint256 minHfundOut,
        bytes calldata hookData,
        PermitData calldata permit
    ) external returns (uint256 hfundReceived) {
        require(!_locked, "SwapHelper: reentrant");
        _locked = true;

        bool zeroForOne = usdc == Currency.unwrap(key.currency0);

        // Optional EIP-2612 permit (skipped if deadline == 0).
        // try/catch: defuses permit front-run DoS — if nonce was consumed by a front-runner,
        // allowance is already set and the transferFrom below will still succeed.
        if (permit.deadline > 0) {
            try IERC20Permit(usdc).permit(
                msg.sender, address(this), type(uint256).max,
                permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        bytes memory result = poolManager.unlock(abi.encode(CallbackData({
            key:         key,
            zeroForOne:  zeroForOne,
            amountIn:    usdcAmount,
            inputToken:  usdc,
            outputToken: hfund,
            recipient:   msg.sender,
            hookData:    hookData
        })));

        hfundReceived = abi.decode(result, (uint256));
        require(hfundReceived >= minHfundOut, "SwapHelper: slippage");
        _locked = false;
    }

    // ─── Emergency recovery ───────────────────────────────────────────────────

    /// @notice Recover any accidentally stuck tokens.
    function rescueToken(address token, address to) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
    }
}
