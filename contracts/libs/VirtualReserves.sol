// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title VirtualReserves
/// @notice Converts a pool's current state (sqrtPriceX96 + in-range liquidity)
///         into the equivalent (reserve0, reserve1) pair that SmartFee's delta
///         formula operates on. The pair describes the local constant-product
///         x*y=k behaviour at the current price: a marginal swap against the
///         in-range liquidity L moves price exactly as it would against a V2
///         pool holding these virtual reserves.
/// @dev    For in-range liquidity L at sqrtPrice = sqrt(P):
///           reserve0 = L / sqrt(P)  =  L * 2^96 / sqrtPriceX96
///           reserve1 = L * sqrt(P)  =  L * sqrtPriceX96 / 2^96
///         Both formulas use FullMath.mulDiv to handle the intermediate
///         256-bit overflow that occurs at extreme prices.
///
///         `L` is whatever the manager reports as in-range liquidity — equal
///         to total liquidity for full-range pools (Spry's recommended
///         configuration, on which the IL economics are derived), less for
///         concentrated configurations. The formula is exact either way for
///         the marginal swap behaviour at the current tick.
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
