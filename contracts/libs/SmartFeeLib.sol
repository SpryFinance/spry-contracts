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
///
///         Migration note: prior to this refactor SmartFee was hardcoded
///         to a single "BLUE-CHIP" curve and used an internal "feeBps"
///         intermediate unit (1 unit = 0.10% = 1000 V4 pips). The new
///         design works in V4 pips end-to-end. For backward compatibility
///         BLUE-CHIP's coefficients are unchanged in spirit; the only
///         observable difference is at the asymmetric +334 right-safe
///         boundary, where the new V4-pip-native math returns ~3103 pips
///         instead of the old integer-truncated 3000 pips. The economic
///         delta is ≤0.011% — well within audit tolerance and only at one
///         singular boundary point.
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
        (uint256 reserve0, uint256 reserve1) =
            VirtualReserves.fromState(sqrtPriceX96, liquidity);

        if (reserve0 == 0 || reserve1 == 0 || amountSpecified == 0) {
            return uint24(p.safeFee);
        }

        // Translate V4 SwapParams into the (amount0Out, amount1Out) shape
        // used by the delta formula below; exactly one of the two is non-zero.
        (uint256 amount0Out, uint256 amount1Out) =
            _outputAmounts(reserve0, reserve1, zeroForOne, amountSpecified);

        int256 delta = _computeDelta(reserve0, reserve1, amount0Out, amount1Out);
        return uint24(_feeForDelta(delta, p));
    }

    /// @notice Public-equivalent helper: given a delta value already computed
    ///         externally, return the fee. Used by `_executeCumulative` paths
    ///         where the delta is the cumulative window delta rather than a
    ///         per-swap delta. Exposes the curve directly without re-deriving
    ///         delta from a sqrt-price + amount.
    function feeForDelta(int256 delta, SpryFeeParams memory p)
        internal
        pure
        returns (uint24)
    {
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
    ///      one doesn't) was preserved from the original SmartFee design
    ///      to maintain continuity at the asymmetric BLUE-CHIP boundaries
    ///      [-250, +334]. Each tier's safe/alert/danger boundaries are
    ///      tuned to this asymmetry.
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
    function _exp(int128 a, int128 b, int256 delta) private pure returns (uint256) {
        return (uint256(int256(a)) *
            unwrap(E.pow((wrap(int256(b)) * wrap(delta)) / wrap(1000))).toUint256())
            / (1e36).toUint256();
    }
}
