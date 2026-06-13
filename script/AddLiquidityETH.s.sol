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

/// @title AddLiquidityETH
/// @notice Testnet helper. Creates (if needed) and seeds a full-range position
///         in an ETH/token Spry pool. Native ETH is currency0 (address 0); the
///         given token is currency1. Provide the amounts you want to deposit;
///         the actual amounts used are bounded by the computed liquidity, and
///         any excess ETH is refunded by the router.
///
/// @dev Reads from env:
///        PRIVATE_KEY                     LP owner key (also the salt source)
///        V4_POOL_MANAGER                 canonical PoolManager
///        SPRY_HOOK_ADDRESS              deployed SpryHook
///        V4_POOL_MODIFY_LIQUIDITY_TEST  canonical PoolModifyLiquidityTest
///        TOKEN                           the ERC20 to pair with ETH
///        ETH_AMOUNT                      native ETH to deposit (wei)
///        TOKEN_AMOUNT                    token to deposit (base units)
///      Optional:
///        TICK_SPACING   tier, one of 1/10/60/200/1000 (default 60)
///        SQRT_PRICE_X96 initial price for a NEW pool (default: derived from
///                       the amount ratio, else 1:1)
///
/// Example:
///   TOKEN=0x.. ETH_AMOUNT=100000000000000000 TOKEN_AMOUNT=1000000000000000000000 \
///     forge script script/AddLiquidityETH.s.sol:AddLiquidityETH --rpc-url unichain_sepolia --broadcast
contract AddLiquidityETH is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint256 ethAmount = vm.envUint("ETH_AMOUNT");
        uint256 tokenAmount = vm.envUint("TOKEN_AMOUNT");

        // ETH (address 0) is always currency0; the token is currency1.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(vm.envAddress("TOKEN")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(vm.envAddress("SPRY_HOOK_ADDRESS"))
        });

        IPoolManager manager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        address lp = vm.envAddress("V4_POOL_MODIFY_LIQUIDITY_TEST");

        vm.startBroadcast(pk);
        {
            uint160 sqrtP = _initIfNeeded(manager, key, ethAmount, tokenAmount);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
                TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
                ethAmount,
                tokenAmount
            );
            require(liq > 0, "AddLiquidityETH: zero liquidity (amounts too small)");

            // Token leg pulled via transferFrom; ETH leg sent as msg.value (router refunds excess).
            IERC20(Currency.unwrap(key.currency1)).approve(lp, tokenAmount);
            IModifyLiquidityRouter(lp).modifyLiquidity{value: ethAmount}(
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

        console.log("ETH/token pool seeded. token:", Currency.unwrap(key.currency1));
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
