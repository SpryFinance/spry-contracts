// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";

/// @title FeeAccrualBenefit
/// @notice Pins two complementary properties in one suite:
///           1. An honest LP earns fees on their own position when swaps
///              happen against the pool's liquidity.
///           2. A drive-by attacker who add+remove cycles around a fee
///              window CANNOT drain fees that accrued on someone else's
///              position. The per-owner-salt design (V4 canonical
///              PositionManager pattern, mirrored here by LPHelper) keys
///              every position by `salt = bytes32(uint256(uint160(owner)))`
///              so each LP's fee accumulator is strictly their own.
contract FeeAccrualBenefit is ScenarioBase {
    /// @dev Alice provides liquidity; the trader runs balanced two-way
    ///      swaps so impermanent loss is minimal. Alice withdraws and
    ///      ends up strictly richer than she started — her own position
    ///      accrued fees in proportion to its share of pool depth.
    function testLPAccruesFeesOnOwnPosition() public {
        uint256 aliceIn0 = 5e20;
        uint256 aliceIn1 = 5e20;

        (uint128 aliceLiq, , ) = _addLiquidity(alice, aliceIn0, aliceIn1);
        assertGt(aliceLiq, 0, "alice received shares");

        uint256 leg = 3e20;
        for (uint256 i = 0; i < 25; ++i) {
            _swapExactIn(bob, true, leg);
            _swapExactIn(bob, false, leg);
        }

        (uint256 t0Before, uint256 t1Before, ) = _snapshot(alice);
        _removeLiquidity(alice, aliceLiq);
        (uint256 t0After, uint256 t1After, ) = _snapshot(alice);

        uint256 out0 = t0After - t0Before;
        uint256 out1 = t1After - t1Before;
        assertGe(out0 + out1, aliceIn0 + aliceIn1, "alice's total never decreases");
        assertGt(out0 + out1, aliceIn0 + aliceIn1, "fees accrued to her position");
    }

    /// @dev Pre-Commit-1, Bob could siphon fees that accrued on Alice's
    ///      (and the seed's) position by sandwiching a fee-generating
    ///      swap window with `add+remove` on the shared position. Under
    ///      the V4-native per-owner-position model, Bob's add creates a
    ///      *new* V4 position keyed by his own salt and fees accrue
    ///      pro-rata to whichever position's liquidity was in range. If
    ///      Bob holds for zero swap volume, his position earns zero
    ///      fees. We assert his round-trip leaves him at most break-
    ///      even (accounting for tiny rounding).
    function testDriveByLPGetsNoFeesFromAlicesPosition() public {
        // 1. Alice provides bulk liquidity.
        (uint128 aliceLiq, , ) = _addLiquidity(alice, 5e20, 5e20);
        assertGt(aliceLiq, 0);

        // 2. Trader runs the fee-generating swap window — BEFORE Bob enters.
        for (uint256 i = 0; i < 25; ++i) {
            _swapExactIn(carol, true,  3e20);
            _swapExactIn(carol, false, 3e20);
        }

        // 3. Bob walks up after the fees have accrued, adds a small
        //    position, and immediately removes it. Under the broken
        //    shared-position model he'd siphon ~all accumulated fees;
        //    under the per-owner-position model he gets ~zero.
        _driveByLP(bob);

        // 4. Sanity: Alice can still claim her fee share — the drive-by
        //    didn't erase it.
        _assertAliceStillEarnedFees(aliceLiq);
    }

    /// @dev Helper: Bob does add+remove with a 1e20 position. Asserts the
    ///      delta on each token is below a rounding threshold (1e10 wei).
    function _driveByLP(address bobAddr) internal {
        (uint256 before0, uint256 before1, ) = _snapshot(bobAddr);
        (uint128 bobLiq, , ) = _addLiquidity(bobAddr, 1e20, 1e20);
        _removeLiquidity(bobAddr, bobLiq);
        (uint256 after0, uint256 after1, ) = _snapshot(bobAddr);

        uint256 net0 = after0 > before0 ? after0 - before0 : 0;
        uint256 net1 = after1 > before1 ? after1 - before1 : 0;
        assertLe(net0, 1e10, "drive-by LP siphoned token0 fees");
        assertLe(net1, 1e10, "drive-by LP siphoned token1 fees");
    }

    /// @dev Helper: confirm Alice's position still pays fees after a
    ///      drive-by. We compare her output sum to her input sum
    ///      (5e20 + 5e20 = 1e21).
    function _assertAliceStillEarnedFees(uint128 aliceLiq) internal {
        (uint256 before0, uint256 before1, ) = _snapshot(alice);
        _removeLiquidity(alice, aliceLiq);
        (uint256 after0, uint256 after1, ) = _snapshot(alice);
        assertGt(
            (after0 - before0) + (after1 - before1),
            1e21,
            "alice still earned fees on her position despite drive-by"
        );
    }
}
