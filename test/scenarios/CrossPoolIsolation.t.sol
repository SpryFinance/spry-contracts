// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

/// @title CrossPoolIsolation
/// @notice Multi-pool adversarial scenarios.
///           1. The router's ERC6909-shaped ledger is keyed by PoolId.
///              Removing liquidity from pool B with shares minted on pool
///              A must fail because the holder has zero balance on B.
///           2. A swap on pool A/B must not change the reserves or LP shares
///              of pool A/C, even though they share currency A. PoolId
///              keying makes this trivial in principle; this asserts it
///              holds under stress.
///           3. Initializing the same PoolKey twice must revert.
contract CrossPoolIsolation is ScenarioBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ERC20Mock internal token2;
    PoolKey internal keyAC;

    function setUp() public override {
        super.setUp();
        token2 = new ERC20Mock();
        deal(address(token2), address(this), 1e30);
        deal(address(token2), alice, 1e30);
        deal(address(token2), bob, 1e30);
        deal(address(token2), carol, 1e30);
        token2.approve(address(router), type(uint256).max);
        token2.approve(address(lp),     type(uint256).max);
        vm.startPrank(alice);
        token2.approve(address(router), type(uint256).max);
        token2.approve(address(lp),     type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        token2.approve(address(router), type(uint256).max);
        token2.approve(address(lp),     type(uint256).max);
        vm.stopPrank();

        // Build pool A/C (where A is one of the existing tokens — pick token0).
        (Currency c0, Currency c1) = address(token0) < address(token2)
            ? (Currency.wrap(address(token0)), Currency.wrap(address(token2)))
            : (Currency.wrap(address(token2)), Currency.wrap(address(token0)));
        keyAC = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyAC, SQRT_PRICE_1_1);
        // Seed pool A/C — _addLiquidity helper only knows the base pool key,
        // so call lp directly for the second pool's seed.
        lp.addLiquidity(keyAC, SEED_LIQUIDITY, SEED_LIQUIDITY, address(this));
    }

    function testCannotRemoveOnPoolBUsingPoolAShares() public {
        // Alice deposits on pool A/B (the base pool).
        (uint128 aliceLiqAB, , ) = _addLiquidity(alice, 1e21, 1e21);
        assertGt(aliceLiqAB, 0);

        // Pool A/C ledger has zero liquidity for alice — per-pool isolation
        // by V4 position (owner, lower, upper, salt).
        assertEq(lp.positionLiquidity(keyAC, alice), 0, "alice has zero liquidity on pool A/C");

        // Trying to remove that amount on pool A/C must revert: V4 will
        // see the position has no liquidity and refuse the negative delta.
        vm.prank(alice);
        vm.expectRevert();
        lp.removeLiquidity(keyAC, aliceLiqAB, alice, alice);
    }

    function testSwapOnPoolABDoesNotAffectPoolAC() public {
        uint160 sqrtAB_pre = _sqrtPriceX96();
        (uint160 sqrtAC_pre, , , ) = manager.getSlot0(keyAC.toId());
        uint128 liqAC_pre = manager.getLiquidity(keyAC.toId());

        // Bob does a big swap on pool A/B.
        _swapExactIn(bob, true, 5e21);

        uint160 sqrtAB_post = _sqrtPriceX96();
        (uint160 sqrtAC_post, , , ) = manager.getSlot0(keyAC.toId());
        uint128 liqAC_post = manager.getLiquidity(keyAC.toId());

        assertTrue(sqrtAB_post != sqrtAB_pre, "pool A/B moved");
        assertEq(sqrtAC_post, sqrtAC_pre, "pool A/C price unchanged");
        assertEq(liqAC_post, liqAC_pre, "pool A/C liquidity unchanged");
    }

    function testCannotReInitializeSamePoolKey() public {
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}
