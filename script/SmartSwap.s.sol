// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal handle to the deployed SpryRouter swap entry point.
interface ISpryRouter {
    function swapExactInputSingle(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        bytes calldata hookData
    ) external payable returns (uint256 amountOut);
}

/// @title SmartSwap
/// @notice Testnet helper. Swaps using only the two token addresses: it finds
///         the initialized Spry pool for the pair (auto-detecting the tier),
///         defaults the input amount to the caller's full balance, and routes
///         through the deployed SpryRouter. amountOutMin is 0, so this is
///         testnet-only convenience, not production slippage protection.
///
/// @dev Reads from env:
///        PRIVATE_KEY          caller key
///        V4_POOL_MANAGER      canonical PoolManager (for pool detection)
///        SPRY_HOOK_ADDRESS   deployed SpryHook
///        SPRY_ROUTER_ADDRESS deployed SpryRouter
///        TOKEN_IN, TOKEN_OUT  the swap direction
///      Optional:
///        AMOUNT_IN     exact input amount (default: caller's full TOKEN_IN balance)
///        TICK_SPACING  force a tier instead of auto-detecting (1/10/60/200/1000)
///
/// Example:
///   TOKEN_IN=0x.. TOKEN_OUT=0x.. \
///     forge script script/SmartSwap.s.sol:SmartSwap --rpc-url unichain_sepolia --broadcast
contract SmartSwap is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Blocks keep the local-variable count low so the script compiles without
    // via_ir (the default profile keeps via_ir off for coverage accuracy).
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        require(tokenIn != tokenOut, "SmartSwap: TOKEN_IN == TOKEN_OUT");
        bool zeroForOne = tokenIn < tokenOut;

        // Resolve the tier (explicit or auto-detected) and build the key.
        PoolKey memory key;
        {
            IPoolManager manager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
            IHooks hook = IHooks(vm.envAddress("SPRY_HOOK_ADDRESS"));
            (Currency c0, Currency c1) = zeroForOne
                ? (Currency.wrap(tokenIn), Currency.wrap(tokenOut))
                : (Currency.wrap(tokenOut), Currency.wrap(tokenIn));

            int24 tickSpacing;
            uint256 forced = vm.envOr("TICK_SPACING", uint256(0));
            if (forced != 0) {
                tickSpacing = int24(int256(forced));
                require(
                    _initialized(manager, c0, c1, hook, tickSpacing),
                    "SmartSwap: pool not initialized for TICK_SPACING"
                );
            } else {
                tickSpacing = _detectTier(manager, c0, c1, hook);
                require(tickSpacing != 0, "SmartSwap: no initialized Spry pool for this pair");
            }
            key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: tickSpacing,
                hooks: hook
            });
        }

        uint256 amountIn = vm.envOr("AMOUNT_IN", uint256(0));
        if (amountIn == 0) amountIn = IERC20(tokenIn).balanceOf(me);
        require(amountIn > 0, "SmartSwap: zero input (no balance and no AMOUNT_IN)");

        uint256 amountOut;
        {
            address router = vm.envAddress("SPRY_ROUTER_ADDRESS");
            vm.startBroadcast(pk);
            // SpryRouter pulls the input via transferFrom(payer = caller), so approve it.
            IERC20(tokenIn).approve(router, amountIn);
            amountOut = ISpryRouter(router).swapExactInputSingle(
                key, zeroForOne, amountIn, 0, me, block.timestamp + 3600, ""
            );
            vm.stopBroadcast();
        }

        console.log("tier tickSpacing:", uint256(int256(key.tickSpacing)));
        console.log("tokenIn:         ", tokenIn);
        console.log("tokenOut:        ", tokenOut);
        console.log("amountIn:        ", amountIn);
        console.log("amountOut:       ", amountOut);
    }

    function _initialized(IPoolManager manager, Currency c0, Currency c1, IHooks hook, int24 tickSpacing)
        internal
        view
        returns (bool)
    {
        PoolKey memory k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: hook
        });
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        return sqrtPriceX96 != 0;
    }

    function _detectTier(IPoolManager manager, Currency c0, Currency c1, IHooks hook)
        internal
        view
        returns (int24)
    {
        int24[5] memory tiers = [int24(1), int24(10), int24(60), int24(200), int24(1000)];
        for (uint256 i = 0; i < tiers.length; i++) {
            if (_initialized(manager, c0, c1, hook, tiers[i])) return tiers[i];
        }
        return 0;
    }
}
