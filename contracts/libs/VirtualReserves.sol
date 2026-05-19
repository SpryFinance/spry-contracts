// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title VirtualReserves
/// @notice Converts a pool's current state (sqrtPriceX96 + in-range liquidity)
///         into the equivalent (reserve0, reserve1) pair that SmartFee's delta
///         formula operates on. Under the protocol's full-range-only
///         constraint, liquidity is uniform across the entire price range and
///         the swap math reduces to the constant-product x*y=k at the current
///         price.
/// @dev    For a pool with uniform full-range liquidity L at sqrtPrice = sqrt(P):
///           reserve0 = L / sqrt(P)  =  L * 2^96 / sqrtPriceX96
///           reserve1 = L * sqrt(P)  =  L * sqrtPriceX96 / 2^96
///         Both formulas use FullMath.mulDiv to handle the intermediate
///         256-bit overflow that occurs at extreme prices.
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
