# OKHypersFun — On-Chain Fund Platform Powered by Uniswap V4 Hook

> **Build-X Hackathon submission** — X Layer × Uniswap V4 Hook Track

**Live Frontend (X Layer):** https://xlayer.hypers.fun/

HypersFun is a fully on-chain, permissionless fund management platform built on top of **Uniswap V4's Hook mechanism**, deployed on **X Layer Mainnet**. Investors buy and sell fund shares (HFUND) directly through a Uniswap V4 pool, with pricing, fee collection, NAV accounting, and strategy governance all managed transparently on-chain — no centralised fund manager required.

> **Origin:** HypersFun was originally built and production-tested on **HyperEVM**, where we validated the core product idea — on-chain fund management with bonding-curve pricing, tiered exit fees, and community governance. Having proven the concept in a live environment, we rebuilt the architecture natively around **Uniswap V4 Hooks** and brought it to X Layer, leveraging V4's customisable pool logic and X Layer's low-cost EVM infrastructure.

> **Origin:** HypersFun was originally conceived and battle-tested on **HyperEVM**, where we validated the core product idea — on-chain fund management with a bonding-curve pricing engine, tiered exit fees, and investor governance. After proving the concept in production, we rebuilt the architecture natively around **Uniswap V4 Hooks** and deployed to X Layer, taking full advantage of V4's customisable pool logic and X Layer's low-cost EVM environment.

---

## The Problem

Traditional DeFi liquidity pools price assets with constant-product formulas (x·y=k), which cannot reflect the true value of a managed fund. Fund shares should track **Net Asset Value (NAV)** — not arbitrary market sentiment. Existing solutions either rely on centralised custodians or expose investors to exploitable price manipulation. There is no native way in DeFi to create a fund where:

- Share price is always anchored to verified on-chain NAV
- Investors can freely enter and exit via a DEX
- Fund strategy is governed by the investors themselves

---

## The Solution — HypersFun Hook

HypersFun introduces a **custom Uniswap V4 Hook** that intercepts every swap in the HFUND/USDC pool and overrides the pricing engine with real-time NAV data. This creates a new type of liquidity pool that functions as a **fund subscription and redemption window** — rather than a speculative trading venue.

### How it works

```
Investor (USDC)
       │
       │  swap USDC → HFUND  (buy shares)
       ▼
┌─────────────────────────────────────────────┐
│          Uniswap V4 PoolManager             │
│                                             │
│  beforeSwap ──► HypersFunHook               │
│                  │                          │
│                  ├─ Read NAV from FundVault │
│                  ├─ Bonding-curve depth     │
│                  └─ Override swap price     │
│                                             │
│  afterSwap ───► Collect fees → FundVault    │
└─────────────────────────────────────────────┘
       │
       ▼
FundVault  (mint HFUND shares at NAV price)
       │
       ▼
VaultGovernance  (HFUND holders propose & vote on strategy)
       │
       ▼
Community-approved strategy execution
```

---

## Key Innovations

### 1. NAV-Anchored Pricing Inside a V4 Hook

Most V4 Hook projects adjust fee tiers or add limit-order logic on top of the standard AMM. HypersFun goes further — the Hook **completely overrides the swap price** using the vault's real-time NAV per share. The custom `HyperFunMath` library computes each swap output based on:

- Current on-chain NAV (total assets / total supply)
- Virtual bonding-curve depth to provide slippage resistance on large orders
- TWAP (10-minute time-weighted average) to prevent flash-loan NAV manipulation

This is the first implementation of **NAV-anchored pricing delivered natively through a V4 Hook**.

### 2. Bonding-Curve + NAV Hybrid AMM

Pure NAV pricing would allow zero-cost arbitrage between NAV and market price. HypersFun combines NAV pricing with a **virtual bonding curve** that charges increasing slippage for larger orders. This:

- Discourages large flash-loan attacks against the fund
- Provides natural exit liquidity for redemptions of any size
- Self-adjusts as total deposits grow, without any external intervention

### 3. Tiered Exit Fees — Rewarding Long-Term Holders

A tiered redemption fee structure is enforced on-chain, keyed to how long each investor has held their shares:

| Holding Period | Exit Fee |
|---|---|
| < 7 days | 15% |
| 7 – 30 days | 8% |
| 30 – 90 days | 3% |
| > 90 days | 0% |

This eliminates short-term speculation and aligns investor incentives with the fund's long-term performance — a mechanism not previously available natively in DeFi fund infrastructure.

### 4. Gasless EIP-2612 Permit — One Signature, Full Flow

Investors never need to send a separate `approve` transaction. The buy flow uses **EIP-2612 off-chain permit signatures**: a single MetaMask signature authorises the exact USDC amount needed for the swap, which is consumed atomically in the same transaction. This reduces friction, lowers gas costs, and prevents over-approvals.

### 5. On-Chain Governance by Investors

Fund strategy changes require a quorum vote by HFUND holders via `VaultGovernance`. Investors:

- Lock HFUND tokens to submit proposals
- Vote for or against strategy changes (e.g. switching from active trading to passive mode)
- Execute passed proposals after a time-lock period

There is no centralised fund leader. Strategy is determined entirely by the community — enforced on-chain.

---

## Contracts (X Layer Mainnet — Chain ID 196)

| Contract | Address | Verified Source |
|---|---|---|
| **FundVault** (HFUND) | `0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634` | [OKLink](https://www.oklink.com/xlayer/address/0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634#code) |
| **HypersFunHook** | `0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8` | [OKLink](https://www.oklink.com/xlayer/address/0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8#code) |
| **VaultGovernance** | `0xB001f47909285ef2E72fB2816D2d771F20425ef4` | [OKLink](https://www.oklink.com/xlayer/address/0xB001f47909285ef2E72fB2816D2d771F20425ef4#code) |
| **SwapHelper** | `0x1c4450C6864078d92bd67622f28eB77D2bed065B` | [OKLink](https://www.oklink.com/xlayer/address/0x1c4450C6864078d92bd67622f28eB77D2bed065B#code) |

> All contracts are **open-source and verified** on OKLink. Anyone can audit the full logic.

### Uniswap V4 Pool Key

| Field | Value |
|---|---|
| currency0 (USDC) | `0x74b7F16337b8972027F6196A17a631aC6dE26d22` |
| currency1 (HFUND) | `0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634` |
| fee | `0` |
| tickSpacing | `60` |
| hooks | `0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8` |
| PoolManager | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |

---

## Contract Overview

### FundVault.sol
ERC-20 fund share token (HFUND) with EIP-2612 permit support. Manages:
- USDC deposits → HFUND minting at current NAV
- HFUND redemptions → USDC withdrawals with tiered exit fees
- NAV per share calculation (total USDC assets / total HFUND supply)
- 10-minute TWAP to prevent flash-loan NAV manipulation
- Performance fee (10%) on profits, accrued to the treasury
- Hard supply cap and configurable initial price

### HypersFunHook.sol
The core V4 Hook. Implements `beforeSwap`, `afterSwap`, `beforeAddLiquidity`, and `beforeRemoveLiquidity` to:
- Replace Uniswap's standard x·y=k pricing with NAV-based bonding-curve math
- Enforce that all pool liquidity flows through the vault (no external LP positions)
- Collect trading fees and route them to FundVault
- Guard pool initialisation and curve parameters

### HyperFunMath.sol
Pure Solidity library containing all bonding-curve and swap math. Separated for clean auditability and potential reuse in other projects.

### SwapHelper.sol
Utility contract for external integrations. Wraps the Uniswap V4 `PoolManager.swap()` call with a clean interface for frontend and contract-to-contract interactions.

### VaultGovernance.sol
On-chain governance for the fund. HFUND holders:
- Lock a minimum token amount to create proposals
- Vote for/against within a voting window
- Execute approved proposals after a mandatory delay
- Supports configurable quorum (basis points of total supply)

---

## Long / Short Trading via Aave

HypersFun's fund vault is integrated with **Aave on X Layer** to enable fully on-chain leveraged long and short positions. The vault borrows assets through Aave's lending protocol to open directional trades — no centralised exchange or off-chain custody required.

### Supported Assets

| Asset | Long | Short |
|---|---|---|
| **xBTC** | ✓ | ✓ |
| **xETH** | ✓ | ✓ |
| **xSOL** | ✓ | ✓ |

### How it works

1. The vault supplies USDC as collateral to Aave
2. Aave issues a credit line against the collateral
3. The vault borrows the target asset (e.g. xBTC) to open a long, or borrows a stablecoin to short
4. Positions are managed on-chain; PnL accrues directly to the vault's NAV
5. All position changes require a **governance vote** — the community decides when to open, adjust, or close trades

This design means every trade is transparent, auditable, and governed by HFUND holders — not a single fund manager.

---

## Market Value

HypersFun addresses a real and underserved market:

- **Tokenised fund management** is one of the fastest-growing segments in RWA and on-chain finance
- Traditional on-chain funds (e.g. Yearn, dHEDGE) rely on custom AMM wrappers or centralised price feeds — not native DEX infrastructure
- By building natively on V4 Hooks, HypersFun gains composability with the entire Uniswap ecosystem from day one
- **Aave integration** unlocks real yield strategies (long/short xBTC, xETH, xSOL) that generate returns for HFUND holders
- The tiered exit-fee structure and governance model are designed to attract long-term capital, not short-term speculation
- X Layer's low gas fees make frequent NAV updates and small-ticket investments economically viable

---

## Development

### Prerequisites
- Node.js 18+
- OKB on X Layer for gas

### Setup
```bash
git clone https://github.com/leoyeungkm/HypersFun_Xlayer_Contract.git
cd HypersFun_Xlayer_Contract
npm install
cp .env.example .env
# Set XLAYER_PRIVATE_KEY in .env
```

### Compile
```bash
npx hardhat compile
```

### Verify on OKLink
```bash
npx hardhat run scripts/verify-all.ts --network xLayerMainnet
```

### .env Reference
```
XLAYER_PRIVATE_KEY=0x...        # deployer private key (needs OKB for gas)
```

---

## License

MIT
