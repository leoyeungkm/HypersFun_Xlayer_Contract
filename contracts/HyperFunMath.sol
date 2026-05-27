// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HyperFunMath
/// @notice Pure bonding-curve math for HypersFun V4 Hook on X Layer.
///         Ported from V3 HyperFunMath.sol — pure functions only.
library HyperFunMath {

    uint256 internal constant BPS       = 10_000;
    uint256 internal constant PRECISION = 1e18;

    // ─────────────────────────────────────────────────────────────────────────
    //  Buy: USDC in → FUND tokens out
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice x*y=k: compute tokens out for a USDC buy (after fee deduction).
    /// @param usdcIn          Gross USDC in (6-decimal)
    /// @param nav             NAV per share (1e18)
    /// @param effVirtualBase  Virtual USDC reserve (1e18, NAV-denominated)
    /// @param effVirtualTokens Virtual FUND reserve (1e18)
    /// @param maxPremiumBps   Max buy-price premium over NAV (e.g. 20000 = 2×)
    /// @param currentBuyPrice Current buy price before this trade (1e18)
    /// @return tokensOut      FUND out (1e18)
    /// @return newPrice       Price after trade (1e18 per FUND)
    /// @return priceImpactBps Price impact (bps)
    function calculateTokensOutPure(
        uint256 usdcIn,        // net of trading fee (6-decimal)
        uint256 nav,
        uint256 effVirtualBase,
        uint256 effVirtualTokens,
        uint256 maxPremiumBps,
        uint256 currentBuyPrice
    ) internal pure returns (
        uint256 tokensOut,
        uint256 newPrice,
        uint256 priceImpactBps
    ) {
        uint256 virtualBaseUsdc = (effVirtualBase * nav) / PRECISION;
        uint256 usdcIn18        = usdcIn * 1e12;

        // x*y=k
        tokensOut = (effVirtualTokens * usdcIn18) / (virtualBaseUsdc + usdcIn18);

        uint256 newVBase   = virtualBaseUsdc + usdcIn18;
        uint256 newVTokens = effVirtualTokens - tokensOut;

        if (newVTokens > 0) {
            newPrice = (newVBase * PRECISION) / newVTokens;
            uint256 maxPrice = (nav * (BPS + maxPremiumBps)) / BPS;
            if (newPrice > maxPrice) newPrice = maxPrice;
        } else {
            newPrice = (nav * (BPS + maxPremiumBps)) / BPS;
        }

        if (currentBuyPrice > 0 && newPrice > currentBuyPrice) {
            priceImpactBps = ((newPrice - currentBuyPrice) * BPS) / currentBuyPrice;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Sell: FUND tokens in → USDC out (gross, before fees)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice x*y=k: compute gross USDC out for a FUND sell.
    ///         Caller must apply NAV ceiling, exit fee, and trading fee afterwards.
    /// @param tokensIn        FUND tokens sold (1e18)
    /// @param nav             NAV per share (1e18)
    /// @param effVirtualBase  Virtual USDC reserve (1e18)
    /// @param effVirtualTokens Virtual FUND reserve (1e18)
    /// @param maxDiscountBps  Max sell-price discount below NAV (e.g. 5000 = 0.5×)
    /// @return grossUsdcOut   Gross USDC out BEFORE fees (6-decimal)
    /// @return newPrice       Price after trade (1e18)
    /// @return priceImpactBps Price impact (bps)
    function calculateUsdcOutPure(
        uint256 tokensIn,
        uint256 nav,
        uint256 effVirtualBase,
        uint256 effVirtualTokens,
        uint256 maxDiscountBps
    ) internal pure returns (
        uint256 grossUsdcOut,
        uint256 newPrice,
        uint256 priceImpactBps
    ) {
        uint256 virtualBaseUsdc = (effVirtualBase * nav) / PRECISION;
        uint256 usdcOut18 = (virtualBaseUsdc * tokensIn) / (effVirtualTokens + tokensIn);
        grossUsdcOut = usdcOut18 / 1e12;

        uint256 newVBase   = virtualBaseUsdc - usdcOut18;
        uint256 newVTokens = effVirtualTokens + tokensIn;

        newPrice = (newVBase * PRECISION) / newVTokens;
        uint256 minPrice = (nav * (BPS - maxDiscountBps)) / BPS;
        if (newPrice < minPrice) newPrice = minPrice;

        uint256 oldPrice = effVirtualTokens > 0
            ? (virtualBaseUsdc * PRECISION) / effVirtualTokens
            : 0;
        if (oldPrice > 0 && newPrice < oldPrice) {
            priceImpactBps = ((oldPrice - newPrice) * BPS) / oldPrice;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Inverse buy: back-calculate USDC needed for an exact token output
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Inverse of calculateTokensOutPure: given an exact `tokensOut` desired,
    ///         return the net USDC (6-dec) that must flow into the curve to receive exactly
    ///         that many tokens. Used for cap-bounded buys near maxSupply.
    ///
    ///  Forward:  tokensOut = (V * usdcIn18) / (B + usdcIn18)
    ///  Inverse:  usdcIn18  = (tokensOut * B) / (V - tokensOut)
    ///
    /// @param tokensOut       Desired FUND output (1e18) — must be < effVirtualTokens
    /// @param nav             NAV per share (1e18)
    /// @param effVirtualBase  Current virtual USDC reserve (1e18)
    /// @param effVirtualTokens Current virtual FUND reserve (1e18)
    /// @return netUsdc6       Net USDC (6-decimal) required (0 if tokensOut == 0)
    function backCalcNetUsdcForTokens(
        uint256 tokensOut,
        uint256 nav,
        uint256 effVirtualBase,
        uint256 effVirtualTokens
    ) internal pure returns (uint256 netUsdc6) {
        if (tokensOut == 0) return 0;
        // Degenerate: not enough virtual tokens to fill the order
        if (tokensOut >= effVirtualTokens) return type(uint256).max;
        uint256 virtualBaseUsdc = (effVirtualBase * nav) / PRECISION; // 1e18
        uint256 usdcIn18 = (tokensOut * virtualBaseUsdc) / (effVirtualTokens - tokensOut);
        netUsdc6 = usdcIn18 / 1e12;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Curve state update helpers (replicate V3 virtualBase/virtualTokens logic)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Compute new curve state after a buy.
    ///         Returns updated (newBase, newTokens) to persist in hook storage.
    /// @param curveBase       Current virtual USDC reserve (1e18, NAV-denominated)
    /// @param curveTokens     Current virtual FUND reserve (1e18)
    /// @param nav             NAV per share at time of trade (1e18)
    /// @param netUsdcIn       USDC net of trading fee (6-decimal)
    /// @param tokensOut       FUND minted (1e18)
    /// @param maxBcRatioBps   Max vBase/vTokens ratio in bps (0 = disabled)
    function updateCurveAfterBuy(
        uint256 curveBase,
        uint256 curveTokens,
        uint256 nav,
        uint256 netUsdcIn,
        uint256 tokensOut,
        uint256 maxBcRatioBps
    ) internal pure returns (uint256 newBase, uint256 newTokens) {
        uint256 virtualBaseUsdc = (curveBase * nav) / PRECISION;
        uint256 newVirtualBaseUsdc = virtualBaseUsdc + (netUsdcIn * 1e12);
        newBase   = (newVirtualBaseUsdc * PRECISION) / nav;
        newTokens = curveTokens > tokensOut ? curveTokens - tokensOut : 0;

        // Cap: vBase/vTokens <= maxBcRatioBps
        if (maxBcRatioBps > 0 && newTokens > 0) {
            uint256 ratio = (newBase * BPS) / newTokens;
            if (ratio > maxBcRatioBps) {
                newTokens = (newBase * BPS) / maxBcRatioBps;
            }
        }
    }

    /// @notice Compute new curve state after a sell.
    ///         exitFee stays in vault (not reflected in BC reserve change).
    /// @param curveBase       Current virtual USDC reserve (1e18, NAV-denominated)
    /// @param curveTokens     Current virtual FUND reserve (1e18)
    /// @param nav             NAV per share at time of trade (1e18)
    /// @param afterExitFee6   USDC gross out MINUS exit fee (6-decimal) — BC uses this
    /// @param tokensIn        FUND burned (1e18)
    function updateCurveAfterSell(
        uint256 curveBase,
        uint256 curveTokens,
        uint256 nav,
        uint256 afterExitFee6,
        uint256 tokensIn
    ) internal pure returns (uint256 newBase, uint256 newTokens) {
        uint256 virtualBaseUsdc = (curveBase * nav) / PRECISION;
        uint256 afterExitFee18  = afterExitFee6 * 1e12;
        uint256 newVirtualBaseUsdc = virtualBaseUsdc > afterExitFee18
            ? virtualBaseUsdc - afterExitFee18
            : 0;
        newBase   = (newVirtualBaseUsdc * PRECISION) / nav;
        newTokens = curveTokens + tokensIn;

        // Floor: vBase/vTokens >= 1.0 (prevents price < NAV)
        if (newBase > 0 && newTokens > 0) {
            uint256 ratio = (newBase * BPS) / newTokens;
            if (ratio < BPS) {
                newTokens = newBase; // floor at 1:1 ratio
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  NAV helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Raw NAV = totalAssets (1e18) / supply (1e18). Returns 1e18 when supply=0.
    function getRawNAV(uint256 totalAssets, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) return PRECISION;
        return (totalAssets * PRECISION) / supply;
    }

    /// @notice TWAP NAV: exponential decay toward instantNav.
    ///         Ported from V3 HyperFunMath.calcSmoothedNAV.
    ///         Only applies downward smoothing (instant rises pass through immediately).
    /// @param instantNav       Current raw NAV (1e18)
    /// @param storedTwapNav    Last stored TWAP NAV (1e18)
    /// @param storedTwapTime   Timestamp of last TWAP update
    /// @param halfLife         Half-life in seconds (0 → default 600s = 10 min)
    /// @param blockTimestamp   Current block.timestamp
    function calcSmoothedNAV(
        uint256 instantNav,
        uint256 storedTwapNav,
        uint256 storedTwapTime,
        uint256 halfLife,
        uint256 blockTimestamp
    ) internal pure returns (uint256) {
        if (storedTwapNav == 0 || storedTwapTime == 0) return instantNav;
        // If NAV rises: pass through immediately (buy protection not needed)
        if (instantNav >= storedTwapNav) return instantNav;

        uint256 elapsed = blockTimestamp - storedTwapTime;
        if (elapsed == 0) return storedTwapNav;

        uint256 hl  = halfLife > 0 ? halfLife : 600;
        uint256 gap = storedTwapNav - instantNav;
        uint256 periods   = elapsed / hl;
        uint256 remaining = elapsed % hl;

        if (periods > 0) {
            gap = periods >= 10 ? gap >> 10 : gap >> periods;
        }
        if (remaining > 0 && gap > 0) {
            uint256 partialReduction = (gap * remaining) / (hl * 2);
            gap = gap > partialReduction ? gap - partialReduction : 0;
        }
        return instantNav + gap;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Price helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current buy price from virtual reserves (1e18 per FUND).
    function getBuyPrice(
        uint256 nav,
        uint256 effVirtualBase,
        uint256 effVirtualTokens
    ) internal pure returns (uint256) {
        if (effVirtualTokens == 0) return nav;
        uint256 virtualBaseUsdc = (effVirtualBase * nav) / PRECISION;
        return (virtualBaseUsdc * PRECISION) / effVirtualTokens;
    }

    /// @notice Convert sqrtPriceX96 to price ratio (1e18).
    ///         result = (sqrtPriceX96 / 2^96)^2 * 1e18 = token1/token0 in 1e18.
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        // Prevent overflow: compute in two halves
        // price1e18 = sqrtP^2 * 1e18 / 2^192
        // = (sqrtP * sqrtP / 2^192) * 1e18
        // Use 256-bit intermediate: sqrtP^2 fits in 320 bits, need to shift
        return mulDiv(sqrtP * sqrtP, PRECISION, 1 << 192);
    }

    /// @notice Full-precision multiply then divide (512-bit intermediate).
    ///         Prevents overflow in sqrtPriceX96ToPrice.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // 512-bit multiply using 256-bit assembly
        uint256 prod0; uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) return prod0 / denominator;

        require(denominator > prod1, "MulDiv: overflow");

        uint256 remainder;
        assembly { remainder := mulmod(a, b, denominator) }
        assembly { prod1 := sub(prod1, gt(remainder, prod0)) }
        assembly { prod0 := sub(prod0, remainder) }

        uint256 twos = denominator & (~denominator + 1);
        assembly { denominator := div(denominator, twos) }
        assembly { prod0 := div(prod0, twos) }
        assembly { twos := add(div(sub(0, twos), twos), 1) }
        prod0 |= prod1 * twos;

        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;

        result = prod0 * inv;
    }
}
