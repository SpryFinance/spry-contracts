// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {E, wrap, unwrap} from "@prb/math/src/SD59x18.sol";

struct ReserveInOut {
    uint256 reserve0;
    uint256 reserve1;
    uint256 amount0Out;
    uint256 amount1Out;
}

library SmartFeeLib {
    using SafeCast for *;

    // Delta Zone Detection Parameters
    int32 public constant LOWER_THRESHOLD_LIMIT = -250;
    int32 public constant UPPER_THRESHOLD_LIMIT = 334;
    int32 public constant LOWER_STOP_LIMIT = -500;
    int32 public constant UPPER_STOP_LIMIT = 1000;

    // Linear Regresion Parameters
    int64 public constant LINEAR_REGRESSION_BASIS_POINT = 1_000_000;
    int64 public constant A_LEFT = -68_000;
    int64 public constant B_LEFT = -14_000;
    int64 public constant A_RIGHT = 25_370;
    int64 public constant B_RIGHT = -5_370;

    // Exponential Regression Parameters
    int112 public constant A_LEFT_EXP = 8.0e18;
    int112 public constant B_LEFT_EXP = -1.8325814637483102e18;
    int112 public constant A_RIGHT_EXP = 15.905414575341013e18;
    int112 public constant B_RIGHT_EXP = 0.22907268296853878e18;

    function getCorrectedFee(ReserveInOut memory r)
        internal
        pure
        returns (uint256)
    {
        (uint256 reserve0, uint256 reserve1) = (r.reserve0, r.reserve1);

        // For the very first swap if the reserves are 0, then just return 0
        if (reserve0 == 0 || reserve1 == 0) return 0;

        uint256 price_init = (1000000 * reserve0) / reserve1;
        uint256 price_final = r.amount0Out != 0
            ? (1000000 * (r.amount0Out + reserve0)) / reserve1
            : (1000000 * reserve0) / (r.amount1Out + reserve1);

        int256 delta = int256((1000 * price_final) / price_init) - 1000;

        if (delta >= LOWER_THRESHOLD_LIMIT && delta <= UPPER_THRESHOLD_LIMIT)
            return 3;
        else if (delta >= LOWER_STOP_LIMIT && delta < LOWER_THRESHOLD_LIMIT)
            // a(delta) + b
            return uint256(_calculateModifiedFee(A_LEFT, B_LEFT, delta));
        else if (delta > UPPER_THRESHOLD_LIMIT && delta <= UPPER_STOP_LIMIT)
            // a(delta) + b
            return uint256(_calculateModifiedFee(A_RIGHT, B_RIGHT, delta));
        else if (delta < LOWER_STOP_LIMIT && delta >= -1000)
            // a.exp(b.delta)
            return _calculateStopCF(A_LEFT_EXP, B_LEFT_EXP, delta);
        else if (delta > UPPER_STOP_LIMIT && delta <= 5000)
            // a.exp(b.delta)
            return _calculateStopCF(A_RIGHT_EXP, B_RIGHT_EXP, delta);
        else return 55;
    }

    function _calculateModifiedFee(
        int64 a,
        int64 b,
        int256 delta
    ) private pure returns (int256) {
        return ((a * delta) + (1000 * b)) / LINEAR_REGRESSION_BASIS_POINT;
    }

    function _calculateStopCF(
        int112 a,
        int112 b,
        int256 delta
    ) private pure returns (uint256) {
        return
            (a.toUint256() *
                unwrap(E.pow((wrap(int256(b)) * wrap(delta)) / wrap(1000)))
                    .toUint256()) / (1e36).toUint256();
    }
}
