/**
 * deploy-and-wire-xlayer.ts
 * Full deploy + setup in one script. Replaces deploy-xlayer.ts + setup-new-deployment.ts.
 *
 * Steps:
 *   1. Deploy FundVault
 *   2. Mine CREATE2 salt → Deploy HypersFunHook
 *   3. vault.setHook(hook)
 *   4. hook.setPendingCurve(10000, 10000)
 *   5. PoolManager.initialize → afterInitialize auto-seeds curve
 *   6. hook.initializeCurve(21M, 21M) → set final depth
 *   7. Deploy SwapHelper
 *   8. Deploy VaultGovernance
 *   9. vault.setGovernance(gov)
 *  10. vault.setApprovedShortAsset × 3
 *  11. gov.setAssetConfig × 3 (correct poolFee=500, assetIsToken1)
 *  12. gov.setGovParams(2min voting, 1min timelock)
 *  13. Print all addresses
 *
 * Usage:
 *   npx hardhat run scripts/deploy-and-wire-xlayer.ts --network xLayerMainnet
 */

import { ethers } from "hardhat";

// ─── X Layer Mainnet fixed addresses ─────────────────────────────────────────
const POOL_MANAGER = "0x360e68faccca8ca495c1b759fd9eee466db9fb32";
const USDC         = "0x74b7F16337b8972027F6196A17a631aC6dE26d22";
const C2D_ADDR     = "0x05DAcBF5f2D4C55B9A11e4D670C1588FD47fA12F"; // existing Create2Deployer

// ─── Fund parameters ──────────────────────────────────────────────────────────
const FUND_NAME         = "HypersFun USDC Fund";
const FUND_SYMBOL       = "HFUND";
const PERF_FEE          = 1000n;                          // 10%
const INITIAL_PRICE_E18 = 1_000_000_000_000_000n;        // $0.001/HFUND
const MAX_SUPPLY        = 21_000_000n * 10n ** 18n;       // 21M HFUND

// ─── Curve depth ──────────────────────────────────────────────────────────────
const CURVE_SEED  = ethers.parseEther("10000");    // initial seed via afterInitialize
const CURVE_DEPTH = ethers.parseEther("21000000"); // final depth after setup

// ─── Hook flag bits ───────────────────────────────────────────────────────────
const HOOK_FLAGS = BigInt("0x2AC8");
const HOOK_MASK  = BigInt("0x3FFF");

// ─── Pool init ────────────────────────────────────────────────────────────────
const SQRT_PRICE_X96 = BigInt("79228162514264337593543950336");

// ─── Short assets (poolFee=500 confirmed on-chain; assetIsToken1 verified) ───
const SHORT_ASSETS = [
  {
    symbol:        "xBTC",
    asset:         "0xb7C00000bcDEeF966b20B3D884B98E64d2b06b4f",
    debtToken:     "0x5F874396f28dfdBd6bA2be80F52FD013Ce388C75",
    pricingPool:   "0x5fcFb33C9AB1665FeE892eB2aF163e863a874D73",
    assetIsToken1: true,   // USDT=token0 on xBTC pool
    poolFee:       500,    // confirmed on-chain (was wrong 3000 before)
    decimals:      8,
    deployRatioBps: 5000,
    borrowRatioBps: 7000,
  },
  {
    symbol:        "xSOL",
    asset:         "0x505000008DE8748DBd4422ff4687a4FC9bEba15b",
    debtToken:     "0x4aF568Cb78Ade0e45E42f9B6d3deC0ff81E788af",
    pricingPool:   "0x4651300221f345a4c6F566079BD1DDC291049c7d",
    assetIsToken1: false,  // xSOL=token0
    poolFee:       500,
    decimals:      9,
    deployRatioBps: 5000,
    borrowRatioBps: 7000,
  },
  {
    symbol:        "xETH",
    asset:         "0xE7B000003A45145decf8a28FC755aD5eC5EA025A",
    debtToken:     "0xB756Fc7065369602f2cCb8356283E8b997fDfe2a",
    pricingPool:   "0x77ef18adF35f62B2Ad442e4370cDbC7fe78B7dcC",
    assetIsToken1: true,   // USDT=token0 on xETH pool
    poolFee:       500,
    decimals:      18,
    deployRatioBps: 5000,
    borrowRatioBps: 7000,
  },
];

// ─── Governance params ────────────────────────────────────────────────────────
const VOTING_PERIOD   = 2 * 60;  // 2 minutes
const TIMELOCK_DELAY  = 1 * 60;  // 1 minute
const QUORUM_BPS      = 0;       // unchanged
const MIN_PROPOSER    = 0;       // unchanged

// ─── ABIs ─────────────────────────────────────────────────────────────────────
const GOV_ABI = [
  "function setAssetConfig(uint8 index, address asset, address debtToken, address pricingPool, bool assetIsToken1, uint24 poolFee, uint8 assetDecimals, uint256 deployRatioBps, uint256 borrowRatioBps) external",
  "function setGovParams(uint256 votingPeriod_, uint256 timelockDelay_, uint256 quorumBps_, uint256 minProposerLock_) external",
  "function assetConfigCount() view returns (uint8)",
  "function votingPeriod() view returns (uint256)",
  "function timelockDelay() view returns (uint256)",
];
const HOOK_ABI = [
  "function initializeCurve(uint256 initialBase, uint256 initialTokens) external",
  "function setPendingCurve(uint256 base, uint256 tokens) external",
  "function curveBase() view returns (uint256)",
  "function curveTokens() view returns (uint256)",
  "function currentBuyPrice() view returns (uint256)",
];
const VAULT_ABI = [
  "function setHook(address hook_) external",
  "function setGovernance(address gov_) external",
  "function setApprovedShortAsset(address asset, bool approved) external",
];

// ─────────────────────────────────────────────────────────────────────────────

async function findSalt(c2dAddr: string, initCodeHash: string): Promise<bigint> {
  console.log("  Mining CREATE2 salt (up to 500,000 values)…");
  for (let i = 0n; i < 500_000n; i++) {
    const saltHex = "0x" + i.toString(16).padStart(64, "0");
    const hash = ethers.keccak256(
      "0x" + "ff"
      + c2dAddr.slice(2).toLowerCase().padStart(40, "0")
      + saltHex.slice(2).padStart(64, "0")
      + initCodeHash.slice(2)
    );
    const addrBig = BigInt("0x" + hash.slice(-40));
    if ((addrBig & HOOK_MASK) === HOOK_FLAGS) {
      console.log(`  ✓ Found salt i=${i}  hook addr: 0x${hash.slice(-40)}`);
      return i;
    }
    if (i % 50_000n === 0n && i > 0n) process.stdout.write(`  … tried ${i.toLocaleString()}\n`);
  }
  throw new Error("Salt not found in 500,000 iterations");
}

async function main() {
  const [signer] = await ethers.getSigners();
  const deployer  = await signer.getAddress();
  console.log("Deployer:", deployer);
  console.log("Network :", (await ethers.provider.getNetwork()).name);

  const okbBal = await ethers.provider.getBalance(deployer);
  console.log("OKB bal :", ethers.formatEther(okbBal));
  if (okbBal < ethers.parseEther("0.05")) throw new Error("Insufficient OKB");

  // ── 1. Deploy FundVault ─────────────────────────────────────────────────────
  // Already deployed — reuse existing address
  const vaultAddr = "0x970355a07E00F8a50Ea9B531ba9d1307C58A12cf";
  console.log("\n[1/12] FundVault already deployed:", vaultAddr);
  const vault = await ethers.getContractAt("FundVault", vaultAddr);

  // ── 2. Hook already deployed ───────────────────────────────────────────────
  const hookAddr = "0x77802d04b223e2faA7B10F032A1DD9e9BBFd2Ac8";
  console.log("\n[2/12] Hook already deployed:", hookAddr);

  // ── 3. setHook already done ────────────────────────────────────────────────
  console.log("\n[3/12] vault.setHook already done (skipping)");
  const vaultForSetup = new ethers.Contract(vaultAddr, VAULT_ABI, signer);

  // ── 4. (skipped — PROD Hook has no setPendingCurve) ─────────────────────────
  console.log("\n[4/12] skipped (no setPendingCurve in this version)");
  const hook = new ethers.Contract(hookAddr, HOOK_ABI, signer);

  // ── 5. Initialize V4 pool ──────────────────────────────────────────────────
  console.log("\n[5/12] Initialize V4 pool…");
  const fundAddrLow = vaultAddr.toLowerCase();
  const usdcAddrLow = USDC.toLowerCase();
  const currency0   = fundAddrLow < usdcAddrLow ? vaultAddr : USDC;
  const currency1   = fundAddrLow < usdcAddrLow ? USDC : vaultAddr;
  const poolKey     = { currency0, currency1, fee: 0, tickSpacing: 60, hooks: hookAddr };
  const pm = await ethers.getContractAt(
    ["function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24 tick)"],
    POOL_MANAGER
  );
  await (await pm.initialize(poolKey, SQRT_PRICE_X96, { gasLimit: 1_000_000n })).wait();
  console.log("  ✓ Pool initialized");
  console.log("    currency0:", currency0);
  console.log("    currency1:", currency1);

  // ── 6. Set final curve depth 21M ──────────────────────────────────────────
  console.log("\n[6/12] hook.initializeCurve(21M)…");
  await (await hook.initializeCurve(CURVE_DEPTH, CURVE_DEPTH, { gasLimit: 200_000n })).wait();
  console.log("  curveBase  :", ethers.formatEther(await hook.curveBase()));
  console.log("  curveTokens:", ethers.formatEther(await hook.curveTokens()));
  console.log("  buyPrice   :", ethers.formatEther(await hook.currentBuyPrice()), "USDC/HFUND");

  // ── 7. Deploy SwapHelper ──────────────────────────────────────────────────
  console.log("\n[7/12] Deploying SwapHelper…");
  const SwapHelper = await ethers.getContractFactory("SwapHelper");
  const swapHelper = await SwapHelper.deploy(POOL_MANAGER);
  await swapHelper.waitForDeployment();
  const swapHelperAddr = await swapHelper.getAddress();
  console.log("  SwapHelper:", swapHelperAddr);

  // ── 8. Deploy VaultGovernance ─────────────────────────────────────────────
  console.log("\n[8/12] Deploying VaultGovernance…");
  const VaultGovernance = await ethers.getContractFactory("VaultGovernance");
  const gov = await VaultGovernance.deploy(vaultAddr, vaultAddr, deployer);
  await gov.waitForDeployment();
  const govAddr = await gov.getAddress();
  console.log("  VaultGovernance:", govAddr);

  // ── 9. Wire governance to vault ────────────────────────────────────────────
  console.log("\n[9/12] vault.setGovernance…");
  await (await vaultForSetup.setGovernance(govAddr)).wait();
  console.log("  ✓ done");

  // ── 10. Approve short assets ───────────────────────────────────────────────
  console.log("\n[10/12] Approving short assets…");
  for (const a of SHORT_ASSETS) {
    await (await vaultForSetup.setApprovedShortAsset(a.asset, true, { gasLimit: 100_000n })).wait();
    console.log(`  ✓ ${a.symbol} approved`);
  }

  // ── 11. Set asset configs (correct poolFee=500, assetIsToken1) ─────────────
  console.log("\n[11/12] Setting governance assetConfigs…");
  const govContract = new ethers.Contract(govAddr, GOV_ABI, signer);
  for (let i = 0; i < SHORT_ASSETS.length; i++) {
    const a = SHORT_ASSETS[i];
    await (await govContract.setAssetConfig(
      i, a.asset, a.debtToken, a.pricingPool,
      a.assetIsToken1, a.poolFee, a.decimals,
      a.deployRatioBps, a.borrowRatioBps,
      { gasLimit: 300_000n }
    )).wait();
    console.log(`  ✓ assetConfig[${i}] (${a.symbol}) fee=${a.poolFee} isToken1=${a.assetIsToken1}`);
  }
  console.log("  assetConfigCount:", (await govContract.assetConfigCount()).toString());

  // ── 12. Set governance timing params ──────────────────────────────────────
  console.log("\n[12/13] gov.setGovParams (2min voting, 1min timelock)…");
  await (await govContract.setGovParams(VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, MIN_PROPOSER, { gasLimit: 200_000n })).wait();
  console.log("  votingPeriod :", (await govContract.votingPeriod()).toString(), "s");
  console.log("  timelockDelay:", (await govContract.timelockDelay()).toString(), "s");

  // ── 13. Disable per-tx cap ────────────────────────────────────────────────
  // Default maxTxBps=100 (1% NAV) blocks ALL txs on fresh vault (NAV=0).
  console.log("\n[13/13] hook.setParams — disable maxTxBps…");
  const [fee, maxP, maxD, maxSP, maxBC, , minDep2] = await Promise.all([
    hook.tradingFeeBps?.() ?? 100n, hook.maxPremiumBps?.() ?? 20000n, hook.maxDiscountBps?.() ?? 5000n,
    hook.maxSellPremiumBps?.() ?? 200n, hook.maxBcRatioBps?.() ?? 18000n,
    hook.maxTxBps?.() ?? 100n, hook.minDepositUsdc6?.() ?? 100000n
  ]);
  const hookFull = new ethers.Contract(hookAddr, [
    "function setParams(uint256,uint256,uint256,uint256,uint256,uint256,uint256) external",
    "function tradingFeeBps() view returns (uint256)",
    "function maxPremiumBps() view returns (uint256)",
    "function maxDiscountBps() view returns (uint256)",
    "function maxSellPremiumBps() view returns (uint256)",
    "function maxBcRatioBps() view returns (uint256)",
    "function maxTxBps() view returns (uint256)",
    "function minDepositUsdc6() view returns (uint256)",
  ], signer);
  const [f2,p2,d2,sp2,bc2,,md2] = await Promise.all([
    hookFull.tradingFeeBps(), hookFull.maxPremiumBps(), hookFull.maxDiscountBps(),
    hookFull.maxSellPremiumBps(), hookFull.maxBcRatioBps(), hookFull.maxTxBps(), hookFull.minDepositUsdc6()
  ]);
  await (await hookFull.setParams(f2, p2, d2, sp2, bc2, 0n, md2, { gasLimit: 200_000n })).wait();
  console.log("  ✓ maxTxBps set to 0 (no per-tx cap)");

  // ── Summary ────────────────────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════════╗");
  console.log("║          DEPLOYMENT COMPLETE                 ║");
  console.log("╠══════════════════════════════════════════════╣");
  console.log(`  FundVault       : ${vaultAddr}`);
  console.log(`  HypersFunHook   : ${hookAddr}`);
  console.log(`  SwapHelper      : ${swapHelperAddr}`);
  console.log(`  VaultGovernance : ${govAddr}`);
  console.log(`  PoolManager     : ${POOL_MANAGER}`);
  console.log(`  USDC            : ${USDC}`);
  console.log("╠══════════════════════════════════════════════╣");
  console.log("║  UPDATE src/config.ts with these addresses!  ║");
  console.log("╚══════════════════════════════════════════════╝");
  console.log("\n⚠  Seed via SwapHelper (Trade page), NOT vault.depositUsdc()");
  console.log("   This ensures totalMintedFair is correctly tracked.");
}

main().catch(e => { console.error(e); process.exit(1); });
