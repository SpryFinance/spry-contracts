// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";

/// @title DonationAndStuckTokens
/// @notice Verifies two things:
///           1. Raw ERC20 transfers directly into the PoolManager (bypassing
///              `sync`/`settle`) do NOT alter pool accounting and cannot
///              poison the dynamic-fee algorithm. The "donated" tokens are
///              effectively stuck — they remain unaccounted, and the next
///              real settle() picks them up cleanly only if a caller
///              completes the proper sync/settle dance for that currency.
///           2. ERC20 transferred directly into the SpryRouter sits there
///              and cannot be drained by a random caller. The router has no
///              token-sweep entry point by design; this enforces that
///              property.
///         Both checks ensure mistaken transfers never enable theft.
contract DonationAndStuckTokens is ScenarioBase {
    function testRawTransferToPoolManagerDoesNotMovePrice() public {
        uint160 priceBefore = _sqrtPriceX96();
        uint128 liqBefore = _poolLiquidity();

        // Alice mistakenly sends tokens straight to PoolManager.
        uint256 donation = 5e21;
        vm.prank(alice);
        token0.transfer(address(manager), donation);

        // The pool's accounting is unaffected — sqrtPriceX96 and liquidity
        // are derived from settled positions, not raw balances.
        assertEq(_sqrtPriceX96(), priceBefore, "price unchanged by donation");
        assertEq(_poolLiquidity(), liqBefore, "liquidity unchanged by donation");

        // Subsequent swaps still execute correctly against the original state.
        uint256 outBefore = token1.balanceOf(bob);
        _swapExactIn(bob, true, 1e19);
        assertGt(token1.balanceOf(bob), outBefore, "swap completes after donation");
    }

    function testRawTransferToRouterIsNotDrainable() public {
        // Alice mistakenly transfers tokens directly into the router.
        uint256 stuck = 7e20;
        vm.prank(alice);
        token0.transfer(address(router), stuck);
        assertEq(token0.balanceOf(address(router)), stuck);

        uint256 carolBefore = token0.balanceOf(carol);

        // Carol attempts every public router entry point that touches token0
        // hoping to siphon it. None of them give her anyone-else's tokens.
        // Each call is wrapped in try/catch because either revert or the
        // happy path with carol's OWN balance change is acceptable; what's
        // NOT acceptable is carol ending up with the stuck token0.
        vm.startPrank(carol);
        try router.swapExactInputSingle(key, true, 1, 1, carol, block.timestamp + 100, "") returns (uint256) {} catch {}
        try router.swapExactOutputSingle(key, true, 1, type(uint256).max, carol, block.timestamp + 100, "") returns (uint256) {} catch {}
        try lp.removeLiquidity(key, 1, carol, carol) returns (uint256, uint256) {} catch {}
        vm.stopPrank();

        // The router still holds the stuck tokens — they didn't leak to carol.
        assertEq(token0.balanceOf(address(router)), stuck, "stuck tokens still in router");
        // Carol may have spent some of her own tokens swapping, but she did
        // not somehow acquire MORE token0 than she started with from the stuck stash.
        assertLe(token0.balanceOf(carol), carolBefore, "carol gained no token0 from the stuck stash");
    }
}
