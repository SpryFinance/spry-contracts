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

/// @dev Minimal handle to the canonical V4 PoolModifyLiquidityTest router.
interface IModifyLiquidityRouter {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta);
}

/// @title RemoveLiquidity
/// @notice Testnet helper. Removes liquidity from a Spry pool identified by its
///         two token addresses and tier, sending the unwound tokens back to the
///         caller. Set REMOVE_ALL=true to withdraw the full position balance.
///
/// @dev Reads from env:
///        PRIVATE_KEY                     LP owner key (the salt source)
///        V4_POOL_MANAGER                 canonical PoolManager
///        SPRY_HOOK_ADDRESS              deployed SpryHook
///        V4_POOL_MODIFY_LIQUIDITY_TEST  canonical PoolModifyLiquidityTest
///        TOKEN0, TOKEN1                  the pair (any order; sorted here)
///      Optional:
///        TICK_SPACING  tier, one of 1/10/60/200/1000 (default 60)
///        REMOVE_ALL    true to remove the full position balance (default false)
///        LIQUIDITY     amount of L to remove when REMOVE_ALL is false; capped
///                      at the current position balance
///
/// Example (remove everything):
///   TOKEN0=0x.. TOKEN1=0x.. REMOVE_ALL=true \
///     forge script script/RemoveLiquidity.s.sol:RemoveLiquidity \
///       --rpc-url base_sepolia --broadcast
contract RemoveLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Blocks keep the local-variable count low so the script compiles without
    // via_ir (the default profile keeps via_ir off for coverage accuracy).
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        address lp = vm.envAddress("V4_POOL_MODIFY_LIQUIDITY_TEST");

        PoolKey memory key;
        {
            address ta = vm.envAddress("TOKEN0");
            address tb = vm.envAddress("TOKEN1");
            (Currency c0, Currency c1) = ta < tb
                ? (Currency.wrap(ta), Currency.wrap(tb))
                : (Currency.wrap(tb), Currency.wrap(ta));
            key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing,
                hooks: IHooks(vm.envAddress("SPRY_HOOK_ADDRESS"))
            });
        }

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        bytes32 salt = bytes32(uint256(uint160(me)));

        // Position owner is the router; the per-owner salt isolates this LP.
        (uint128 current,,) =
            IPoolManager(vm.envAddress("V4_POOL_MANAGER")).getPositionInfo(key.toId(), lp, tickLower, tickUpper, salt);
        require(current > 0, "RemoveLiquidity: no position liquidity for this pair/tier/owner");

        uint128 toRemove;
        if (vm.envOr("REMOVE_ALL", false)) {
            toRemove = current; // up to the full LP balance
        } else {
            uint256 requested = vm.envUint("LIQUIDITY");
            toRemove = requested >= current ? current : uint128(requested); // cap at balance
        }
        require(toRemove > 0, "RemoveLiquidity: nothing to remove");

        vm.startBroadcast(pk);
        IModifyLiquidityRouter(lp).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(toRemove)),
                salt: salt
            }),
            ""
        );
        vm.stopBroadcast();

        console.log("removed liquidity: ", uint256(toRemove));
        console.log("remaining position:", uint256(current - toRemove));
        console.log("tokens sent to:    ", me);
    }
}
