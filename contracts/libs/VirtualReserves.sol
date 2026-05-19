// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title VirtualReserves
/// @notice Converts V4 pool state (sqrtPriceX96 + liquidity) into V2-style
///         virtual reserves under the assumption that ALL liquidity lives in
///         a single full-range position [MIN_TICK, MAX_TICK]. Under that
///         assumption a V4 pool is mathematically a V2 pool, and SmartFee's
///         delta math (which is defined on V2 reserves) applies directly.
/// @dev For a pool with uniform full-range liquidity L at sqrtPrice = √P:
///         reserve0 = L / √P  =  L * 2^96 / sqrtPriceX96
///         reserve1 = L * √P  =  L * sqrtPriceX96 / 2^96
///      Both formulas use FullMath.mulDiv to handle the intermediate
///      256-bit overflow that occurs at extreme prices.
library VirtualReserves {
    uint256 internal constant Q96 = 1 << 96;

    function fromState(uint160 sqrtPriceX96, uint128 liquidity)
        internal
        pure
        returns (uint256 reserve0, uint256 reserve1)
    {
        if (liquidity == 0 || sqrtPriceX96 == 0) {
            return (0, 0);
        }
        reserve0 = FullMath.mulDiv(uint256(liquidity), Q96, uint256(sqrtPriceX96));
        reserve1 = FullMath.mulDiv(uint256(liquidity), uint256(sqrtPriceX96), Q96);
    }
}
