# HypersFun — Uniswap V4 Hook on X Layer

HypersFun is a decentralised fund platform built on **Uniswap V4** and deployed on **X Layer Mainnet (Chain ID 196)**. Investors buy/sell fund shares (HFUND) through a custom V4 Hook that embeds a bonding-curve AMM and routes profits to an on-chain fund vault. Governance token holders can vote to change the fund's trading strategy.

---

## Deployed Contracts

| Contract | Address | Explorer |
|---|---|---|
| FundVault (HFUND) | `0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634` | [View](https://www.oklink.com/xlayer/address/0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634#code) |
| HypersFunHook | `0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8` | [View](https://www.oklink.com/xlayer/address/0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8#code) |
| VaultGovernance | `0xB001f47909285ef2E72fB2816D2d771F20425ef4` | [View](https://www.oklink.com/xlayer/address/0xB001f47909285ef2E72fB2816D2d771F20425ef4#code) |
| SwapHelper | `0x1c4450C6864078d92bd67622f28eB77D2bed065B` | [View](https://www.oklink.com/xlayer/address/0x1c4450C6864078d92bd67622f28eB77D2bed065B#code) |

> All contracts verified on [OKLink](https://www.oklink.com/xlayer).

---

## Architecture

```
User (USDC)
    │
    ▼
HypersFunHook  ◄──── Uniswap V4 PoolManager
    │  (bonding-curve pricing, fee collection)
    ▼
FundVault (ERC-20 / EIP-2612)
    │  (NAV accounting, TWAP, exit-fee tiers)
    ▼
VaultGovernance
    │  (proposals, quorum voting, mode changes)
    ▼
Fund Leader  ──►  External exchanges (trading)
```

### Contracts

| Contract | Description |
|---|---|
| **FundVault** | ERC-20 fund share token (HFUND). Tracks NAV per share, TWAP, performance fees, and tiered exit fees. Investors deposit USDC to mint shares and redeem shares for USDC. |
| **HypersFunHook** | Uniswap V4 Hook implementing `beforeSwap` / `afterSwap`. Embeds a virtual bonding-curve AMM so HFUND/USDC swaps price shares off on-chain NAV. Collects trading fees for the vault. |
| **HyperFunMath** | Pure library. Bonding-curve price and swap math used by HypersFunHook. |
| **SwapHelper** | Thin helper that wraps PoolManager swap calls for external integrations. |
| **VaultGovernance** | Token-weighted on-chain governance. HFUND holders lock tokens to propose and vote on fund-mode changes (e.g. active trading vs. passive). |

---

## Pool Key (X Layer Mainnet)

| Field | Value |
|---|---|
| currency0 | `0x74b7F16337b8972027F6196A17a631aC6dE26d22` (USDC) |
| currency1 | `0x750F9F25Bd7E4144077C8E8A22E6D4721ebB8634` (HFUND) |
| fee | `0` |
| tickSpacing | `60` |
| hooks | `0xe256dDe4e526ea7A01585c35B5B4e0861e642AC8` |
| PoolManager | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |

---

## Development

### Prerequisites

- Node.js 18+
- An X Layer wallet with OKB for gas
- An [OKLink API key](https://www.oklink.com/account/my-api) for verification

### Setup

```bash
npm install
cp .env.example .env
# Fill in XLAYER_PRIVATE_KEY and OKLINK_API_KEY
```

### Compile

```bash
npx hardhat compile
```

### Verify on OKLink

```bash
npx hardhat run scripts/verify-all.ts --network xLayerMainnet
```

---

## License

MIT
