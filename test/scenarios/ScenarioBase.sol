// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LPHelper} from "../utils/LPHelper.sol";

/// @title ScenarioBase
/// @notice Shared fixture for the attack-scenario suite. Deploys a fresh
///         PoolManager, mines + deploys SpryHook, deploys SpryRouter,
///         creates a dynamic-fee pool initialized at 1:1 with seeded
///         full-range liquidity, and provisions three actors (alice,
///         bob, carol) with token + native-ETH balances and pre-approved
///         router allowances.
abstract contract ScenarioBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant SEED_LIQUIDITY = 1e22;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provision the three test actors with router (swap) and lp helper
        // (LP) approvals plus token + native-ETH balances.
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < actors.length; ++i) {
            deal(address(token0), actors[i], 1e30);
            deal(address(token1), actors[i], 1e30);
            deal(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            token0.approve(address(lp),     type(uint256).max);
            token1.approve(address(lp),     type(uint256).max);
            vm.stopPrank();
        }

        // Seed liquidity from the test contract so scenarios can swap immediately.
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        lp.addLiquidity(key, SEED_LIQUIDITY, SEED_LIQUIDITY, address(this));
    }

    // -----------------------------------------------------------------
    // LP helpers — wrap the LPHelper API so individual scenarios stay
    // terse. Each `owner` gets a unique V4 position (per-owner salt),
    // matching the canonical Uniswap PositionManager design.
    // -----------------------------------------------------------------
    function _addLiquidity(address actor, uint256 amount0Desired, uint256 amount1Desired)
        internal returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        vm.prank(actor);
        return lp.addLiquidity(key, amount0Desired, amount1Desired, actor);
    }

    function _removeLiquidity(address actor, uint128 liquidity)
        internal returns (uint256 amount0, uint256 amount1)
    {
        vm.prank(actor);
        return lp.removeLiquidity(key, liquidity, actor, actor);
    }

    function _positionLiquidity(address actor) internal view returns (uint128) {
        return lp.positionLiquidity(key, actor);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------
    function _pid() internal view returns (PoolId) {
        return key.toId();
    }

    function _pidUint() internal view returns (uint256) {
        return uint256(PoolId.unwrap(_pid()));
    }

    function _sqrtPriceX96() internal view returns (uint160 sp) {
        (sp, , , ) = manager.getSlot0(_pid());
    }

    function _poolLiquidity() internal view returns (uint128) {
        return manager.getLiquidity(_pid());
    }

    /// @notice Records (token0 balance, token1 balance, native ETH balance)
    ///         for an actor; useful for before/after comparisons.
    function _snapshot(address who)
        internal
        view
        returns (uint256 t0, uint256 t1, uint256 eth)
    {
        return (token0.balanceOf(who), token1.balanceOf(who), who.balance);
    }

    function _swapExactIn(address actor, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        vm.prank(actor);
        return router.swapExactInputSingle(
            key,
            zeroForOne,
            amountIn,
            1,
            actor,
            block.timestamp + 100
        ,
        "");
    }

    receive() external payable {}
}
