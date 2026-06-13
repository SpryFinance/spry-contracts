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

import {MintableERC20} from "./mocks/MintableERC20.sol";

/// @dev Minimal handle to the canonical V4 PoolModifyLiquidityTest router.
interface IModifyLiquidityRouter {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta);
}

/// @title SeedPool
/// @notice Testnet helper. Deploys and mints two mock ERC20s, creates a Spry
///         pool against the deployed SpryHook, and seeds a full-range position
///         through the canonical V4 PoolModifyLiquidityTest router.
///
/// @dev Reads from env:
///        PRIVATE_KEY                     deployer key (also the LP owner/salt)
///        V4_POOL_MANAGER                 canonical PoolManager
///        SPRY_HOOK_ADDRESS              deployed SpryHook
///        V4_POOL_MODIFY_LIQUIDITY_TEST  canonical PoolModifyLiquidityTest
///      Optional:
///        TICK_SPACING   tier, one of 1/10/60/200/1000 (default 60, BLUE-CHIP)
///        TOKEN_DECIMALS decimals for the mock tokens (default 18)
///        MINT_AMOUNT    minted to the deployer per token (default 1e24)
///        LIQUIDITY      full-range liquidity L to add (default 1e21)
///        SQRT_PRICE_X96 initial price (default 1<<96, i.e. 1:1)
///
/// Example:
///   forge script script/SeedPool.s.sol:SeedPool \
///     --rpc-url unichain_sepolia --broadcast
contract SeedPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Blocks keep the local-variable count low so the script compiles without
    // via_ir (the default profile keeps via_ir off for coverage accuracy).
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(1e21));

        vm.startBroadcast(pk);

        // Deploy + mint, scoped so the token/decimals/amount locals are freed.
        Currency c0;
        Currency c1;
        {
            uint8 dec = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));
            uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000 ether));
            MintableERC20 ta = new MintableERC20("Spry Test Token A", "sptA", dec);
            MintableERC20 tb = new MintableERC20("Spry Test Token B", "sptB", dec);
            ta.mint(me, mintAmount);
            tb.mint(me, mintAmount);
            (c0, c1) = address(ta) < address(tb)
                ? (Currency.wrap(address(ta)), Currency.wrap(address(tb)))
                : (Currency.wrap(address(tb)), Currency.wrap(address(ta)));
        }

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(vm.envAddress("SPRY_HOOK_ADDRESS"))
        });

        IPoolManager(vm.envAddress("V4_POOL_MANAGER")).initialize(
            key, uint160(vm.envOr("SQRT_PRICE_X96", uint256(1 << 96)))
        );

        // The PoolModifyLiquidityTest router pulls tokens from msg.sender via
        // transferFrom, so the deployer approves it for both currencies.
        {
            address lp = vm.envAddress("V4_POOL_MODIFY_LIQUIDITY_TEST");
            MintableERC20(Currency.unwrap(c0)).approve(lp, type(uint256).max);
            MintableERC20(Currency.unwrap(c1)).approve(lp, type(uint256).max);
            IModifyLiquidityRouter(lp).modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(tickSpacing),
                    tickUpper: TickMath.maxUsableTick(tickSpacing),
                    liquidityDelta: int256(liquidity),
                    salt: bytes32(uint256(uint160(me))) // per-owner salt (LPHelper / PositionManager model)
                }),
                ""
            );
        }

        vm.stopBroadcast();

        console.log("token0:         ", Currency.unwrap(c0));
        console.log("token1:         ", Currency.unwrap(c1));
        console.log("tickSpacing:    ", uint256(int256(tickSpacing)));
        console.log("liquidity added:", liquidity);
        console.log("LP owner (salt):", me);
        console.log("poolId:");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }
}
