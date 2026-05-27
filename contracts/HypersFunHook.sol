// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FundVault} from "./FundVault.sol";
import {HyperFunMath} from "./HyperFunMath.sol";

/// @title HypersFunHook
/// @notice Uniswap V4 Hook — NAV-anchored tokenized-fund market on X Layer.
///
/// ┌─ Hook-as-AMM ─────────────────────────────────────────────────────────┐
/// │  Every FUND/USDC swap is fully handled here; no native CLMM used.    │
/// │                                                                        │
/// │  Buy  (USDC → FUND)                                                   │
/// │    1. Deduct trading fee (→ treasury)                                  │
/// │    2. Bonding curve: tokensOut = f(netUsdcIn, curveBase, curveTokens) │
/// │    3. Update curveBase / curveTokens in storage (persist state)       │
/// │    4. pm.take(USDC → vault); mintFUND; settle FUND to PM              │
/// │                                                                        │
/// │  Sell (FUND → USDC)                                                   │
/// │    1. Bonding curve: grossUsdcOut = f(tokensIn, curveBase, curveTokens│
/// │    2. Apply NAV ceiling (2% above NAV, globalMaxSellPremiumBps)       │
/// │    3. Deduct exit fee (stays in vault → increases remaining NAV)      │
/// │    4. Deduct trading fee (→ treasury)                                  │
/// │    5. Update curveBase / curveTokens in storage                       │
/// │    6. pm.take(FUND → hook); burn; vault sends netUsdc to PM           │
/// └───────────────────────────────────────────────────────────────────────┘
///
/// Critical V3 features ported:
///   ✓ Trading fee (tradingFeeBps, default 1%)
///   ✓ Performance fee (minted by FundVault.burnShares)
///   ✓ Exit fee tiers (time-based, calculated by FundVault)
///   ✓ Persistent curveBase/curveTokens (state updates every swap)
///   ✓ NAV ceiling on sell (maxSellPremiumBps, default 2%)
///   ✓ Max BC ratio cap (curveBase/curveTokens ≤ maxBcRatioBps)
///   ✓ Ratio floor (curveBase/curveTokens ≥ 1.0 after sell)
///   ✓ TWAP NAV (FundVault.getSmoothedNAV used on buys)
///   ✓ Reentrancy guard
///   ✓ Pause mechanism
///   ✓ Min deposit check
///   ✓ Slippage protection (minOut via hookData)
///   ✓ Seller identified via hookData (abi.encode(actualSeller, minOut))
contract HypersFunHook is BaseHook {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ─── Linked vault ────────────────────────────────────────────────────────
    FundVault public immutable vault;
    address   public immutable usdc;

    // ─── Persistent bonding-curve state ──────────────────────────────────────
    // These mirror V3's virtualBase / virtualTokens (updated every swap).
    // curveBase   = virtual USDC reserve in NAV-normalised units (1e18)
    // curveTokens = virtual FUND reserve (1e18)
    uint256 public curveBase;
    uint256 public curveTokens;

    // ─── Fee & pricing parameters ─────────────────────────────────────────────
    uint256 public tradingFeeBps;    // Platform trading fee (default 100 = 1%)
    uint256 public maxPremiumBps;    // Max buy price above NAV (default 20000 = 2×)
    uint256 public maxDiscountBps;   // Max sell price below NAV (default 5000 = 0.5×)
    uint256 public maxSellPremiumBps;// NAV ceiling on sell output (default 200 = 2%)
    uint256 public maxBcRatioBps;    // Max curveBase/curveTokens ratio (default 18000=1.8×)
    uint256 public maxTxBps;         // Max single-tx as % of vault NAV (default 100 = 1%)
    uint256 public minDepositUsdc6;  // Min deposit in USDC 6-decimal (default 5 USDC)
    address public treasury;         // Receives trading fees

    // ─── Pool config ──────────────────────────────────────────────────────────
    bool private _poolInitialized;
    bool private _usdcIsCurrency0;  // true if USDC address < FUND address (sorted lower)

    // ─── Pause & reentrancy ───────────────────────────────────────────────────
    bool public paused;
    uint256 private _swapLock; // simple reentrancy lock for beforeSwap

    // ─── Admin ────────────────────────────────────────────────────────────────
    address public owner;

    // ─── Anti-snipe & fair-curve tracking (from Sato pattern) ────────────────
    /// @notice Block number at hook deployment. Entropy window runs for ENTROPY_BLOCKS after this.
    uint256 public immutable GENESIS_BLOCK;

    /// @notice Blocks after genesis during which buys receive ±10% entropy randomness.
    uint256 public constant ENTROPY_BLOCKS = 100;

    /// @notice Minimum blocks between an address's last buy and its first sell.
    uint256 public constant COOLDOWN_BLOCKS = 1;

    /// @notice Cumulative "fair-curve" tokens minted through the bonding curve only.
    ///         Excludes entropy bonuses and performance-fee mints, so sell pricing
    ///         is always proportional to what was actually paid into the curve.
    uint256 public totalMintedFair;

    /// @notice True once 99% of vault.maxSupply() has been curve-minted. Buys blocked after this.
    bool public selfDeprecated;

    /// @notice Last block in which each address executed a buy.
    mapping(address => uint256) public lastBuyBlock;

    // ─── Events ───────────────────────────────────────────────────────────────
    event FundBuy(
        address indexed buyer,
        uint256 usdcGrossIn,
        uint256 tradingFee6,
        uint256 fundOut,
        uint256 navAtSwap,
        uint256 priceImpactBps
    );
    event FundSell(
        address indexed seller,
        uint256 fundIn,
        uint256 usdcGrossOut,
        uint256 exitFee6,
        uint256 tradingFee6,
        uint256 usdcNetOut,
        uint256 navAtSwap,
        uint256 priceImpactBps
    );
    event CurveStateUpdated(uint256 curveBase, uint256 curveTokens);
    event SelfDeprecatedTriggered();
    event ParamsUpdated(
        uint256 tradingFeeBps,
        uint256 maxPremiumBps,
        uint256 maxDiscountBps,
        uint256 maxSellPremiumBps,
        uint256 maxBcRatioBps,
        uint256 maxTxBps,
        uint256 minDepositUsdc6
    );

    // ─── Errors ───────────────────────────────────────────────────────────────
    error WrongTokenPair();
    error AlreadyInitialized();
    error NoExternalLiquidity();
    error ContractPaused();
    error ReentrancyLocked();
    error TxTooLarge();
    error BelowMinDeposit();
    error InsufficientOutput();
    error ZeroSwap();
    error OnlyOwner();
    error ExactOutputNotSupported();
    error SelfDeprecated();
    error CooldownActive();

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param poolManager_  Uniswap V4 PoolManager on X Layer (chain 196).
    ///                      Look up address at docs.uniswap.org/contracts/v4/deployments
    /// @param vault_        FundVault (the FUND ERC20 + asset manager)
    /// @param usdc_         USDC address on X Layer
    /// @param treasury_     Address that receives trading fees
    /// @param owner_        Owner / fund manager (explicit — supports CREATE2 deploy via factory)
    constructor(
        IPoolManager poolManager_,
        FundVault    vault_,
        address      usdc_,
        address      treasury_,
        address      owner_
    ) BaseHook(poolManager_) {
        vault        = vault_;
        usdc         = usdc_;
        treasury     = treasury_ != address(0) ? treasury_ : owner_;
        owner        = owner_ != address(0) ? owner_ : msg.sender;
        GENESIS_BLOCK = block.number;

        // Default parameters (matching V3 Factory defaults where applicable)
        tradingFeeBps     = 100;    // 1%
        maxPremiumBps     = 20_000; // 2× NAV ceiling for buys
        maxDiscountBps    = 5_000;  // 0.5× NAV floor for sells
        maxSellPremiumBps = 200;    // V3 globalMaxSellPremiumBps = 2% ceiling above NAV
        maxBcRatioBps     = 18_000; // V3 globalMaxBcRatioBps = 1.8× ratio cap
        maxTxBps          = 100;    // 1% of vault NAV per trade
        minDepositUsdc6   = 100_000; // 0.1 USDC minimum

        // curveBase/curveTokens initialised in initializeCurve() after vault seed deposit
    }

    // ─── Hook permissions ────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                true,
            afterInitialize:                 false,
            beforeAddLiquidity:              true,   // block external LP
            afterAddLiquidity:               false,
            beforeRemoveLiquidity:           true,   // block external LP removal
            afterRemoveLiquidity:            false,
            beforeSwap:                      true,   // ★ NAV-anchored AMM
            afterSwap:                       true,   // TWAP update + events
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           true,   // hook fully controls swap output
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── beforeInitialize ────────────────────────────────────────────────────

    /// @notice Validate that the pool is FUND/USDC (sorted either way).
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        if (_poolInitialized) revert AlreadyInitialized();

        address c0   = Currency.unwrap(key.currency0);
        address c1   = Currency.unwrap(key.currency1);
        address fund = address(vault);

        bool valid = (c0 == usdc && c1 == fund) || (c0 == fund && c1 == usdc);
        if (!valid) revert WrongTokenPair();

        _usdcIsCurrency0 = (c0 == usdc);
        _poolInitialized  = true;

        return IHooks.beforeInitialize.selector;
    }

    // ─── Block external liquidity ────────────────────────────────────────────

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert NoExternalLiquidity(); }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert NoExternalLiquidity(); }

    // ─── beforeSwap ★ ────────────────────────────────────────────────────────

    /// @notice Full NAV-anchored AMM swap.
    ///
    ///         hookData encoding (optional, used for slippage + exit fee):
    ///           abi.encode(address actualUser, uint256 minOut)
    ///           actualUser: real investor (vs router address as `sender`)
    ///           minOut:     minimum tokens/USDC out (slippage protection)
    ///
    ///         Curve state (curveBase, curveTokens) is UPDATED here (not in afterSwap)
    ///         so the state is consistent even if afterSwap is skipped.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {

        if (paused)        revert ContractPaused();
        if (_swapLock > 0) revert ReentrancyLocked();
        _swapLock = 1;

        // V4: amountSpecified < 0 = exact input; > 0 = exact output
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn == 0) { _swapLock = 0; revert ZeroSwap(); }

        // Decode hookData for actual user + slippage (both optional)
        address actualUser = sender;
        uint256 minOut     = 0;
        if (hookData.length >= 64) {
            (actualUser, minOut) = abi.decode(hookData, (address, uint256));
            if (actualUser == address(0)) actualUser = sender;
        }

        // Direction: zeroForOne ^ usdcIsCurrency0
        // If USDC is currency0:  zeroForOne=true  → USDC→FUND (buy)
        // If USDC is currency1:  zeroForOne=false → USDC→FUND (buy)
        bool isBuy = (params.zeroForOne == _usdcIsCurrency0);

        Currency usdcCurrency = _usdcIsCurrency0 ? key.currency0 : key.currency1;
        Currency fundCurrency = _usdcIsCurrency0 ? key.currency1 : key.currency0;

        BeforeSwapDelta delta;

        if (isBuy) {
            delta = _handleBuy(
                key, usdcCurrency, fundCurrency,
                amountIn, actualUser, minOut
            );
        } else {
            delta = _handleSell(
                key, usdcCurrency, fundCurrency,
                amountIn, actualUser, minOut
            );
        }

        _swapLock = 0;
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    // ─── Buy implementation ───────────────────────────────────────────────────

    function _handleBuy(
        PoolKey calldata,
        Currency usdcCurrency,
        Currency fundCurrency,
        uint256 usdcGrossIn,   // 6-decimal
        address buyer,
        uint256 minFundOut
    ) internal returns (BeforeSwapDelta) {

        // ── 0. Self-deprecation guard ─────────────────────────────────────────
        if (selfDeprecated) revert SelfDeprecated();

        // ── 1. Min deposit check ──────────────────────────────────────────────
        if (usdcGrossIn < minDepositUsdc6) revert BelowMinDeposit();

        // ── 2. Per-tx cap ─────────────────────────────────────────────────────
        uint256 totalNav = vault.totalNAV(); // 1e18
        uint256 cap6 = (totalNav * maxTxBps / HyperFunMath.BPS) / 1e12;
        if (cap6 > 0 && usdcGrossIn > cap6) revert TxTooLarge();

        // ── 3. Trading fee ────────────────────────────────────────────────────
        uint256 tradingFee6  = (usdcGrossIn * tradingFeeBps) / HyperFunMath.BPS;
        uint256 netUsdcIn6   = usdcGrossIn - tradingFee6;

        // ── 4. NAV (TWAP-smoothed for buy — prevents liquidation spike exploit) ─
        uint256 nav = vault.getSmoothedNAV();

        // ── 5. Bonding curve → fair token amount ──────────────────────────────
        uint256 currentBuyP = HyperFunMath.getBuyPrice(nav, curveBase, curveTokens);

        (uint256 fairTokensOut, , uint256 impact) = HyperFunMath.calculateTokensOutPure(
            netUsdcIn6, nav, curveBase, curveTokens, maxPremiumBps, currentBuyP
        );
        if (fairTokensOut == 0) { _swapLock = 0; revert InsufficientOutput(); }

        // ── 5b. Cap-bounded buy: clamp to remaining supply & refund excess USDC ─
        // If this buy would exceed maxSupply, cap fairTokensOut to the remaining
        // supply and back-calculate the exact USDC needed. The caller receives a
        // partial refund for the unconsummed USDC (via SwapHelper's refund path).
        {
            uint256 maxSup = vault.maxSupply();
            if (maxSup > 0 && totalMintedFair + fairTokensOut > maxSup) {
                uint256 remaining = maxSup > totalMintedFair ? maxSup - totalMintedFair : 0;
                if (remaining == 0) { _swapLock = 0; revert SelfDeprecated(); }

                // Back-calculate net USDC for the capped amount (ceiling division for gross)
                uint256 cappedNetUsdc6   = HyperFunMath.backCalcNetUsdcForTokens(
                    remaining, nav, curveBase, curveTokens
                );
                // gross = net * BPS / (BPS - fee), ceiling to avoid rounding deficit
                uint256 cappedGrossUsdc6 = (cappedNetUsdc6 * HyperFunMath.BPS + (HyperFunMath.BPS - tradingFeeBps) - 1)
                                           / (HyperFunMath.BPS - tradingFeeBps);

                // Recalculate all USDC-related locals with the capped values
                fairTokensOut = remaining;
                netUsdcIn6    = cappedNetUsdc6;
                tradingFee6   = cappedGrossUsdc6 - cappedNetUsdc6;
                usdcGrossIn   = cappedGrossUsdc6; // remainder is refunded to buyer by SwapHelper
            }
        }

        // ── 5d. Entropy multiplier (first ENTROPY_BLOCKS: ±10% randomness) ────
        // Curve state is updated with fairTokensOut; buyer receives mintAmount.
        // Discourages bots from sniping precise arbitrage at launch.
        uint256 mintAmount = _applyEntropy(fairTokensOut, buyer, usdcGrossIn);

        if (minFundOut > 0 && mintAmount < minFundOut) { _swapLock = 0; revert InsufficientOutput(); }

        // ── 6. Update curve state with FAIR amount (not entropy-adjusted) ─────
        (uint256 newBase, uint256 newTokens) = HyperFunMath.updateCurveAfterBuy(
            curveBase, curveTokens, nav, netUsdcIn6, fairTokensOut, maxBcRatioBps
        );
        curveBase   = newBase;
        curveTokens = newTokens;

        // ── 6b. Update fair-curve tracker & cooldown ──────────────────────────
        totalMintedFair += fairTokensOut;
        lastBuyBlock[buyer] = block.number;

        // ── 6c. Self-deprecation check (99% of maxSupply minted via curve) ────
        {
            uint256 maxSup = vault.maxSupply();
            if (maxSup > 0 && totalMintedFair * 100 >= maxSup * 99) {
                selfDeprecated = true;
                emit SelfDeprecatedTriggered();
            }
        }

        // ── 7. Physical settlement ────────────────────────────────────────────
        // ① Pull gross USDC from PM → hook
        poolManager.take(usdcCurrency, address(this), usdcGrossIn);
        // ② Send trading fee to treasury
        if (tradingFee6 > 0) {
            IERC20(usdc).safeTransfer(treasury, tradingFee6);
        }
        // ③ Send net USDC to vault
        IERC20(usdc).safeTransfer(address(vault), netUsdcIn6);
        // ③.5 Auto-deploy into active mode (short/long) if governance voted a direction
        try vault.autoDeployCapital(netUsdcIn6) {} catch {}
        // ④ Vault mints FUND to hook (tracked for actual buyer, not hook)
        vault.mintShares(address(this), buyer, mintAmount);
        // ⑤ Hook settles FUND to PM (PM will give to router → buyer)
        poolManager.sync(fundCurrency);
        IERC20(Currency.unwrap(fundCurrency)).transfer(address(poolManager), mintAmount);
        poolManager.settle();

        emit FundBuy(buyer, usdcGrossIn, tradingFee6, mintAmount, nav, impact);

        // Delta: hook consumed usdcGrossIn of specified (USDC), provided mintAmount of unspecified (FUND)
        return toBeforeSwapDelta(
            int128(int256(usdcGrossIn)),
            -int128(int256(mintAmount))
        );
    }

    // ─── Sell implementation ──────────────────────────────────────────────────

    function _handleSell(
        PoolKey calldata,
        Currency usdcCurrency,
        Currency fundCurrency,
        uint256 tokensIn,     // FUND (1e18)
        address seller,
        uint256 minUsdcOut
    ) internal returns (BeforeSwapDelta) {

        if (tokensIn == 0) { _swapLock = 0; revert ZeroSwap(); }

        // ── 0. Same-block cooldown (anti-sandwich) ────────────────────────────
        {
            uint256 lb = lastBuyBlock[seller];
            if (lb != 0 && block.number - lb < COOLDOWN_BLOCKS) revert CooldownActive();
        }

        // ── 1. Per-tx cap ─────────────────────────────────────────────────────
        uint256 totalNav = vault.totalNAV();
        uint256 nav      = vault.navPerShare(); // instant NAV for sell (V3 logic)
        uint256 capTokens = (totalNav * maxTxBps / HyperFunMath.BPS) * HyperFunMath.PRECISION / nav;
        if (capTokens > 0 && tokensIn > capTokens) revert TxTooLarge();

        // ── 1b. Fair-curve adjustment ─────────────────────────────────────────
        // Converts actual token amount into the canonical curve position, excluding
        // entropy bonuses and perf-fee mints from the sell pricing.
        uint256 actualSupply = vault.totalSupply();
        uint256 fairIn = (totalMintedFair > 0 && actualSupply > 0)
            ? (tokensIn * totalMintedFair) / actualSupply
            : tokensIn;
        if (fairIn == 0) fairIn = tokensIn; // guard: fallback to actual if ratio is tiny

        // ── 2. Bonding curve (gross USDC out, priced on fairIn) ───────────────
        (uint256 grossUsdcOut6, , uint256 impact) = HyperFunMath.calculateUsdcOutPure(
            fairIn, nav, curveBase, curveTokens, maxDiscountBps
        );

        // ── 3. NAV ceiling (V3 globalMaxSellPremiumBps = 2%) ─────────────────
        // Prevents sell price > NAV × (1 + maxSellPremiumBps/BPS)
        {
            uint256 ceiling18 = (tokensIn * nav * (HyperFunMath.BPS + maxSellPremiumBps)) /
                                 (HyperFunMath.BPS * HyperFunMath.PRECISION);
            uint256 gross18 = grossUsdcOut6 * 1e12;
            if (gross18 > ceiling18) {
                grossUsdcOut6 = ceiling18 / 1e12;
            }
        }

        // ── 4. Exit fee (time-based, stays in vault) ──────────────────────────
        (uint256 exitFeeBps, ) = vault.calculateExitFee(seller);
        uint256 exitFee6       = (grossUsdcOut6 * exitFeeBps) / HyperFunMath.BPS;
        uint256 afterExitFee6  = grossUsdcOut6 - exitFee6;

        // ── 5. Trading fee ────────────────────────────────────────────────────
        uint256 tradingFee6  = (afterExitFee6 * tradingFeeBps) / HyperFunMath.BPS;
        uint256 netUsdcOut6  = afterExitFee6 - tradingFee6;

        if (netUsdcOut6 == 0) { _swapLock = 0; revert InsufficientOutput(); }
        if (minUsdcOut > 0 && netUsdcOut6 < minUsdcOut) { _swapLock = 0; revert InsufficientOutput(); }

        // ── 6. Update curve state with fairIn (V3: BC uses afterExitFee, not gross) ─
        (uint256 newBase, uint256 newTokens) = HyperFunMath.updateCurveAfterSell(
            curveBase, curveTokens, nav, afterExitFee6, fairIn
        );
        curveBase   = newBase;
        curveTokens = newTokens;

        // ── 6b. Update fair-curve tracker ────────────────────────────────────
        totalMintedFair = totalMintedFair >= fairIn ? totalMintedFair - fairIn : 0;

        // ── 7. Physical settlement ────────────────────────────────────────────
        // ① Pull FUND from PM → hook
        poolManager.take(fundCurrency, address(this), tokensIn);
        // ② Burn FUND — hook holds tokens (received via pm.take); track fees for seller
        vault.burnSharesFrom(seller, tokensIn);
        // ③ Vault sends afterExitFee USDC to hook.
        //    If vault USDC is insufficient (capital deployed), auto-unwinds positions atomically.
        vault.ensureLiquidityAndSend(address(this), afterExitFee6);
        // ④ Send trading fee to treasury
        if (tradingFee6 > 0) {
            IERC20(usdc).safeTransfer(treasury, tradingFee6);
        }
        // ⑤ Send netUsdcOut to PM + settle (router will take for seller)
        poolManager.sync(usdcCurrency); // must sync before settle
        IERC20(usdc).safeTransfer(address(poolManager), netUsdcOut6);
        poolManager.settle();

        if (exitFee6 > 0) {
            emit FundSell(seller, tokensIn, grossUsdcOut6, exitFee6, tradingFee6, netUsdcOut6, nav, impact);
        } else {
            emit FundSell(seller, tokensIn, grossUsdcOut6, 0, tradingFee6, netUsdcOut6, nav, impact);
        }

        // Delta: hook consumed tokensIn FUND, provided netUsdcOut6 USDC
        return toBeforeSwapDelta(
            int128(int256(tokensIn)),
            -int128(int256(netUsdcOut6))
        );
    }

    // ─── afterSwap ───────────────────────────────────────────────────────────

    /// @notice Update TWAP NAV after each swap.
    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Update vault's TWAP NAV (mirrors V3 _updateTwapNav)
        vault.updateTwapNav();
        emit CurveStateUpdated(curveBase, curveTokens);
        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Curve initialisation ─────────────────────────────────────────────────

    /// @notice Initialise curveBase and curveTokens after vault seed deposit.
    ///         Call once: after vault.depositUsdc() and before any investor buys.
    ///         Mirrors V3's defaultBcVirtualBase / defaultBcVirtualTokens.
    /// @param initialBase   Virtual USDC depth (1e18) — e.g. 2_000_000 * 1e18
    /// @param initialTokens Virtual FUND depth (1e18) — e.g. 2_000_000 * 1e18
    function initializeCurve(uint256 initialBase, uint256 initialTokens) external onlyOwner {
        require(initialBase > 0 && initialTokens > 0, "Hook: zero reserves");
        curveBase   = initialBase;
        curveTokens = initialTokens;
        // Seed the fair-curve counter with the vault's current supply (the leader's seed deposit).
        // This ensures sells of seed tokens are correctly priced without distorting the ratio.
        if (totalMintedFair == 0) totalMintedFair = vault.totalSupply();
        emit CurveStateUpdated(initialBase, initialTokens);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function setParams(
        uint256 tradingFeeBps_,
        uint256 maxPremiumBps_,
        uint256 maxDiscountBps_,
        uint256 maxSellPremiumBps_,
        uint256 maxBcRatioBps_,
        uint256 maxTxBps_,
        uint256 minDepositUsdc6_
    ) external onlyOwner {
        require(tradingFeeBps_     <= 500,    "Hook: fee max 5%");
        require(maxPremiumBps_     <= 100_000,"Hook: premium too high");
        require(maxDiscountBps_    <= 10_000, "Hook: discount > 100%");
        require(maxSellPremiumBps_ <= 2_000,  "Hook: sell ceiling max 20%");
        require(maxBcRatioBps_ == 0 || (maxBcRatioBps_ >= 10_000 && maxBcRatioBps_ <= 50_000), "Hook: bcRatio");
        require(maxTxBps_          <= 1_000,  "Hook: cap max 10%");
        require(minDepositUsdc6_   >= 100_000, "Hook: min 0.1 USDC");

        tradingFeeBps     = tradingFeeBps_;
        maxPremiumBps     = maxPremiumBps_;
        maxDiscountBps    = maxDiscountBps_;
        maxSellPremiumBps = maxSellPremiumBps_;
        maxBcRatioBps     = maxBcRatioBps_;
        maxTxBps          = maxTxBps_;
        minDepositUsdc6   = minDepositUsdc6_;

        emit ParamsUpdated(
            tradingFeeBps_, maxPremiumBps_, maxDiscountBps_,
            maxSellPremiumBps_, maxBcRatioBps_, maxTxBps_, minDepositUsdc6_
        );
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "Hook: zero");
        treasury = treasury_;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
    }

    function transferOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @notice Apply ±10% entropy randomness during the launch window (ENTROPY_BLOCKS).
    ///         Uses blockhash + buyer address + input amount as entropy source.
    ///         After ENTROPY_BLOCKS, returns fairTokens unchanged.
    function _applyEntropy(uint256 fairTokens, address buyer, uint256 usdcIn)
        internal view returns (uint256)
    {
        if (block.number >= GENESIS_BLOCK + ENTROPY_BLOCKS) return fairTokens;
        bytes32 h = keccak256(abi.encodePacked(blockhash(block.number - 1), buyer, usdcIn));
        uint256 mul = 9_000 + (uint256(h) % 2_001); // 9000..11000 → 0.9x to 1.1x
        return (fairTokens * mul) / 10_000;
    }

    // ─── View helpers (same as V3's calculateTokensOut / calculateUsdcOut) ────

    /// @notice Preview: FUND out for a USDC buy (gross amount, before slippage limit).
    function quoteBuy(uint256 usdcGrossIn6)
        external view
        returns (uint256 tokensOut, uint256 tradingFee6, uint256 newPrice)
    {
        uint256 fee6    = (usdcGrossIn6 * tradingFeeBps) / HyperFunMath.BPS;
        uint256 netIn6  = usdcGrossIn6 - fee6;
        uint256 nav     = vault.getSmoothedNAV();
        uint256 curBuyP = HyperFunMath.getBuyPrice(nav, curveBase, curveTokens);
        (tokensOut, newPrice, ) = HyperFunMath.calculateTokensOutPure(
            netIn6, nav, curveBase, curveTokens, maxPremiumBps, curBuyP
        );
        tradingFee6 = fee6;
    }

    /// @notice Preview: USDC out for a FUND sell (net, after all fees).
    function quoteSell(uint256 fundIn)
        external view
        returns (uint256 usdcNetOut6, uint256 exitFee6, uint256 tradingFee6, uint256 newPrice)
    {
        uint256 nav = vault.navPerShare();
        (uint256 grossUsdcOut6, , ) = HyperFunMath.calculateUsdcOutPure(
            fundIn, nav, curveBase, curveTokens, maxDiscountBps
        );
        // NAV ceiling
        uint256 ceiling18 = (fundIn * nav * (HyperFunMath.BPS + maxSellPremiumBps)) /
                             (HyperFunMath.BPS * HyperFunMath.PRECISION);
        if (grossUsdcOut6 * 1e12 > ceiling18) grossUsdcOut6 = ceiling18 / 1e12;

        (uint256 eFeeBps, ) = vault.calculateExitFee(msg.sender);
        exitFee6      = (grossUsdcOut6 * eFeeBps)   / HyperFunMath.BPS;
        uint256 afterExitFee = grossUsdcOut6 - exitFee6;
        tradingFee6   = (afterExitFee * tradingFeeBps)       / HyperFunMath.BPS;
        usdcNetOut6   = afterExitFee - tradingFee6;

        (, newPrice, ) = HyperFunMath.calculateUsdcOutPure(
            fundIn, nav, curveBase, curveTokens, maxDiscountBps
        );
    }

    /// @notice Current buy price (1e18 USDC per FUND).
    function currentBuyPrice() external view returns (uint256) {
        return HyperFunMath.getBuyPrice(vault.getSmoothedNAV(), curveBase, curveTokens);
    }

    /// @notice Current NAV per share (instant, 1e18).
    function currentNav() external view returns (uint256) {
        return vault.navPerShare();
    }

    /// @notice Current curve ratio (curveBase/curveTokens in BPS).
    function currentCurveRatioBps() external view returns (uint256) {
        if (curveTokens == 0) return 0;
        return (curveBase * HyperFunMath.BPS) / curveTokens;
    }
}
