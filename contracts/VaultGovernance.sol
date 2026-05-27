// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFundVault {
    function setActiveMode(
        bool isShort_, address asset_, address debtToken_, address pricingPool_,
        bool assetIsToken1_, uint24 poolFee_, uint8 assetDecimals_,
        uint256 deployRatioBps_, uint256 borrowRatioBps_, uint256 durationSeconds_
    ) external;
    function revokeActiveMode() external;
    function closeAllShorts() external;
    function closeAllLongs() external;
    function totalSupply() external view returns (uint256);
}

/// @title VaultGovernance
/// @notice Trustless governance: HFUND holders vote GO SHORT / GO LONG / EXIT
///         for any pre-configured asset (xBTC, xSOL, xETH, …).
///
///  Setup (leader does once, then renounces):
///    1. setAssetConfig(0, xBTC_params)
///    2. setAssetConfig(1, xSOL_params)
///    3. setAssetConfig(2, xETH_params)
///    4. vault.setGovernance(thisContract)
///    5. vault.renounceLeader()
///    6. renounceAdmin()
///
///  Proposal flow (fully autonomous):
///    propose(GoShort, assetIndex=1, "Short SOL", permit)
///    → holders vote FOR/AGAINST (1-hour window)
///    → after 1-hour vote + 1-min timelock → anyone execute()
///    → vault runs GoShort on that asset for 24 hours
contract VaultGovernance is ReentrancyGuard {

    IERC20     public immutable hfund;
    IFundVault public immutable vault;

    // ─── Pre-configured assets (set by leader, e.g. 0=xBTC, 1=xSOL, 2=xETH) ─
    struct AssetConfig {
        address asset;
        address debtToken;
        address pricingPool;
        bool    assetIsToken1;
        uint24  poolFee;
        uint8   assetDecimals;
        uint256 deployRatioBps;   // % of each buy to deploy (e.g. 8000 = 80%)
        uint256 borrowRatioBps;   // % of collateral value to borrow (e.g. 5000 = 50%)
        bool    configured;
    }
    mapping(uint8 => AssetConfig) public assetConfigs;
    uint8 public assetConfigCount;

    uint256 public modeDuration = 24 hours;

    // ─── Governance timing (admin-settable) ───────────────────────────────────
    uint256 public votingPeriod    = 1 hours;
    uint256 public timelockDelay   = 1 minutes;
    uint256 public quorumBps       = 1_000;   // 10% of total HFUND supply
    uint256 public minProposerLock = 1e18;    // 1 HFUND to propose

    // ─── Admin (only before leader renounces) ─────────────────────────────────
    address public admin;

    // ─── Proposal ─────────────────────────────────────────────────────────────
    enum Direction    { GoShort, GoLong, Exit }
    enum ProposalState { Active, Defeated, Queued, Executed, Cancelled }

    struct Proposal {
        Direction direction;
        uint8     assetIndex;          // which assetConfig to use (ignored for Exit)
        address   proposer;
        uint256   proposerLocked;      // auto-counted as FOR
        uint256   votingDeadline;
        uint256   timelockEnd;
        uint256   votesFor;
        uint256   votesAgainst;
        uint256   totalSupplySnapshot;
        bool      executed;
        bool      cancelled;
        string    description;
    }

    mapping(uint256 => Proposal)                    public proposals;
    mapping(uint256 => mapping(address => uint256)) public lockedFor;
    mapping(uint256 => mapping(address => uint256)) public lockedAgainst;

    uint256 public proposalCount;

    // ─── Events ───────────────────────────────────────────────────────────────
    event AssetConfigured(uint8 indexed index, address indexed asset);
    event ProposalCreated(uint256 indexed id, Direction direction, uint8 assetIndex, address indexed proposer, uint256 votingDeadline);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 amount);
    event ProposalExecuted(uint256 indexed id, Direction direction, uint8 assetIndex);
    event ProposalCancelled(uint256 indexed id);
    event VoteReclaimed(uint256 indexed id, address indexed voter, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotAdmin();
    error NotConfigured();
    error VotingStillActive();
    error VotingAlreadyEnded();
    error TimelockNotExpired();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error ProposalDefeated();
    error NothingToReclaim();
    error InsufficientLock();
    error NotProposer();
    error InvalidProposalId();
    error InvalidParam();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address hfund_, address vault_, address admin_) {
        hfund = IERC20(hfund_);
        vault = IFundVault(vault_);
        admin = admin_;
    }

    // ─── Admin setup ──────────────────────────────────────────────────────────

    /// @notice Register or update a tradeable asset at the given index.
    ///         Typical: index 0 = xBTC, 1 = xSOL, 2 = xETH.
    function setAssetConfig(
        uint8   index_,
        address asset_,
        address debtToken_,
        address pricingPool_,
        bool    assetIsToken1_,
        uint24  poolFee_,
        uint8   assetDecimals_,
        uint256 deployRatioBps_,
        uint256 borrowRatioBps_
    ) external onlyAdmin {
        if (deployRatioBps_ == 0 || deployRatioBps_ > 9_500) revert InvalidParam();
        bool wasConfigured = assetConfigs[index_].configured;
        assetConfigs[index_] = AssetConfig({
            asset:          asset_,
            debtToken:      debtToken_,
            pricingPool:    pricingPool_,
            assetIsToken1:  assetIsToken1_,
            poolFee:        poolFee_,
            assetDecimals:  assetDecimals_,
            deployRatioBps: deployRatioBps_,
            borrowRatioBps: borrowRatioBps_,
            configured:     true
        });
        if (!wasConfigured && index_ >= assetConfigCount) {
            assetConfigCount = index_ + 1;
        }
        emit AssetConfigured(index_, asset_);
    }

    function setModeDuration(uint256 seconds_) external onlyAdmin {
        if (seconds_ < 1 hours || seconds_ > 30 days) revert InvalidParam();
        modeDuration = seconds_;
    }

    function setGovParams(uint256 vp, uint256 td, uint256 qb, uint256 ml) external onlyAdmin {
        if (vp > 0) votingPeriod    = vp;
        if (td > 0) timelockDelay   = td;
        if (qb > 0) quorumBps       = qb;
        if (ml > 0) minProposerLock = ml;
    }

    /// @notice Renounce admin — after this, governance proposals are the only authority.
    function renounceAdmin() external onlyAdmin {
        admin = address(0);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function state(uint256 id) public view returns (ProposalState) {
        if (id >= proposalCount) revert InvalidProposalId();
        Proposal storage p = proposals[id];
        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed)  return ProposalState.Executed;
        if (block.timestamp <= p.votingDeadline) return ProposalState.Active;
        uint256 quorum = p.totalSupplySnapshot * quorumBps / 10_000;
        if ((p.votesFor + p.votesAgainst) < quorum) return ProposalState.Defeated;
        if (p.votesFor <= p.votesAgainst)            return ProposalState.Defeated;
        return ProposalState.Queued;
    }

    // ─── Permit struct ────────────────────────────────────────────────────────
    struct PermitData {
        uint256 deadline;
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // ─── 1. Propose ───────────────────────────────────────────────────────────

    /// @notice Propose a direction change for a specific pre-configured asset.
    /// @param direction  GoShort(0) / GoLong(1) / Exit(2)
    /// @param assetIndex Which asset to trade (ignored when direction = Exit)
    /// @param permit     Optional EIP-2612 permit for HFUND (deadline=0 to skip)
    function propose(
        Direction       direction,
        uint8           assetIndex,
        string calldata description,
        PermitData calldata permit
    ) external nonReentrant returns (uint256 id) {
        if (direction != Direction.Exit) {
            if (!assetConfigs[assetIndex].configured) revert NotConfigured();
        }

        if (minProposerLock > 0) {
            if (permit.deadline > 0) {
                // try/catch: defuses permit front-run DoS
                try IERC20Permit(address(hfund)).permit(
                    msg.sender, address(this), minProposerLock,
                    permit.deadline, permit.v, permit.r, permit.s
                ) {} catch {}
            }
            hfund.transferFrom(msg.sender, address(this), minProposerLock);
        }

        id = proposalCount++;
        Proposal storage p = proposals[id];
        p.direction           = direction;
        p.assetIndex          = assetIndex;
        p.proposer            = msg.sender;
        p.proposerLocked      = minProposerLock;
        p.votingDeadline      = block.timestamp + votingPeriod;
        p.timelockEnd         = p.votingDeadline + timelockDelay;
        p.totalSupplySnapshot = hfund.totalSupply();
        p.description         = description;

        // Proposer lock auto-counts as FOR vote
        if (minProposerLock > 0) {
            lockedFor[id][msg.sender] = minProposerLock;
            p.votesFor                = minProposerLock;
        }

        emit ProposalCreated(id, direction, assetIndex, msg.sender, p.votingDeadline);
    }

    // ─── 2. Vote ──────────────────────────────────────────────────────────────

    /// @param permit Optional EIP-2612 permit for HFUND (deadline=0 to skip)
    function castVote(uint256 id, bool support, uint256 amount, PermitData calldata permit)
        external nonReentrant
    {
        if (id >= proposalCount) revert InvalidProposalId();
        Proposal storage p = proposals[id];
        if (p.cancelled) revert AlreadyCancelled();
        if (block.timestamp > p.votingDeadline) revert VotingAlreadyEnded();
        if (amount == 0) revert InsufficientLock();

        if (permit.deadline > 0) {
            try IERC20Permit(address(hfund)).permit(
                msg.sender, address(this), amount,
                permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }
        hfund.transferFrom(msg.sender, address(this), amount);

        if (support) { lockedFor[id][msg.sender]     += amount; p.votesFor     += amount; }
        else          { lockedAgainst[id][msg.sender] += amount; p.votesAgainst += amount; }

        emit VoteCast(id, msg.sender, support, amount);
    }

    // ─── 3. Execute ───────────────────────────────────────────────────────────

    /// @notice Execute after timelock passes. Anyone can call.
    ///
    ///  Flow for GoShort / GoLong:
    ///    1. revokeActiveMode()   — stop new auto-deploys immediately
    ///    2. closeAllShorts()     — close all existing short positions (up to 20 per call)
    ///       If > 20 positions remain, reverts with OpenPositionsRemain — call closeAllShorts()
    ///       on the vault directly (via guardian/leader) then re-call execute().
    ///    3. setActiveMode(new)   — start new direction
    ///
    ///  Flow for Exit:
    ///    1. revokeActiveMode()
    ///    2. closeAllShorts()
    function execute(uint256 id) external nonReentrant {
        ProposalState s = state(id);
        if (s == ProposalState.Active)    revert VotingStillActive();
        if (s == ProposalState.Defeated)  revert ProposalDefeated();
        if (s == ProposalState.Executed)  revert AlreadyExecuted();
        if (s == ProposalState.Cancelled) revert AlreadyCancelled();
        if (block.timestamp < proposals[id].timelockEnd) revert TimelockNotExpired();

        Direction dir      = proposals[id].direction;
        uint8     assetIdx = proposals[id].assetIndex;

        // Step 1: stop current mode to prevent new auto-deploys
        vault.revokeActiveMode();

        // Step 2: close all existing positions before switching direction.
        vault.closeAllShorts();
        vault.closeAllLongs();

        // Step 3: set new direction (skip for Exit)
        proposals[id].executed = true;

        if (dir != Direction.Exit) {
            AssetConfig storage cfg = assetConfigs[assetIdx];
            if (!cfg.configured) revert NotConfigured();
            vault.setActiveMode(
                dir == Direction.GoShort,
                cfg.asset, cfg.debtToken, cfg.pricingPool,
                cfg.assetIsToken1, cfg.poolFee, cfg.assetDecimals,
                cfg.deployRatioBps, cfg.borrowRatioBps,
                modeDuration
            );
        }

        emit ProposalExecuted(id, dir, assetIdx);
    }

    // ─── 4. Reclaim ───────────────────────────────────────────────────────────

    function reclaimVote(uint256 id) external nonReentrant {
        if (id >= proposalCount) revert InvalidProposalId();
        Proposal storage p = proposals[id];
        if (block.timestamp <= p.votingDeadline && !p.cancelled) revert VotingStillActive();

        uint256 total = lockedFor[id][msg.sender] + lockedAgainst[id][msg.sender];
        if (total == 0) revert NothingToReclaim();

        lockedFor[id][msg.sender]     = 0;
        lockedAgainst[id][msg.sender] = 0;
        hfund.transfer(msg.sender, total);
        emit VoteReclaimed(id, msg.sender, total);
    }

    // ─── Cancel ───────────────────────────────────────────────────────────────

    function cancel(uint256 id) external {
        if (id >= proposalCount) revert InvalidProposalId();
        Proposal storage p = proposals[id];
        if (msg.sender != p.proposer) revert NotProposer();
        if (p.executed)  revert AlreadyExecuted();
        if (p.cancelled) revert AlreadyCancelled();
        p.cancelled = true;
        emit ProposalCancelled(id);
    }
}
