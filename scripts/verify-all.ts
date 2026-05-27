/**
 * verify-all.ts
 * Verify all HypersFun contracts on OKLink (X Layer explorer)
 *
 * Prerequisites:
 *   1. OKLINK_API_KEY in .env  →  https://www.oklink.com/account/my-api
 *   2. npm install
 *   3. npx hardhat run scripts/verify-all.ts --network xLayerMainnet
 */

import { run } from "hardhat";

// ─── Deployed addresses ───────────────────────────────────────────────────────
const VAULT       = "0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634";
const HOOK        = "0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8";
const GOV         = "0xB001f47909285ef2E72fB2816D2d771F20425ef4";
const SWAP_HELPER = "0x1c4450C6864078d92bd67622f28eB77D2bed065B";

// ─── Shared constants (must match deploy-xlayer.ts) ───────────────────────────
const POOL_MANAGER = "0x360e68faccca8ca495c1b759fd9eee466db9fb32";
const USDC         = "0x74b7F16337b8972027F6196A17a631aC6dE26d22";
const DEPLOYER     = "0xe8900BFdB3AaaD4F472479f6d430eB39CbaBfa9F";
const PERF_FEE     = 1000; // 10%

async function verify(address: string, contract: string, args: unknown[]) {
  console.log(`\nVerifying ${contract} at ${address}…`);
  try {
    await run("verify:verify", {
      address,
      contract,
      constructorArguments: args,
    });
    console.log(`  ✓ ${contract} verified`);
  } catch (e: any) {
    if (e.message?.toLowerCase().includes("already verified")) {
      console.log(`  ✓ ${contract} already verified`);
    } else {
      console.error(`  ✗ ${contract} failed:`, e.message?.slice(0, 200));
    }
  }
}

async function main() {
  console.log("=== HypersFun Contract Verification ===");
  console.log("Network: X Layer Mainnet (Chain ID 196)");

  // 1. HyperFunMath — internal library linked into HypersFunHook (not standalone)
  //    No separate address; it's already included in the HypersFunHook verification above.

  // 2. FundVault
  await verify(VAULT, "contracts/FundVault.sol:FundVault", [
    "HypersFun USDC Fund", // name_
    "HFUND",               // symbol_
    USDC,                  // usdc_
    DEPLOYER,              // leader_
    DEPLOYER,              // treasury_
    POOL_MANAGER,          // poolManager_
    PERF_FEE,              // performanceFeeBps_
    0,                     // maxSupply_ (0 = no cap)
    0,                     // initialPriceE18_ (0 → defaults to 1e18 = $1)
  ]);

  // 3. HypersFunHook (deployed via Create2 — same args)
  await verify(HOOK, "contracts/HypersFunHook.sol:HypersFunHook", [
    POOL_MANAGER, // poolManager_
    VAULT,        // vault_
    USDC,         // usdc_
    DEPLOYER,     // treasury_
    DEPLOYER,     // owner_
  ]);

  // 4. SwapHelper
  await verify(SWAP_HELPER, "contracts/SwapHelper.sol:SwapHelper", [
    POOL_MANAGER, // poolManager_
  ]);

  // 5. VaultGovernance
  await verify(GOV, "contracts/VaultGovernance.sol:VaultGovernance", [
    VAULT,    // hfund_
    VAULT,    // vault_
    DEPLOYER, // admin_
  ]);

  console.log("\n=== Done ===");
  console.log("View on explorer: https://www.oklink.com/xlayer/address/" + VAULT);
}

main().catch((e) => { console.error(e); process.exit(1); });
