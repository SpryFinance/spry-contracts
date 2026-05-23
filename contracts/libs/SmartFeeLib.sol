// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {E, wrap, unwrap} from "@prb/math/src/SD59x18.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {VirtualReserves} from "./VirtualReserves.sol";
import {SpryFeeParams} from "./SpryFeeTypes.sol";

/// @title SmartFeeLib
/// @notice Spry's dynamic fee curve, parameterized by tier. Given a pool's
///         current state, a pending swap, and a tier-specific parameter set,
///         returns the LP fee (in V4 pips) to charge for that swap. The
///         curve has four piecewise regions — safe (constant), alert
///         (linear ramp), danger (exponential ramp), cap (constant). Bounds
///         and coefficients are tier-specific; the structure is the same
///         for all tiers.
///
/// @dev    Returned fee is in V4 dynamic-fee pips (1_000_000 = 100%).
///         Callers passing the result back through V4's hook return
///         channel must OR in `LPFeeLibrary.OVERRIDE_FEE_FLAG (0x400000)`
///         before returning.
library SmartFeeLib {
    using SafeCast for *;

    /// @param sqrtPriceX96    pool's current price as Q64.96
    /// @param liquidity       pool's in-range liquidity (full-range == total)
    /// @param zeroForOne      true if swap is token0 -> token1
    /// @param amountSpecified V4 swap amountSpecified: negative = exactIn,
    ///                       positive = exactOut. Magnitude is the token amount.
    /// @param p               the tier's parameter set (zones + coefficients)
    /// @return fee V4 dynamic fee in pips (0..1_000_000). Caller must OR in
    ///             OVERRIDE_FEE_FLAG when returning from beforeSwap.
    /// @dev Degenerate-input fast-path: if either virtual reserve is zero
    ///      (pool initialized but no liquidity added yet) or the swap
    ///      specifies a zero amount, the function returns the tier's
    ///      `safeFee`. These inputs cannot produce a useful delta and V4
    ///      will reject the swap downstream; the conservative default makes
    ///      the override-fee return value well-defined regardless.
    function getDynamicFee(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne,
        int256 amountSpecified,
        SpryFeeParams memory p
    ) internal pure returns (uint24 fee) {
        int256 delta = computeSignedDelta(sqrtPriceX96, liquidity, zeroForOne, amountSpecified);
        if (delta == 0) return uint24(p.safeFee);
        return uint24(_feeForDelta(delta, p));
    }

    /// @notice Computes the signed per-mille reserve-shift indicator
    ///         ("delta") for a swap, given pool state and swap params.
    ///         Returned value:
    ///           positive  if the swap takes token0 out of the pool
    ///                     (price moves toward "more token0 needed")
    ///           negative  if the swap takes token1 out of the pool
    ///           0         if reserves or amount are zero
    /// @dev Used by SpryHook to feed the per-pool cumulative tracker
    ///      (the cumulative is the running sum of these signed deltas
    ///      within a block window).
    function computeSignedDelta(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne,
        int256 amountSpecified
    ) internal pure returns (int256) {
        (uint256 reserve0, uint256 reserve1) =
            VirtualReserves.fromState(sqrtPriceX96, liquidity);
        if (reserve0 == 0 || reserve1 == 0 || amountSpecified == 0) {
            return 0;
        }
        (uint256 amount0Out, uint256 amount1Out) =
            _outputAmounts(reserve0, reserve1, zeroForOne, amountSpecified);
        return _computeDelta(reserve0, reserve1, amount0Out, amount1Out);
    }

    /// @notice Public-equivalent helper: given a delta value already computed
    ///         externally, return the fee. Used by SpryHook's cumulative
    ///         path to evaluate the curve at the running cum value rather
    ///         than at the per-swap delta.
    function feeForDelta(int256 delta, SpryFeeParams memory p)
        internal
        pure
        returns (uint24)
    {
        if (delta == 0) return uint24(p.safeFee);
        return uint24(_feeForDelta(delta, p));
    }

    /// @dev Derives a single output amount from the V4 SwapParams. For
    ///      exact-input swaps it applies the no-fee constant-product output
    ///      formula to derive the implied output; for exact-output swaps it
    ///      uses the magnitude directly. Exactly one of the returned values
    ///      is non-zero.
    function _outputAmounts(
        uint256 reserve0,
        uint256 reserve1,
        bool zeroForOne,
        int256 amountSpecified
    ) private pure returns (uint256 amount0Out, uint256 amount1Out) {
        bool exactIn = amountSpecified < 0;
        uint256 mag = exactIn
            ? uint256(-amountSpecified)
            : uint256(amountSpecified);

        if (zeroForOne) {
            if (exactIn) {
                amount1Out = FullMath.mulDiv(mag, reserve1, reserve0 + mag);
            } else {
                amount1Out = mag;
            }
        } else {
            if (exactIn) {
                amount0Out = FullMath.mulDiv(mag, reserve0, reserve1 + mag);
            } else {
                amount0Out = mag;
            }
        }
    }

    /// @dev Computes the signed per-mille reserve-shift indicator.
    ///
    ///        amount0Out > 0  (token0 leaves the pool, e.g. one-for-zero):
    ///            delta = +(1000 * amount0Out) / reserve0
    ///
    ///        amount1Out > 0  (token1 leaves the pool, e.g. zero-for-one):
    ///            delta = -(1000 * amount1Out) / (reserve1 + amount1Out)
    ///
    ///      The asymmetric algebra (one denominator includes the swap,
    ///      one doesn't) gives slightly different magnitudes on the +/− sides
    ///      of zero; each tier's safe/alert/danger boundaries are picked to
    ///      match that asymmetry (e.g. BLUE-CHIP's safe zone is [−250, +334]).
    function _computeDelta(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amount0Out,
        uint256 amount1Out
    ) private pure returns (int256 delta) {
        if (amount0Out != 0) {
            delta = int256((1000 * amount0Out) / reserve0);
        } else if (amount1Out != 0) {
            delta = -int256((1000 * amount1Out) / (reserve1 + amount1Out));
        }
        // else: delta = 0, caller's safeFee fast-path handled this
    }

    /// @dev Four-zone fee dispatch keyed on `delta` and tier params.
    function _feeForDelta(int256 delta, SpryFeeParams memory p)
        private
        pure
        returns (uint256)
    {
        if (delta >= int256(p.safeLow) && delta <= int256(p.safeHigh)) {
            return uint256(p.safeFee);
        } else if (delta >= int256(p.alertLow) && delta < int256(p.safeLow)) {
            return uint256(_linear(p.aLeft, p.bLeft, delta));
        } else if (delta > int256(p.safeHigh) && delta <= int256(p.alertHigh)) {
            return uint256(_linear(p.aRight, p.bRight, delta));
        } else if (delta >= int256(p.dangerLow) && delta < int256(p.alertLow)) {
            return _exp(p.aLeftExp, p.bLeftExp, delta);
        } else if (delta > int256(p.alertHigh) && delta <= int256(p.dangerHigh)) {
            return _exp(p.aRightExp, p.bRightExp, delta);
        } else {
            return uint256(p.capFee);
        }
    }

    /// @dev Linear-zone formula. Coefficients are tier-specific and tuned
    ///      so the result equals `safeFee` at safeLow/safeHigh and
    ///      `alertEdgeFee` at alertLow/alertHigh.
    ///
    ///      fee_pips = (a · delta + 1000 · b) / 1_000_000
    function _linear(int64 a, int64 b, int256 delta) private pure returns (int256) {
        return ((int256(a) * delta) + (1000 * int256(b))) / 1_000_000;
    }

    /// @dev Exponential-zone formula using PRB-Math SD59x18.
    ///
    ///      fee_pips = (a · exp(b · delta / 1000)) / 1e36
    ///
    ///      Computes the exp argument as `(b · delta) / 1000` directly in
    ///      raw int and wraps the result once — equivalent to but
    ///      strictly more precise than the SD59x18-native `wrap(b) ·
    ///      wrap(delta) / wrap(1000)` form, whose intermediate SD59x18
    ///      multiplication floor-divides by 1e18 and loses precision
    ///      for the typical (b ~ 1e17, delta ~ 1e3) magnitudes Spry
    ///      passes in. `_dangerArea` (which integrates this curve)
    ///      uses the same direct-raw form, so the two APIs now agree
    ///      to within a few pips across the full danger zone.
    function _exp(int128 a, int128 b, int256 delta) private pure returns (uint256) {
        int256 expArg = (int256(b) * delta) / 1000;
        return (uint256(int256(a)) *
            unwrap(E.pow(wrap(expArg))).toUint256())
            / (1e36).toUint256();
    }

    // =====================================================================
    // Integral / marginal-fee mode (path-independent dispatch)
    //
    // SpryHook charges a marginal fee that is independent of how a same-
    // trajectory cumulative move is sliced into individual swaps. The
    // marginal fee is the time-average of the underlying piecewise fee curve
    // over the cumulative interval the swap moves through:
    //
    //       marginal_fee = ∫_{cumBefore}^{cumAfter} feeRate(x) dx
    //                      ───────────────────────────────────────
    //                              cumAfter − cumBefore
    //
    // The integral telescopes (F(c_n) − F(c_0) regardless of any intermediate
    // splits), so splitting a same-side same-direction swap into N pieces
    // costs the exact same total fee as one big swap — closing the sub-
    // window splitting loophole an end-rate rule would leave open.
    //
    // The SIGN-FLIP half of a swap (cumulative crossing zero) is charged at
    // `safeFee` for the unwind portion — that side is a benefit to LPs
    // (pool brought toward neutral), not a cost being amortized.
    // =====================================================================

    /// @notice Path-independent average fee for a swap that shifts the
    ///         pool's cumulative from `cumBefore` to `cumAfter`. Returns
    ///         the integral of the tier's fee curve over the interval,
    ///         divided by the interval length, in V4 pips.
    ///
    /// @dev    Three cases:
    ///           - GROWTH  (same sign, |after| > |before|): marginal =
    ///             ∫_{|before|}^{|after|} curve / (|after| − |before|)
    ///           - UNWIND  (same sign, |after| ≤ |before|): safeFee
    ///           - FLIP    (opposite strict signs): weighted average of
    ///             safeFee over the unwind half and the integral over the
    ///             growth half.
    ///
    ///         Caller (SpryHook) must OR `OVERRIDE_FEE_FLAG` into the
    ///         returned uint24 before passing it back through V4.
    function marginalFee(int256 cumBefore, int256 cumAfter, SpryFeeParams memory p)
        internal
        pure
        returns (uint24)
    {
        if (cumBefore == cumAfter) return uint24(p.safeFee);

        uint256 absBefore = cumBefore >= 0 ? uint256(cumBefore) : uint256(-cumBefore);
        uint256 absAfter  = cumAfter  >= 0 ? uint256(cumAfter)  : uint256(-cumAfter);

        bool flipped = (cumBefore > 0 && cumAfter < 0) || (cumBefore < 0 && cumAfter > 0);

        if (!flipped) {
            if (absAfter > absBefore) {
                // GROWTH: integrate from |before| to |after| on the
                // appropriate side (the one either cumulative endpoint is
                // strictly positive on, defaulting to left when both are
                // non-positive).
                bool right = (cumAfter > 0) || (cumBefore > 0);
                uint256 area = _integral(absBefore, absAfter, p, right);
                return uint24(area / (absAfter - absBefore));
            } else {
                // UNWIND.
                return uint24(p.safeFee);
            }
        } else {
            // FLIP: unwind half at safeFee, growth half integrated on the
            // side cumAfter lands on.
            bool rightAfter = (cumAfter > 0);
            uint256 areaGrowth = _integral(0, absAfter, p, rightAfter);
            uint256 areaUnwind = uint256(p.safeFee) * absBefore;
            return uint24((areaUnwind + areaGrowth) / (absBefore + absAfter));
        }
    }

    /// @dev Piecewise definite integral of the fee curve over [y0, y1] on
    ///      one side of the curve. Both bounds are positive magnitudes —
    ///      `right == true` integrates over deltas +[y0,y1]; `right == false`
    ///      integrates over deltas −[y1,y0] (the symmetric range on the
    ///      negative side). Stitches the integral across safe → alert →
    ///      danger → cap zones as needed; only the zones the [y0,y1]
    ///      interval intersects actually call out to the underlying
    ///      antiderivative helper.
    ///
    ///      Result units: pips · delta. The caller divides by the interval
    ///      length (in delta units) to recover a pips-only marginal rate.
    function _integral(uint256 y0, uint256 y1, SpryFeeParams memory p, bool right)
        private
        pure
        returns (uint256 area)
    {
        if (y0 == y1) return 0;

        uint256 safeEnd   = right ? uint256(int256(p.safeHigh))   : uint256(-int256(p.safeLow));
        uint256 alertEnd  = right ? uint256(int256(p.alertHigh))  : uint256(-int256(p.alertLow));
        uint256 dangerEnd = right ? uint256(int256(p.dangerHigh)) : uint256(-int256(p.dangerLow));

        // Safe zone [0, safeEnd]: constant safeFee.
        if (y0 < safeEnd) {
            uint256 end = y1 < safeEnd ? y1 : safeEnd;
            area += uint256(p.safeFee) * (end - y0);
            if (end == y1) return area;
            y0 = end;
        }

        // Alert zone (safeEnd, alertEnd]: linear curve.
        if (y0 < alertEnd) {
            uint256 end = y1 < alertEnd ? y1 : alertEnd;
            area += _alertArea(y0, end, p, right);
            if (end == y1) return area;
            y0 = end;
        }

        // Danger zone (alertEnd, dangerEnd]: exponential curve.
        if (y0 < dangerEnd) {
            uint256 end = y1 < dangerEnd ? y1 : dangerEnd;
            area += _dangerArea(y0, end, p, right);
            if (end == y1) return area;
            y0 = end;
        }

        // Cap zone (dangerEnd, ∞): constant capFee.
        area += uint256(p.capFee) * (y1 - y0);
    }

    /// @dev Antiderivative of the linear alert-zone curve, evaluated between
    ///      [y0, y1]:
    ///
    ///        right (delta = +y, aR > 0, bR < 0):
    ///          feeRate(y) = (aR·y + 1000·bR) / 1e6
    ///        left  (delta = −y, aL < 0, bL < 0):
    ///          feeRate(−y) = (−aL·y + 1000·bL) / 1e6
    ///
    ///      Substituting a := aR (right) or −aL (left, always positive) and
    ///      b := bR (right) or bL (left, always negative), both sides share
    ///      the form (a·y + 1000·b)/1e6, whose antiderivative is:
    ///
    ///        F(y) = (a·y²/2 + 1000·b·y) / 1e6
    ///
    ///      Returns F(y1) − F(y0). The fee curve is non-negative across the
    ///      alert zone in both tiers, so the integral is always ≥ 0.
    function _alertArea(uint256 y0, uint256 y1, SpryFeeParams memory p, bool right)
        private
        pure
        returns (uint256)
    {
        int256 a;
        int256 b;
        if (right) {
            a = int256(p.aRight);
            b = int256(p.bRight);
        } else {
            a = -int256(p.aLeft);   // aLeft is negative → a is positive
            b = int256(p.bLeft);    // bLeft is negative → keep as is
        }
        int256 yy0 = int256(y0);
        int256 yy1 = int256(y1);
        int256 raw = (a * (yy1 * yy1 - yy0 * yy0) / 2) + (1000 * b * (yy1 - yy0));
        return uint256(raw / int256(1_000_000));
    }

    /// @dev Antiderivative of the exponential danger-zone curve, evaluated
    ///      between [y0, y1] on the chosen side.
    ///
    ///      Real-number form:
    ///        feeRate(d) = (aExp/1e18) · exp(bExp · d / (1000·1e18))   (pips)
    ///        F(d)       = (aExp · 1000 / bExp) · exp(bExp · d / (1000·1e18))
    ///        ∫_{lo}^{hi} = F(hi) − F(lo)
    ///
    ///      Computational form, using SD59x18 raw values from PRB-Math:
    ///        expVal_i = unwrap(E.pow(wrap(bExp · d_i / 1000)))
    ///                 = exp(real_arg_i) · 1e18
    ///        F(d1) − F(d0)
    ///          = (aExp · 1000) · (expVal1 − expVal0) / (bExp · 1e18)
    ///
    ///      On the left side bExp < 0 and d_signed < 0, so the raw signed
    ///      result is negative — we take its magnitude (the integral of the
    ///      strictly positive fee curve over the interval).
    function _dangerArea(uint256 y0, uint256 y1, SpryFeeParams memory p, bool right)
        private
        pure
        returns (uint256)
    {
        if (y0 == y1) return 0;

        int128 aExp;
        int128 bExp;
        if (right) {
            aExp = p.aRightExp;
            bExp = p.bRightExp;
        } else {
            aExp = p.aLeftExp;
            bExp = p.bLeftExp;
        }

        int256 d0Signed = right ? int256(y0) : -int256(y0);
        int256 d1Signed = right ? int256(y1) : -int256(y1);

        int256 expArg0 = (int256(bExp) * d0Signed) / 1000;
        int256 expArg1 = (int256(bExp) * d1Signed) / 1000;

        int256 expVal0 = unwrap(E.pow(wrap(expArg0)));
        int256 expVal1 = unwrap(E.pow(wrap(expArg1)));

        int256 diff = expVal1 - expVal0;
        int256 area = (int256(aExp) * 1000 * diff) / (int256(bExp) * int256(1e18));

        return uint256(area >= 0 ? area : -area);
    }
}
