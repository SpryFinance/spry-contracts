// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal handle to the canonical V4 PoolModifyLiquidityTest router.
interface IModifyLiquidityRouter {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta);
}

/// @title AddLiquidityTokens
/// @notice Testnet helper. Creates (if needed) and seeds a full-range position
///         in a token/token Spry pool. Provide the two token addresses and the
///         amounts you want to deposit; the actual amounts used are bounded by
///         the computed liquidity.
///
/// @dev Reads from env:
///        PRIVATE_KEY                     LP owner key (also the salt source)
///        V4_POOL_MANAGER                 canonical PoolManager
///        SPRY_HOOK_ADDRESS              deployed SpryHook
///        V4_POOL_MODIFY_LIQUIDITY_TEST  canonical PoolModifyLiquidityTest
///        TOKEN0, TOKEN1                  the pair (any order; sorted here)
///        AMOUNT0, AMOUNT1               amounts for TOKEN0/TOKEN1 respectively
///      Optional:
///        TICK_SPACING   tier, one of 1/10/60/200/1000 (default 60)
///        SQRT_PRICE_X96 initial price for a NEW pool (default: derived from
///                       the amount ratio, else 1:1)
///
/// Example:
///   TOKEN0=0x.. TOKEN1=0x.. AMOUNT0=1000000000000000000000 AMOUNT1=1000000000000000000000 \
///     forge script script/AddLiquidityTokens.s.sol:AddLiquidityTokens --rpc-url base_sepolia --broadcast
contract AddLiquidityTokens is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Sort the pair; carry each amount with its token through the sort.
        PoolKey memory key;
        uint256 amount0;
        uint256 amount1;
        {
            address tA = vm.envAddress("TOKEN0");
            address tB = vm.envAddress("TOKEN1");
            require(tA != tB, "AddLiquidityTokens: TOKEN0 == TOKEN1");
            uint256 amtA = vm.envUint("AMOUNT0");
            uint256 amtB = vm.envUint("AMOUNT1");
            (Currency c0, Currency c1) = tA < tB
                ? (Currency.wrap(tA), Currency.wrap(tB))
                : (Currency.wrap(tB), Currency.wrap(tA));
            (amount0, amount1) = tA < tB ? (amtA, amtB) : (amtB, amtA);
            key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing,
                hooks: IHooks(vm.envAddress("SPRY_HOOK_ADDRESS"))
            });
        }

        IPoolManager manager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        address lp = vm.envAddress("V4_POOL_MODIFY_LIQUIDITY_TEST");

        vm.startBroadcast(pk);
        {
            uint160 sqrtP = _initIfNeeded(manager, key, amount0, amount1);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
                TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
                amount0,
                amount1
            );
            require(liq > 0, "AddLiquidityTokens: zero liquidity (amounts too small)");

            // Both legs pulled via transferFrom, so approve the router for each.
            IERC20(Currency.unwrap(key.currency0)).approve(lp, amount0);
            IERC20(Currency.unwrap(key.currency1)).approve(lp, amount1);
            IModifyLiquidityRouter(lp).modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(tickSpacing),
                    tickUpper: TickMath.maxUsableTick(tickSpacing),
                    liquidityDelta: int256(uint256(liq)),
                    salt: bytes32(uint256(uint160(me)))
                }),
                ""
            );
            console.log("liquidity added:", uint256(liq));
        }
        vm.stopBroadcast();

        console.log("token0:         ", Currency.unwrap(key.currency0));
        console.log("token1:         ", Currency.unwrap(key.currency1));
        console.log("LP owner (salt):", me);
        console.log("poolId:");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    /// @dev Returns the pool's sqrtPrice, initializing the pool first if it
    ///      does not exist yet (price = SQRT_PRICE_X96, else derived from the
    ///      amount ratio, else 1:1).
    function _initIfNeeded(IPoolManager manager, PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        returns (uint160 sqrtP)
    {
        (sqrtP,,,) = manager.getSlot0(key.toId());
        if (sqrtP != 0) return sqrtP;
        uint256 forced = vm.envOr("SQRT_PRICE_X96", uint256(0));
        if (forced != 0) sqrtP = uint160(forced);
        else if (amount0 > 0 && amount1 > 0) sqrtP = _sqrtPriceX96(amount0, amount1);
        else sqrtP = uint160(1 << 96);
        manager.initialize(key, sqrtP);
    }

    /// @dev sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96, overflow-safe as
    ///      sqrt((amount1 << 96) / amount0) << 48, clamped to the tick range.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 v = Math.sqrt((amount1 << 96) / amount0) << 48;
        if (v < TickMath.MIN_SQRT_PRICE) v = TickMath.MIN_SQRT_PRICE;
        if (v > TickMath.MAX_SQRT_PRICE) v = TickMath.MAX_SQRT_PRICE;
        return uint160(v);
    }
}
