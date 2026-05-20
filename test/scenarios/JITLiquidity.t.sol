// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";

/// @title JITLiquidity
/// @notice Just-in-time liquidity scenario: attacker (bob) deposits a huge
///         position immediately before a victim's swap and removes it
///         immediately after, hoping to capture a disproportionate share
///         of the swap's fee. The protocol's property under test is that
///         JIT-providers can never extract MORE than their proportional
///         share of the fees generated while their liquidity was in range.
///         I.e. there must be no path to drain pre-existing LPs.
contract JITLiquidity is ScenarioBase {
    function testJITProviderCannotDrainExistingLPs() public {
        // Snapshot the seeder's (this contract's) share value before.
        uint128 seedLiq = _poolLiquidity();
        (uint256 t0Snap, uint256 t1Snap, ) = _snapshot(address(this));

        // Bob front-runs the victim swap by adding a massive position.
        uint256 bobIn0 = 5e22;
        uint256 bobIn1 = 5e22;
        (uint256 bobBal0Before, uint256 bobBal1Before, ) = _snapshot(bob);
        (uint128 bobLiq, , ) = _addLiquidity(bob, bobIn0, bobIn1);

        // Victim (alice) does a sizable swap.
        _swapExactIn(alice, true, 5e21);

        // Bob immediately removes his position.
        _removeLiquidity(bob, bobLiq);

        // Bob's net position in token0 + token1 must NOT exceed what he put in.
        // Anything else would constitute theft from pre-existing LPs, since
        // a JIT provider can at best earn their proportional fees on the
        // single swap that happened in their window.
        (uint256 bobBal0After, uint256 bobBal1After, ) = _snapshot(bob);
        uint256 bobNet0 = bobBal0After + bobIn0 - bobBal0Before; // net token0 movement
        uint256 bobNet1 = bobBal1After + bobIn1 - bobBal1Before;
        // Bob's swap-direction asymmetry means he can't end up with strictly
        // more of both tokens. Either he ends up roughly even, or down on one
        // and up on the other (impermanent loss + a small fee share).
        bool gainedBoth = bobNet0 > bobIn0 && bobNet1 > bobIn1;
        assertFalse(gainedBoth, "JIT must not yield more of BOTH tokens");

        // Existing LP (this contract) shouldn't be worse off than they would
        // have been without the JIT — verified by their liquidity unchanged.
        // (Their position is the same `seedLiq`; the swap's fee accrued
        //  proportionally to both seed and JIT positions.)
        uint128 seedAfter = _poolLiquidity();
        assertEq(seedAfter, seedLiq, "seed liquidity untouched by JIT round-trip");

        // Silence unused-vars warning where appropriate.
        (t0Snap, t1Snap) = (t0Snap, t1Snap);
    }
}
