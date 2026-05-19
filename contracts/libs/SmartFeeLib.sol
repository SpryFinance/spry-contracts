// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {E, wrap, unwrap} from "@prb/math/src/SD59x18.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {VirtualReserves} from "./VirtualReserves.sol";

/// @title SmartFeeLib
/// @notice Spry's dynamic fee curve. Given a pool's current state and a
///         pending swap, returns the LP fee to charge for that swap. The
///         curve has three zones — safe, alert, danger — keyed off a
///         price-shift parameter delta computed from the swap's amount and
///         the pool's virtual reserves:
///           safe   : delta in [-250,  334]            -> 3 bps
///           alert  : delta in [-500, -250) U (334, 1000] -> linear ramp to 20 bps
///           danger : delta in [-1000,-500) U (1000, 5000] -> exponential ramp to 50 bps
///           cap    : everything else                  -> 55 bps
///         All deltas are in thousandths (1000 = +100% price shift).
/// @dev    Returned fee is in V4 dynamic-fee pips (1_000_000 = 100%). Callers
///         passing the result back through V4's hook return channel must OR
///         in `LPFeeLibrary.OVERRIDE_FEE_FLAG (0x400000)` before returning.
library SmartFeeLib {
    using SafeCast for *;

    // Zone boundaries (delta is expressed in thousandths)
    int32 public constant LOWER_THRESHOLD_LIMIT = -250;
    int32 public constant UPPER_THRESHOLD_LIMIT = 334;
    int32 public constant LOWER_STOP_LIMIT = -500;
    int32 public constant UPPER_STOP_LIMIT = 1000;

    // Linear-zone regression coefficients
    int64 public constant LINEAR_REGRESSION_BASIS_POINT = 1_000_000;
    int64 public constant A_LEFT = -68_000;
    int64 public constant B_LEFT = -14_000;
    int64 public constant A_RIGHT = 25_370;
    int64 public constant B_RIGHT = -5_370;

    // Danger-zone exponential coefficients (PRB-Math SD59x18-scaled)
    int112 public constant A_LEFT_EXP = 8.0e18;
    int112 public constant B_LEFT_EXP = -1.8325814637483102e18;
    int112 public constant A_RIGHT_EXP = 15.905414575341013e18;
    int112 public constant B_RIGHT_EXP = 0.22907268296853878e18;

    /// @notice Scale factor from internal bps-of-1000 to V4 pips (1_000_000).
    ///         3 (= 0.3%) -> 3_000 pips; 55 (= 5.5%) -> 55_000 pips.
    uint24 internal constant BPS_TO_PIPS = 1000;

    /// @param sqrtPriceX96   pool's current price as Q64.96
    /// @param liquidity      pool's in-range liquidity (full-range == total)
    /// @param zeroForOne     true if swap is token0 -> token1
    /// @param amountSpecified V4 swap amountSpecified: negative = exactIn,
    ///                       positive = exactOut. Magnitude is the token
    ///                       amount.
    /// @return fee V4 dynamic fee in pips (0..1_000_000). Caller must OR in
    ///             OVERRIDE_FEE_FLAG when returning from beforeSwap.
    function getDynamicFee(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne,
        int256 amountSpecified
    ) internal pure returns (uint24 fee) {
        (uint256 reserve0, uint256 reserve1) =
            VirtualReserves.fromState(sqrtPriceX96, liquidity);

        if (reserve0 == 0 || reserve1 == 0 || amountSpecified == 0) {
            return 3 * BPS_TO_PIPS;
        }

        // Translate V4 SwapParams into the (amount0Out, amount1Out) shape
        // used by the delta formula below; exactly one of the two is non-zero.
        (uint256 amount0Out, uint256 amount1Out) =
            _outputAmounts(reserve0, reserve1, zeroForOne, amountSpecified);

        uint256 feeBps = _getCorrectedFee(reserve0, reserve1, amount0Out, amount1Out);
        return uint24(feeBps) * BPS_TO_PIPS;
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
            // token0 in, token1 out
            if (exactIn) {
                amount1Out = FullMath.mulDiv(mag, reserve1, reserve0 + mag);
            } else {
                amount1Out = mag;
            }
        } else {
            // token1 in, token0 out
            if (exactIn) {
                amount0Out = FullMath.mulDiv(mag, reserve0, reserve1 + mag);
            } else {
                amount0Out = mag;
            }
        }
    }

    /// @dev Three-zone fee dispatch. delta is computed directly from one
    ///      reserve and the swap amount (never dividing by the opposite
    ///      reserve), which is well-defined at every reserve ratio.
    ///      Returns the fee in bps of 1000 (0..55).
    function _getCorrectedFee(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amount0Out,
        uint256 amount1Out
    ) private pure returns (uint256) {
        int256 delta;
        if (amount0Out != 0) {
            delta = int256((1000 * amount0Out) / reserve0);
        } else if (amount1Out != 0) {
            delta = -int256((1000 * amount1Out) / (reserve1 + amount1Out));
        } else {
            return 3;
        }

        if (delta >= LOWER_THRESHOLD_LIMIT && delta <= UPPER_THRESHOLD_LIMIT) {
            return 3;
        } else if (delta >= LOWER_STOP_LIMIT && delta < LOWER_THRESHOLD_LIMIT) {
            return uint256(_linear(A_LEFT, B_LEFT, delta));
        } else if (delta > UPPER_THRESHOLD_LIMIT && delta <= UPPER_STOP_LIMIT) {
            return uint256(_linear(A_RIGHT, B_RIGHT, delta));
        } else if (delta < LOWER_STOP_LIMIT && delta >= -1000) {
            return _exp(A_LEFT_EXP, B_LEFT_EXP, delta);
        } else if (delta > UPPER_STOP_LIMIT && delta <= 5000) {
            return _exp(A_RIGHT_EXP, B_RIGHT_EXP, delta);
        } else {
            return 55;
        }
    }

    function _linear(int64 a, int64 b, int256 delta) private pure returns (int256) {
        return ((a * delta) + (1000 * b)) / LINEAR_REGRESSION_BASIS_POINT;
    }

    function _exp(int112 a, int112 b, int256 delta) private pure returns (uint256) {
        return (a.toUint256() *
            unwrap(E.pow((wrap(int256(b)) * wrap(delta)) / wrap(1000))).toUint256())
            / (1e36).toUint256();
    }
}
