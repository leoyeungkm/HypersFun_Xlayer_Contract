// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HyperFunMath} from "./HyperFunMath.sol";

// ─── External protocol interfaces ─────────────────────────────────────────────

/// @dev Minimal Uniswap V3 SwapRouter02 interface (no deadline in params struct)
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    struct ExactInputParams {
        bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum;
    }
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256);
    function exactInput(ExactInputParams calldata p) external returns (uint256);
    function exactOutputSingle(ExactOutputSingleParams calldata p) external returns (uint256);
}

/// @dev Minimal Aave V3 Pool interface
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @dev Minimal Uniswap V3 pool interface for NAV price reads
interface IUniswapV3PoolSlot0 {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8 feeProtocol, bool unlocked
    );
}

/// @title FundVault
/// @notice ERC20 fund-share token for HypersFun on X Layer.
///
/// ┌─ What this replaces from V3 ───────────────────────────────────────────┐
/// │  HyperFunToken  → fund share ERC20 + bonding curve (now in Hook)       │
/// │  HyperFunTrading → L1 Hyperliquid perp/spot (now: V4 deployCapital)    │
/// │                                                                          │
/// │  No L1 precompiles, no CORE_WRITER, no pending sells.                   │
/// │  Leader trades via standard Uniswap V4 swaps on X Layer.                │
/// │  NAV = USDC balance + V4 pool-priced asset holdings (StateLibrary).     │
/// └─────────────────────────────────────────────────────────────────────────┘
///
/// Roles:
///   Leader  — fund manager; deposits seed USDC, deploys/withdraws capital
///   Hook    — HypersFunHook; sole authority to mint/burn shares + collect fees
///   Traders — API wallets authorised by Leader (like V3 apiWalletInfo)
///
/// Exit fee (time-based, same structure as V3):
///   < 7 days  : 15%   |  7–30 days : 8%   |  30–90 days : 3%   |  > 90 days : 0%
///   Fee stays in vault (increases NAV for remaining holders).
contract FundVault is ERC20, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant BPS       = 10_000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_PERF_FEE = 3_000; // 30%
    uint256 public constant MAX_EXIT_FEE = 1_500; // 15% per tier

    // ─── V3 / Aave constants (X Layer mainnet) ────────────────────────────────
    address internal constant V3_ROUTER         = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address internal constant AAVE_POOL         = 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116;
    address internal constant USDT_TOKEN        = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant WOKB_TOKEN        = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant AUSDT_TOKEN       = 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297;
    address internal constant USDC_WOKB_POOL    = 0x3c2a3E37A6A905b3308861222a92fF2bE2d6DA62;
    uint24  internal constant USDC_WOKB_V3_FEE  = 100;
    uint24  internal constant USDT_WOKB_V3_FEE  = 3000;

    // ─── Immutables ───────────────────────────────────────────────────────────
    address public immutable usdc;
    address public immutable poolManager; // V4 PoolManager — used only for _update hook-address guard
    uint256 public immutable maxSupply;   // hard supply cap (e.g. 21_000_000 * 1e18)

    // ─── Core roles ───────────────────────────────────────────────────────────
    address public hook;        // HypersFunHook — set once
    address public leader;      // Fund manager (can be renounced → address(0))
    address public treasury;    // Receives trading fees
    address public governance;  // VaultGovernance contract (trustless on-chain gov)
    address public guardian;    // Emergency pause / withdraw (fast, no timelock)

    // ─── Performance fee ──────────────────────────────────────────────────────
    uint256 public performanceFeeBps;

    // Entry NAV tracking for performance fee (mirrors V3 EntryRecord)
    struct EntryRecord {
        uint256 weightedEntryNav; // weighted-average NAV at entry (1e18)
        uint256 totalTokens;      // total fund tokens held (for weighted avg)
    }
    mapping(address => EntryRecord) public entryRecords;

    // ─── Exit fee (V3-compatible tier system) ─────────────────────────────────
    struct ExitFeeTier {
        uint256 daysHeld; // minimum days held to qualify for this fee
        uint256 feeBps;   // fee in bps (1500 = 15%)
    }
    ExitFeeTier[] public exitFeeTiers;
    bool public exitFeeEnabled;

    // User purchase tracking for exit fee (mirrors V3 UserPurchaseInfo)
    struct UserPurchaseInfo {
        uint256 totalTokens;       // total tokens bought (weighted average base)
        uint256 weightedTimestamp; // weighted-average purchase timestamp
        uint256 lastPurchaseTime;
    }
    mapping(address => UserPurchaseInfo) public userPurchaseInfo;

    // ─── TWAP NAV (V3 V40 feature) ────────────────────────────────────────────
    uint256 public twapNav;            // smoothed NAV (1e18)
    uint256 public twapNavTime;        // last update timestamp
    uint256 public twapHalfLife;       // half-life in seconds (default 600 = 10 min)

    // ─── Pause ────────────────────────────────────────────────────────────────
    bool public paused;

    // ─── Authorized traders (replaces V3 apiWalletInfo) ──────────────────────
    struct TraderInfo {
        string  name;
        uint256 expiresAt; // 0 = permanent
    }
    mapping(address => TraderInfo) public authorizedTraders;

    // ─── Tracked assets for NAV (V3) ─────────────────────────────────────────
    struct TrackedAssetV3 {
        address token;
        address v3Pool;        // V3 pool with token/USDC pricing
        bool    token0IsAsset;
        uint8   tokenDecimals;
    }
    TrackedAssetV3[] public trackedAssetsV3;
    mapping(address => bool) public isTrackedV3;

    // ─── Approved short assets (owner whitelist — prevents fake pricingPool attack) ──
    mapping(address => bool) public approvedShortAssets;

    // ─── Active vault mode (set by governance vote) ───────────────────────────
    // Governance votes "vault enters SHORT/LONG mode for asset X for N days".
    // Every new deposit auto-deploys into the direction.
    // Every sell auto-unwinds proportional exposure to return USDC to seller.
    struct ActiveMode {
        bool    active;
        bool    isShort;           // true = short direction, false = long direction
        address asset;             // asset to trade (e.g. xBTC)
        address debtToken;         // SHORT only: Aave variable debt token
        address pricingPool;       // V3 pool for asset/USDT pricing
        bool    assetIsToken1;     // true if asset is token1 in pricingPool
        uint24  poolFee;           // V3 fee tier for asset/USDT swap
        uint8   assetDecimals;     // decimals of asset
        uint256 deployRatioBps;    // % of new deposit to auto-deploy (e.g. 8000 = 80%)
        uint256 borrowRatioBps;    // SHORT: % of USDT collateral value to borrow (e.g. 5000 = 50%)
        uint256 expiresAt;         // mode expires at this timestamp
    }
    ActiveMode public activeMode;

    // ─── Short positions (Aave borrow, generic asset) ─────────────────────────
    struct ShortPosition {
        uint256 collateralUsdt;  // USDT supplied to Aave (6 dec)
        address assetShorted;    // asset borrowed and sold (e.g. xETH)
        address debtToken;       // Aave variable debt token for assetShorted
        address pricingPool;     // V3 pool: assetShorted/USDT — for NAV debt valuation
        bool    assetIsToken1;   // true if assetShorted is token1 in pricingPool
        uint24  poolFee;         // V3 fee for assetShorted/USDT swap
        uint256 borrowedAmount;  // amount borrowed (assetShorted decimals)
        uint8   assetDecimals;   // decimals of assetShorted
        bool    open;
    }
    ShortPosition[] public shortPositions;


    // ─── Events ───────────────────────────────────────────────────────────────
    event HookSet(address indexed hook);
    event LeaderDeposit(address indexed leader, uint256 usdcAmount, uint256 sharesOut);
    event TraderAuthorized(address indexed trader, string name, uint256 expiresAt);
    event TraderRevoked(address indexed trader);
    event PerformanceFeeMinted(address indexed user, address indexed leader, uint256 tokens, uint256 nav);
    event ExitFeeCharged(address indexed user, uint256 feeUsdcAmount, uint256 feeBps, uint256 daysHeld);
    event Paused(bool paused);
    event TwapUpdated(uint256 smoothedNav);
    event ShortOpened(uint256 indexed posId, address assetShorted, uint256 collateralUsdt, uint256 borrowedAmount);
    event ShortClosed(uint256 indexed posId, address assetShorted, uint256 usdtWithdrawn);
    event AssetTrackedV3(address indexed token);
    event AssetUntrackedV3(address indexed token);
    event ActiveModeSet(address indexed asset, bool isShort, uint256 deployRatioBps, uint256 expiresAt);
    event ActiveModeRevoked();

    // ─── Errors ───────────────────────────────────────────────────────────────
    error OnlyHook();
    error OnlyLeader();
    error OnlyLeaderOrTrader();
    error HookAlreadySet();
    error GovernanceAlreadySet();
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();
    error CapReached();
    error TokenAlreadyTracked();
    error TokenNotTracked();
    error InsufficientVaultUsdc();
    error SlippageTooHigh();
    error PositionNotOpen();
    error NotApprovedShortAsset();
    error PerfFeeTooHigh();
    error ExitFeeTooHigh();
    error InvalidParam();
    error Unauthorized();
    error NoActiveMode();

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    modifier onlyLeader() {
        if (msg.sender != leader) revert OnlyLeader();
        _;
    }

    /// @dev Governance contract can call admin functions after leader renounces.
    modifier onlyLeaderOrGovernance() {
        if (msg.sender != leader && msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyLeaderOrTrader() {
        bool isLeader  = msg.sender == leader;
        bool isTrader  = authorizedTraders[msg.sender].expiresAt == 0
            ? bytes(authorizedTraders[msg.sender].name).length > 0
            : block.timestamp < authorizedTraders[msg.sender].expiresAt;
        bool isGov     = msg.sender == governance;
        if (!isLeader && !isTrader && !isGov) revert OnlyLeaderOrTrader();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ─── Initial price (set once at deployment) ───────────────────────────────
    /// @notice Initial NAV per share used on the very first depositUsdc call.
    ///         1e18 = $1/HFUND (classic 1:1)
    ///         1e12 = $0.000001/HFUND (pump.fun style — 1 USDC ≈ 1M HFUND at launch)
    uint256 public immutable initialPriceE18;

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        string memory name_,
        string memory symbol_,
        address usdc_,
        address leader_,
        address treasury_,
        address poolManager_,
        uint256 performanceFeeBps_,
        uint256 maxSupply_,         // 0 = no cap; e.g. 21_000_000 * 1e18
        uint256 initialPriceE18_    // initial NAV: 1e18=$1, 1e12=$0.000001; 0 defaults to 1e18
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (usdc_ == address(0) || leader_ == address(0)) revert ZeroAddress();
        if (performanceFeeBps_ > MAX_PERF_FEE) revert PerfFeeTooHigh();

        usdc            = usdc_;
        leader          = leader_;
        treasury        = treasury_ != address(0) ? treasury_ : leader_;
        poolManager     = poolManager_;
        performanceFeeBps = performanceFeeBps_;
        maxSupply       = maxSupply_;
        initialPriceE18 = initialPriceE18_ > 0 ? initialPriceE18_ : 1e18;
        twapHalfLife    = 600; // 10 minutes default
        exitFeeEnabled  = true;

        // Default exit fee tiers (mirrors V3 Factory defaults)
        exitFeeTiers.push(ExitFeeTier({daysHeld: 0,  feeBps: 1500})); // <7d: 15%
        exitFeeTiers.push(ExitFeeTier({daysHeld: 7,  feeBps: 800}));  // 7-30d: 8%
        exitFeeTiers.push(ExitFeeTier({daysHeld: 30, feeBps: 300}));  // 30-90d: 3%
        exitFeeTiers.push(ExitFeeTier({daysHeld: 90, feeBps: 0}));    // >90d: 0%
    }

    // ─── One-time hook binding ────────────────────────────────────────────────

    /// @notice Called once by deployer after hook is deployed.
    function setHook(address hook_) external onlyLeader {
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        // Hook needs unlimited USDC approval to settle sells
        IERC20(usdc).approve(hook_, type(uint256).max);
        emit HookSet(hook_);
    }

    // ─── NAV calculation ─────────────────────────────────────────────────────

    /// @notice Total fund assets in USDC (1e18 precision).
    ///         USDC balance (6→18 scaled) + asset values via V4 StateLibrary.
    function totalNAV() public view returns (uint256 nav) {
        nav = IERC20(usdc).balanceOf(address(this)) * 1e12;

        // V3 tracked assets (e.g. WOKB long position priced via V3 pool)
        uint256 nv3 = trackedAssetsV3.length;
        for (uint256 i = 0; i < nv3; i++) {
            TrackedAssetV3 storage a = trackedAssetsV3[i];
            uint256 bal = IERC20(a.token).balanceOf(address(this));
            if (bal == 0) continue;
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolSlot0(a.v3Pool).slot0();
            if (sqrtPriceX96 == 0) continue;
            nav += _valueInUsdc(bal, sqrtPriceX96, a.token0IsAsset, a.tokenDecimals);
        }

        // USDT held in vault (1 USDT ≈ 1 USDC, 6 dec → scale to 1e18)
        nav += IERC20(USDT_TOKEN).balanceOf(address(this)) * 1e12;

        // Aave USDT collateral (aUSDT balance, 6 dec)
        nav += IERC20(AUSDT_TOKEN).balanceOf(address(this)) * 1e12;

        // Subtract outstanding short debt values (generic, per-position)
        // Each open position has a debtToken and a pricingPool (asset/USDT).
        // Debt value in USDT ≈ USDC (1:1 peg).
        uint256 nshort = shortPositions.length;
        for (uint256 i = 0; i < nshort; i++) {
            ShortPosition storage sp = shortPositions[i];
            if (!sp.open) continue;
            uint256 debt = IERC20(sp.debtToken).balanceOf(address(this));
            if (debt == 0) continue;
            (uint160 spSqrt,,,,,,) = IUniswapV3PoolSlot0(sp.pricingPool).slot0();
            if (spSqrt == 0) continue;
            // pricingPool is assetShorted/USDT; assetIsToken1 determines price direction
            // token0IsAsset = !assetIsToken1 (asset is token0 when assetIsToken1=false)
            uint256 debtVal = _valueInUsdc(debt, spSqrt, !sp.assetIsToken1, sp.assetDecimals);
            if (nav > debtVal) nav -= debtVal;
            else { nav = 0; break; }
        }
    }

    /// @notice Instant NAV per share (1e18). Returns initialPriceE18 when supply is zero.
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return initialPriceE18;
        return HyperFunMath.getRawNAV(totalNAV(), supply);
    }

    /// @notice TWAP-smoothed NAV per share (1e18).
    ///         Used for buy-side pricing to protect against NAV spike manipulation.
    ///         When supply is zero (vault drained), returns initialPriceE18 directly
    ///         to avoid stale TWAP from a previous trading cycle inflating the price.
    function getSmoothedNAV() public view returns (uint256) {
        if (totalSupply() == 0) return initialPriceE18;
        return HyperFunMath.calcSmoothedNAV(
            navPerShare(), twapNav, twapNavTime, twapHalfLife, block.timestamp
        );
    }

    /// @notice Update TWAP state. Called by hook after each swap.
    function updateTwapNav() external onlyHook {
        uint256 smoothed = getSmoothedNAV();
        twapNav     = smoothed;
        twapNavTime = block.timestamp;
        emit TwapUpdated(smoothed);
    }

    function _valueInUsdc(
        uint256 tokenBalance,
        uint160 sqrtPriceX96,
        bool    token0IsAsset,
        uint8   // tokenDecimals — unused after formula fix
    ) internal pure returns (uint256 usdcValue1e18) {
        uint256 priceRaw = HyperFunMath.sqrtPriceX96ToPrice(sqrtPriceX96);
        if (priceRaw == 0) return 0;
        if (token0IsAsset) {
            // asset=token0, USDC/USDT=token1; priceRaw = token1_raw/token0_raw * 1e18
            // usdcValue = tokenBalance * (priceRaw/1e18) * 1e12  [convert 6-dec USDT → 1e18]
            usdcValue1e18 = (tokenBalance * priceRaw) / 1e6;
        } else {
            // price = token0/token1 = asset/USDC — need inverse
            // usdcValue = tokenBalance * (1e30 / priceRaw): priceRaw = 1e30/P_human, so P_human = 1e30/priceRaw
            usdcValue1e18 = (tokenBalance * 1e18 * 1e12) / priceRaw;
        }
    }

    // ─── Hook-only: mint / burn / USDC transfer ───────────────────────────────

    /// @notice Mint fund shares. Hook calls on buy.
    ///         `to`      — receives the ERC20 tokens (usually the hook itself, for V4 PM settle)
    ///         `buyer`   — whose purchase record to update (the actual investor)
    function mintShares(address to, address buyer, uint256 amount) external onlyHook whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (maxSupply > 0 && totalSupply() + amount > maxSupply) revert CapReached();
        // Auto-reset TWAP when vault is being re-entered after full drain,
        // so stale TWAP from a previous trading cycle does not distort pricing.
        if (totalSupply() == 0) {
            twapNav     = initialPriceE18;
            twapNavTime = block.timestamp;
            emit TwapUpdated(initialPriceE18);
        }
        uint256 nav = getSmoothedNAV(); // smoothed on buy
        _updateEntryRecord(buyer, amount, nav);
        _updatePurchaseInfo(buyer, amount);
        _mint(to, amount);
    }

    /// @notice Burn fund shares. Hook calls on sell.
    ///         Mints performance fee tokens to leader before burning.
    ///         Returns (exitFeeBps, daysHeld) for the hook to calculate exit fee.
    function burnShares(address from, uint256 amount)
        external
        onlyHook
        whenNotPaused
        returns (uint256 exitFeeBps_, uint256 daysHeld_)
    {
        if (amount == 0) revert ZeroAmount();

        uint256 nav = navPerShare(); // instant NAV on sell (V3 logic)

        // Performance fee: mint tokens to leader
        uint256 perfFeeTokens = _calculatePerformanceFee(from, amount, nav);
        if (perfFeeTokens > 0) {
            _mint(leader, perfFeeTokens);
            emit PerformanceFeeMinted(from, leader, perfFeeTokens, nav);
        }

        // Exit fee info for the hook to deduct from USDC out
        (exitFeeBps_, daysHeld_) = calculateExitFee(from);

        // Update tracking
        _updatePurchaseInfoAfterSell(from, amount);
        _reduceEntryRecord(from, amount);

        _burn(from, amount);
    }

    /// @notice Burn fund shares held by msg.sender (the hook), track fees for `seller`.
    ///         Used when hook received tokens via pm.take before calling this — seller's
    ///         wallet was already swept to PM, so we burn from the hook's balance instead.
    function burnSharesFrom(address seller, uint256 amount)
        external
        onlyHook
        whenNotPaused
        returns (uint256 exitFeeBps_, uint256 daysHeld_)
    {
        if (amount == 0) revert ZeroAmount();

        uint256 nav = navPerShare();

        uint256 perfFeeTokens = _calculatePerformanceFee(seller, amount, nav);
        if (perfFeeTokens > 0) {
            _mint(leader, perfFeeTokens);
            emit PerformanceFeeMinted(seller, leader, perfFeeTokens, nav);
        }

        (exitFeeBps_, daysHeld_) = calculateExitFee(seller);

        _updatePurchaseInfoAfterSell(seller, amount);
        _reduceEntryRecord(seller, amount);

        _burn(msg.sender, amount); // hook holds the tokens — burn from hook's balance
    }

    /// @notice Send USDC from vault to a recipient. Hook calls for sell settlement.
    function sendUSDCOut(address to, uint256 amount6) external onlyHook {
        if (amount6 == 0) return;
        if (IERC20(usdc).balanceOf(address(this)) < amount6) revert InsufficientVaultUsdc();
        IERC20(usdc).safeTransfer(to, amount6);
    }

    // ─── Leader seed deposit ──────────────────────────────────────────────────

    /// @notice Leader deposits USDC to seed the vault.
    ///         On first deposit (zero supply) mints 1 share per 1e12 USDC (1:1 normalised).
    function depositUsdc(uint256 usdcAmount, uint256 minShares)
        external
        onlyLeader
        whenNotPaused
        nonReentrant
    {
        if (usdcAmount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 supply = totalSupply();
        uint256 shares;
        if (supply == 0) {
            // bootstrap: shares = usdcAmount(6-dec) * 1e30 / initialPriceE18
            // e.g. initialPriceE18=1e18 → 1 USDC = 1 HFUND ($1 start)
            //      initialPriceE18=1e12 → 1 USDC = 1,000,000 HFUND ($0.000001 start)
            shares = (usdcAmount * 1e30) / initialPriceE18;
        } else {
            uint256 nav = totalNAV();   // instant NAV for leader deposit
            shares = (usdcAmount * 1e12 * supply) / nav;
        }
        if (shares < minShares) revert SlippageTooHigh();

        uint256 navAtDeposit = supply == 0 ? PRECISION : navPerShare();
        _updateEntryRecord(msg.sender, shares, navAtDeposit);
        _updatePurchaseInfo(msg.sender, shares);
        _mint(msg.sender, shares);

        // Initialise TWAP on first deposit
        if (twapNavTime == 0) {
            twapNav     = navPerShare();
            twapNavTime = block.timestamp;
        }

        emit LeaderDeposit(msg.sender, usdcAmount, shares);
    }

    // ─── Exit fee calculation ─────────────────────────────────────────────────

    /// @notice Returns (exitFeeBps, daysHeld) for a given seller.
    ///         Mirrors V3 HyperFunToken.calculateExitFee().
    function calculateExitFee(address user)
        public view returns (uint256 exitFeeBps_, uint256 daysHeld_)
    {
        if (!exitFeeEnabled || exitFeeTiers.length == 0) return (0, 0);

        UserPurchaseInfo storage info = userPurchaseInfo[user];
        if (info.weightedTimestamp == 0) return (exitFeeTiers[0].feeBps, 0);

        daysHeld_ = (block.timestamp - info.weightedTimestamp) / 1 days;

        exitFeeBps_ = exitFeeTiers[0].feeBps;
        for (uint256 i = exitFeeTiers.length; i > 0; i--) {
            if (daysHeld_ >= exitFeeTiers[i - 1].daysHeld) {
                exitFeeBps_ = exitFeeTiers[i - 1].feeBps;
                break;
            }
        }
    }

    function _updatePurchaseInfo(address user, uint256 tokensOut) internal {
        UserPurchaseInfo storage info = userPurchaseInfo[user];
        if (info.totalTokens == 0) {
            info.totalTokens       = tokensOut;
            info.weightedTimestamp = block.timestamp;
        } else {
            uint256 oldTotal = info.totalTokens;
            uint256 newTotal = oldTotal + tokensOut;
            info.weightedTimestamp =
                (oldTotal * info.weightedTimestamp + tokensOut * block.timestamp) / newTotal;
            info.totalTokens = newTotal;
        }
        info.lastPurchaseTime = block.timestamp;
    }

    function _updatePurchaseInfoAfterSell(address user, uint256 tokensSold) internal {
        UserPurchaseInfo storage info = userPurchaseInfo[user];
        if (tokensSold >= info.totalTokens) {
            info.totalTokens = 0;
        } else {
            info.totalTokens -= tokensSold;
        }
    }

    // ─── Performance fee (mirrors V3 EntryRecord logic) ───────────────────────

    function _updateEntryRecord(address user, uint256 newTokens, uint256 nav) internal {
        EntryRecord storage rec = entryRecords[user];
        if (rec.totalTokens == 0) {
            rec.weightedEntryNav = nav;
            rec.totalTokens      = newTokens;
        } else {
            rec.weightedEntryNav =
                (rec.totalTokens * rec.weightedEntryNav + newTokens * nav) /
                (rec.totalTokens + newTokens);
            rec.totalTokens += newTokens;
        }
    }

    function _calculatePerformanceFee(address user, uint256 tokens, uint256 currentNav)
        internal view returns (uint256 feeTokens)
    {
        if (performanceFeeBps == 0) return 0;
        EntryRecord storage rec = entryRecords[user];
        if (rec.weightedEntryNav == 0 || currentNav <= rec.weightedEntryNav) return 0;

        uint256 profitPerToken = currentNav - rec.weightedEntryNav;
        uint256 totalProfit18  = (tokens * profitPerToken) / PRECISION;
        uint256 fee18          = (totalProfit18 * performanceFeeBps) / BPS;
        feeTokens              = (fee18 * PRECISION) / currentNav;
    }

    function _reduceEntryRecord(address user, uint256 soldTokens) internal {
        EntryRecord storage rec = entryRecords[user];
        if (soldTokens >= rec.totalTokens) {
            rec.weightedEntryNav = 0;
            rec.totalTokens      = 0;
        } else {
            rec.totalTokens -= soldTokens;
        }
    }

    /// @notice Override ERC20._update to inherit entry NAV on transfers.
    ///         Prevents circumventing performance fee by transferring to a fresh address.
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == address(0) || to == address(0) || from == to) return;
        // PM and hook are V4 settlement intermediaries — skip entry nav inheritance
        // to prevent their zero nav from diluting real investors' entry records.
        if (from == poolManager || to == poolManager) return;
        if (from == hook || to == hook) return;

        EntryRecord storage fromRec = entryRecords[from];
        EntryRecord storage toRec   = entryRecords[to];
        uint256 fromNav = fromRec.weightedEntryNav;

        if (toRec.totalTokens == 0) {
            toRec.weightedEntryNav = fromNav;
            toRec.totalTokens      = amount;
        } else {
            toRec.weightedEntryNav =
                (toRec.totalTokens * toRec.weightedEntryNav + amount * fromNav) /
                (toRec.totalTokens + amount);
            toRec.totalTokens += amount;
        }

        if (amount >= fromRec.totalTokens) {
            fromRec.weightedEntryNav = 0;
            fromRec.totalTokens      = 0;
        } else {
            fromRec.totalTokens -= amount;
        }
    }

    // ─── V3 short trading ────────────────────────────────────────────────────

    /// @notice Open a short position on any Aave-borrowable asset.
    /// @param usdcMargin       USDC from vault to use as collateral (will be swapped → USDT via WOKB)
    /// @param assetToShort     Address of asset to borrow and sell (e.g. xETH)
    /// @param debtToken        Aave variable debt token for assetToShort
    /// @param pricingPool      V3 pool: USDT/assetToShort — used for NAV debt valuation
    /// @param assetIsToken1    true if assetToShort is token1 in pricingPool (USDT is token0)
    /// @param poolFee          V3 fee tier for the assetToShort/USDT swap pool
    /// @param amountToBorrow   How much of assetToShort to borrow
    /// @param assetDecimals_   Decimals of assetToShort (e.g. 18 for xETH)
    function openShort(
        uint256 usdcMargin,
        address assetToShort,
        address debtToken,
        address pricingPool,
        bool    assetIsToken1,
        uint24  poolFee,
        uint256 amountToBorrow,
        uint8   assetDecimals_
    ) external onlyLeaderOrTrader whenNotPaused nonReentrant returns (uint256 posId) {
        if (!approvedShortAssets[assetToShort]) revert NotApprovedShortAsset();
        if (usdcMargin == 0 || amountToBorrow == 0) revert ZeroAmount();
        if (IERC20(usdc).balanceOf(address(this)) < usdcMargin) revert InsufficientVaultUsdc();

        // ① USDC → WOKB (fee=100) → USDT (fee=3000)  [both pools have deep liquidity]
        IERC20(usdc).forceApprove(V3_ROUTER, usdcMargin);
        bytes memory toUsdt = abi.encodePacked(
            usdc, USDC_WOKB_V3_FEE, WOKB_TOKEN, USDT_WOKB_V3_FEE, USDT_TOKEN
        );
        uint256 usdtReceived = ISwapRouterV3(V3_ROUTER).exactInput(
            ISwapRouterV3.ExactInputParams({
                path: toUsdt, recipient: address(this), amountIn: usdcMargin, amountOutMinimum: 0
            })
        );

        // ② Supply USDT to Aave as collateral
        IERC20(USDT_TOKEN).forceApprove(AAVE_POOL, usdtReceived);
        IAavePool(AAVE_POOL).supply(USDT_TOKEN, usdtReceived, address(this), 0);

        // ③ Borrow assetToShort (variable rate = 2)
        IAavePool(AAVE_POOL).borrow(assetToShort, amountToBorrow, 2, 0, address(this));

        // ④ Sell borrowed asset → USDT  (use the same V3 pool we priced against)
        IERC20(assetToShort).forceApprove(V3_ROUTER, amountToBorrow);
        ISwapRouterV3(V3_ROUTER).exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: assetToShort, tokenOut: USDT_TOKEN, fee: poolFee,
                recipient: address(this), amountIn: amountToBorrow,
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );

        posId = shortPositions.length;
        shortPositions.push(ShortPosition({
            collateralUsdt: usdtReceived,
            assetShorted:   assetToShort,
            debtToken:      debtToken,
            pricingPool:    pricingPool,
            assetIsToken1:  assetIsToken1,
            poolFee:        poolFee,
            borrowedAmount: amountToBorrow,
            assetDecimals:  assetDecimals_,
            open:           true
        }));
        emit ShortOpened(posId, assetToShort, usdtReceived, amountToBorrow);
    }

    /// @notice Close short: repay Aave debt, recover collateral → USDC.
    function closeShort(uint256 posId, uint256 /*maxUsdcRepay*/)
        external onlyLeaderOrTrader whenNotPaused nonReentrant
    {
        if (!shortPositions[posId].open) revert PositionNotOpen();
        address assetShorted = shortPositions[posId].assetShorted;
        _closeShortCore(posId);
        emit ShortClosed(posId, assetShorted, 0);
    }

    function shortPositionCount() external view returns (uint256) { return shortPositions.length; }

    /// @notice Close ALL open short positions. Called by governance before mode switch.
    function closeAllShorts() external onlyLeaderOrGovernance nonReentrant {
        for (uint256 i = 0; i < shortPositions.length; i++)
            if (shortPositions[i].open) _closeShortCore(i);
    }

    /// @notice Close ALL long positions (sell entire asset holding → USDC).
    ///         Called by governance before mode switch away from GoLong.
    function closeAllLongs() external onlyLeaderOrGovernance nonReentrant {
        ActiveMode storage m = activeMode;
        if (m.asset != address(0)) _closeLongCore(m.asset, m.poolFee);
    }

    /// @notice Core closeLong: sell all held asset → USDC via V3 multi-hop.
    ///         asset → USDT → WOKB → USDC (reverses the buy path).
    function _closeLongCore(address asset_, uint24 poolFee_) internal {
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(asset_).forceApprove(V3_ROUTER, bal);
        bytes memory toUsdc = abi.encodePacked(
            asset_, poolFee_, USDT_TOKEN, USDT_WOKB_V3_FEE, WOKB_TOKEN, USDC_WOKB_V3_FEE, usdc
        );
        ISwapRouterV3(V3_ROUTER).exactInput(
            ISwapRouterV3.ExactInputParams({ path: toUsdc, recipient: address(this), amountIn: bal, amountOutMinimum: 0 })
        );
    }

    // ─── Asset tracking (V3 only) ─────────────────────────────────────────────

    function addTrackedAssetV3(
        address token,
        address v3Pool,
        bool    token0IsAsset,
        uint8   tokenDecimals_
    ) external onlyLeaderOrGovernance {
        if (token == usdc) revert InvalidParam();
        if (isTrackedV3[token]) revert TokenAlreadyTracked();
        trackedAssetsV3.push(TrackedAssetV3({
            token: token, v3Pool: v3Pool,
            token0IsAsset: token0IsAsset, tokenDecimals: tokenDecimals_
        }));
        isTrackedV3[token] = true;
        emit AssetTrackedV3(token);
    }

    function removeTrackedAssetV3(address token) external onlyLeaderOrGovernance {
        if (!isTrackedV3[token]) revert TokenNotTracked();
        isTrackedV3[token] = false;
        uint256 n = trackedAssetsV3.length;
        for (uint256 i = 0; i < n; i++) {
            if (trackedAssetsV3[i].token == token) {
                trackedAssetsV3[i] = trackedAssetsV3[n - 1];
                trackedAssetsV3.pop();
                break;
            }
        }
        emit AssetUntrackedV3(token);
    }

    // ─── Authorized traders (V3 API wallet equivalent) ────────────────────────

    function addAuthorizedTrader(
        address trader,
        string calldata name_,
        uint256 durationDays
    ) external onlyLeaderOrGovernance {
        if (trader == address(0)) revert ZeroAddress();
        uint256 expiresAt = durationDays == 0 ? 0 : block.timestamp + durationDays * 1 days;
        authorizedTraders[trader] = TraderInfo({name: name_, expiresAt: expiresAt});
        emit TraderAuthorized(trader, name_, expiresAt);
    }

    function revokeAuthorizedTrader(address trader) external onlyLeaderOrGovernance {
        delete authorizedTraders[trader];
        emit TraderRevoked(trader);
    }

    // ─── Leader admin ─────────────────────────────────────────────────────────

    function setTreasury(address treasury_) external onlyLeader {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    function setExitFeeEnabled(bool enabled) external onlyLeaderOrGovernance {
        exitFeeEnabled = enabled;
    }

    function setExitFeeTiers(
        uint256[] calldata daysHeld_,
        uint256[] calldata feeBps_
    ) external onlyLeaderOrGovernance {
        if (daysHeld_.length != feeBps_.length) revert InvalidParam();
        if (daysHeld_.length == 0 || daysHeld_.length > 10) revert InvalidParam();
        delete exitFeeTiers;
        for (uint256 i = 0; i < daysHeld_.length; i++) {
            if (feeBps_[i] > MAX_EXIT_FEE) revert ExitFeeTooHigh();
            exitFeeTiers.push(ExitFeeTier({daysHeld: daysHeld_[i], feeBps: feeBps_[i]}));
        }
    }

    function setTwapHalfLife(uint256 halfLifeSeconds) external onlyLeader {
        if (halfLifeSeconds < 60 || halfLifeSeconds > 3600) revert InvalidParam();
        twapHalfLife = halfLifeSeconds;
        twapNav     = navPerShare();
        twapNavTime = block.timestamp;
    }

    function setPaused(bool paused_) external {
        if (msg.sender != leader && msg.sender != guardian && msg.sender != governance)
            revert Unauthorized();
        paused = paused_;
        emit Paused(paused_);
    }

    function transferLeader(address newLeader) external onlyLeader {
        if (newLeader == address(0)) revert ZeroAddress();
        leader = newLeader;
    }

    /// @notice Permanently renounce leader role. After this, only governance + guardian operate.
    ///         Irreversible — ensure governance is set before calling.
    function renounceLeader() external onlyLeader {
        leader = address(0);
    }

    /// @notice Approve/revoke an asset for shorting. Leader or governance can call.
    function setApprovedShortAsset(address asset, bool approved) external onlyLeaderOrGovernance {
        approvedShortAssets[asset] = approved;
    }

    // ─── Active mode: auto-deploy + atomic redemption ────────────────────────

    /// @notice Set vault directional mode. Called by leader/governance.
    ///         When active, every buy auto-deploys deployRatioBps% of USDC into the position.
    ///         Every sell auto-unwinds positions atomically to cover redemption.
    function setActiveMode(
        bool    isShort_,
        address asset_,
        address debtToken_,      // SHORT only; ignored for LONG
        address pricingPool_,
        bool    assetIsToken1_,
        uint24  poolFee_,
        uint8   assetDecimals_,
        uint256 deployRatioBps_, // e.g. 8000 = deploy 80% of each buy into position
        uint256 borrowRatioBps_, // SHORT: e.g. 5000 = borrow 50% of collateral value
        uint256 durationSeconds_
    ) external onlyLeaderOrGovernance {
        if (asset_ == address(0)) revert ZeroAddress();
        if (isShort_ && !approvedShortAssets[asset_]) revert NotApprovedShortAsset();
        if (deployRatioBps_ == 0 || deployRatioBps_ > 9_500) revert InvalidParam(); // max 95%
        activeMode = ActiveMode({
            active:         true,
            isShort:        isShort_,
            asset:          asset_,
            debtToken:      debtToken_,
            pricingPool:    pricingPool_,
            assetIsToken1:  assetIsToken1_,
            poolFee:        poolFee_,
            assetDecimals:  assetDecimals_,
            deployRatioBps: deployRatioBps_,
            borrowRatioBps: borrowRatioBps_,
            expiresAt:      block.timestamp + durationSeconds_
        });
        emit ActiveModeSet(asset_, isShort_, deployRatioBps_, activeMode.expiresAt);
    }

    function revokeActiveMode() external onlyLeaderOrGovernance {
        activeMode.active = false;
        emit ActiveModeRevoked();
    }

    /// @notice Called by hook after every buy. Auto-deploys USDC into active mode.
    ///         GoShort: USDC → USDT → Aave collateral → borrow asset → sell asset.
    ///         GoLong:  USDC → WOKB → USDT → asset (spot buy, held in vault).
    ///         Silent no-op if no active mode, mode expired, or price unavailable.
    function autoDeployCapital(uint256 usdcIn6) external onlyHook {
        ActiveMode storage m = activeMode;
        if (!m.active || m.expiresAt <= block.timestamp) return;

        uint256 deployAmt = usdcIn6 * m.deployRatioBps / 10_000;
        if (deployAmt == 0 || IERC20(usdc).balanceOf(address(this)) < deployAmt) return;

        if (m.isShort) {
            // ── GoShort: USDC → USDT → supply Aave → borrow asset → sell ──────
            IERC20(usdc).forceApprove(V3_ROUTER, deployAmt);
            bytes memory toUsdt = abi.encodePacked(usdc, USDC_WOKB_V3_FEE, WOKB_TOKEN, USDT_WOKB_V3_FEE, USDT_TOKEN);
            uint256 usdtGot = ISwapRouterV3(V3_ROUTER).exactInput(
                ISwapRouterV3.ExactInputParams({ path: toUsdt, recipient: address(this), amountIn: deployAmt, amountOutMinimum: 0 })
            );
            if (usdtGot == 0) return;

            uint256 assetBorrow = _usdtToAssetAmount(usdtGot * m.borrowRatioBps / 10_000, m.pricingPool, m.assetIsToken1);
            if (assetBorrow == 0) return;

            IERC20(USDT_TOKEN).forceApprove(AAVE_POOL, usdtGot);
            IAavePool(AAVE_POOL).supply(USDT_TOKEN, usdtGot, address(this), 0);
            IAavePool(AAVE_POOL).borrow(m.asset, assetBorrow, 2, 0, address(this));
            IERC20(m.asset).forceApprove(V3_ROUTER, assetBorrow);
            ISwapRouterV3(V3_ROUTER).exactInputSingle(ISwapRouterV3.ExactInputSingleParams({
                tokenIn: m.asset, tokenOut: USDT_TOKEN, fee: m.poolFee,
                recipient: address(this), amountIn: assetBorrow, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            }));
            shortPositions.push(ShortPosition({
                collateralUsdt: usdtGot, assetShorted: m.asset, debtToken: m.debtToken,
                pricingPool: m.pricingPool, assetIsToken1: m.assetIsToken1,
                poolFee: m.poolFee, borrowedAmount: assetBorrow,
                assetDecimals: m.assetDecimals, open: true
            }));
            emit ShortOpened(shortPositions.length - 1, m.asset, usdtGot, assetBorrow);
        } else {
            // ── GoLong: USDC → WOKB → USDT → asset (spot long) ──────────────
            IERC20(usdc).forceApprove(V3_ROUTER, deployAmt);
            bytes memory toLong = abi.encodePacked(
                usdc, USDC_WOKB_V3_FEE, WOKB_TOKEN, USDT_WOKB_V3_FEE, USDT_TOKEN, m.poolFee, m.asset
            );
            ISwapRouterV3(V3_ROUTER).exactInput(
                ISwapRouterV3.ExactInputParams({ path: toLong, recipient: address(this), amountIn: deployAmt, amountOutMinimum: 0 })
            );
            // Auto-register asset for NAV tracking on first deploy
            if (!isTrackedV3[m.asset]) {
                trackedAssetsV3.push(TrackedAssetV3({
                    token: m.asset, v3Pool: m.pricingPool,
                    token0IsAsset: !m.assetIsToken1, tokenDecimals: m.assetDecimals
                }));
                isTrackedV3[m.asset] = true;
                emit AssetTrackedV3(m.asset);
            }
        }
    }

    /// @notice Called by hook for sells. Atomically unwinds positions if
    ///         vault USDC is insufficient to cover the redemption.
    ///         GoLong: sells all held asset → USDC in one pass.
    ///         GoShort: closes oldest open positions (up to 5).
    function ensureLiquidityAndSend(address to, uint256 amount6) external onlyHook {
        if (amount6 == 0) return;
        if (IERC20(usdc).balanceOf(address(this)) < amount6) {
            ActiveMode storage m = activeMode;
            if (m.active && !m.isShort && m.asset != address(0)) {
                // GoLong: liquidate entire asset holding
                _closeLongCore(m.asset, m.poolFee);
            } else {
                // GoShort: close oldest open positions until enough USDC
                for (uint256 attempts = 0; attempts < 5; attempts++) {
                    if (IERC20(usdc).balanceOf(address(this)) >= amount6) break;
                    bool found = false;
                    for (uint256 i = 0; i < shortPositions.length; i++) {
                        if (shortPositions[i].open) { _closeShortCore(i); found = true; break; }
                    }
                    if (!found) break;
                }
            }
        }
        if (IERC20(usdc).balanceOf(address(this)) < amount6) revert InsufficientVaultUsdc();
        IERC20(usdc).safeTransfer(to, amount6);
    }

    /// @notice Core closeShort logic (no nonReentrant — caller must hold the lock).
    function _closeShortCore(uint256 posId) internal {
        ShortPosition storage pos = shortPositions[posId];
        if (!pos.open) return;

        uint256 actualUsdc = IERC20(usdc).balanceOf(address(this));
        if (actualUsdc > 0) {
            IERC20(usdc).forceApprove(V3_ROUTER, actualUsdc);
            bytes memory toUsdt = abi.encodePacked(usdc, USDC_WOKB_V3_FEE, WOKB_TOKEN, USDT_WOKB_V3_FEE, USDT_TOKEN);
            ISwapRouterV3(V3_ROUTER).exactInput(ISwapRouterV3.ExactInputParams({ path: toUsdt, recipient: address(this), amountIn: actualUsdc, amountOutMinimum: 0 }));
        }

        // Use actual outstanding debt so approval covers total when multiple positions share one Aave account.
        uint256 currentDebt = IERC20(pos.debtToken).balanceOf(address(this));
        if (currentDebt == 0) { pos.open = false; return; } // debt already repaid (e.g. by a prior close)

        uint256 assetNeeded = currentDebt * 10050 / 10000;
        if (assetNeeded <= currentDebt) assetNeeded = currentDebt + 1;
        uint256 totalUsdt = IERC20(USDT_TOKEN).balanceOf(address(this));
        IERC20(USDT_TOKEN).forceApprove(V3_ROUTER, totalUsdt);
        ISwapRouterV3(V3_ROUTER).exactOutputSingle(ISwapRouterV3.ExactOutputSingleParams({
            tokenIn: USDT_TOKEN, tokenOut: pos.assetShorted, fee: pos.poolFee,
            recipient: address(this), amountOut: assetNeeded,
            amountInMaximum: totalUsdt, sqrtPriceLimitX96: 0
        }));

        IERC20(pos.assetShorted).forceApprove(AAVE_POOL, assetNeeded);
        IAavePool(AAVE_POOL).repay(pos.assetShorted, type(uint256).max, 2, address(this));
        IAavePool(AAVE_POOL).withdraw(USDT_TOKEN, type(uint256).max, address(this));

        uint256 remainUsdt = IERC20(USDT_TOKEN).balanceOf(address(this));
        if (remainUsdt > 0) {
            IERC20(USDT_TOKEN).forceApprove(V3_ROUTER, remainUsdt);
            bytes memory back = abi.encodePacked(USDT_TOKEN, USDT_WOKB_V3_FEE, WOKB_TOKEN, USDC_WOKB_V3_FEE, usdc);
            ISwapRouterV3(V3_ROUTER).exactInput(ISwapRouterV3.ExactInputParams({ path: back, recipient: address(this), amountIn: remainUsdt, amountOutMinimum: 0 }));
        }
        pos.open = false;
    }

    /// @notice Price helper: how many raw asset units equal usdtValue6 USDT.
    function _usdtToAssetAmount(uint256 usdtValue6, address pricingPool, bool assetIsToken1)
        internal view returns (uint256)
    {
        (uint160 sqrtP,,,,,,) = IUniswapV3PoolSlot0(pricingPool).slot0();
        uint256 priceRaw = HyperFunMath.sqrtPriceX96ToPrice(sqrtP);
        if (priceRaw == 0) return 0;
        if (assetIsToken1) {
            // priceRaw = asset_raw/USDT_raw * 1e18
            // assetAmount = usdtValue6 * priceRaw / 1e18
            return (usdtValue6 * priceRaw) / 1e18;
        } else {
            // priceRaw = USDT_raw/asset_raw * 1e18
            // assetAmount = usdtValue6 * 1e18 / priceRaw
            return (usdtValue6 * 1e18) / priceRaw;
        }
    }

    // ─── Governance setup ─────────────────────────────────────────────────────

    /// @notice Set the governance contract. One-time only (cannot replace once set).
    ///         Call this before renounceLeader().
    function setGovernance(address gov_) external onlyLeader {
        if (governance != address(0)) revert GovernanceAlreadySet();
        if (gov_ == address(0)) revert ZeroAddress();
        governance = gov_;
    }

    /// @notice Set guardian address (emergency pause + withdraw, no timelock).
    function setGuardian(address guardian_) external onlyLeader {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
    }

    // ─── Emergency ────────────────────────────────────────────────────────────

    /// @notice Emergency USDC recovery. Leader or guardian (no timelock delay).
    function emergencyWithdrawUsdc(uint256 amount6) external {
        if (msg.sender != leader && msg.sender != guardian) revert Unauthorized();
        address to = leader != address(0) ? leader : guardian;
        IERC20(usdc).safeTransfer(to, amount6);
    }

    /// @notice Emergency token recovery. Leader or guardian (no timelock delay).
    function emergencyWithdrawToken(address token, uint256 amount) external {
        if (msg.sender != leader && msg.sender != guardian) revert Unauthorized();
        address to = leader != address(0) ? leader : guardian;
        IERC20(token).safeTransfer(to, amount);
    }
}
