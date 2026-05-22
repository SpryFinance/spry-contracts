// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ScenarioBase} from "./ScenarioBase.sol";

/// @title IntegralPathIndependence
/// @notice End-to-end V4 scenario proving the splitting-attack-resistance
///         that integral mode is designed to give. Each test forks an A/B
///         comparison from an identical post-setUp pool state via
///         `vm.snapshot` + `vm.revertTo`, then checks the actual
///         swapper's output against the same total input split two ways.
///
///         The headline property: under integral mode, a user who splits
///         a same-direction swap into N pieces within one block ALWAYS
///         pays at least as much total fee as one big swap of the same
///         total amount. Once the trajectory reaches the alert zone the
///         inequality is strict — splitting is actively costly. The
///         mechanism is geometric: each smaller piece's signed delta is
///         computed against post-previous-swap reserves which are more
///         imbalanced, so the cumulative the curve is integrated over
///         travels DEEPER per unit of token swapped, lifting the average
///         per-piece fee rate above the big-swap rate.
contract IntegralPathIndependence is ScenarioBase {
    // ------------------------------------------------------------------
    // Headline test — splitter cannot beat a big swap once the trajectory
    // crosses into the alert zone.
    // ------------------------------------------------------------------

    function testAlertCrossingSplitterPaysStrictlyMore() public {
        uint256 swapTotal = 5e21; // sized to push cum well into right alert
        uint256 nSplits = 5;

        uint256 snap = vm.snapshot();

        // --- A) One big swap ---
        uint256 t1Before_big = token1.balanceOf(address(this));
        router.swapExactInputSingle(key, true, swapTotal, 1, address(this), block.timestamp + 100, "");
        uint256 outputBig = token1.balanceOf(address(this)) - t1Before_big;

        // --- B) Revert + N small same-direction swaps ---
        vm.revertTo(snap);

        uint256 t1Before_split = token1.balanceOf(address(this));
        uint256 perSwap = swapTotal / nSplits;
        for (uint256 i = 0; i < nSplits; ++i) {
            router.swapExactInputSingle(key, true, perSwap, 1, address(this), block.timestamp + 100, "");
        }
        uint256 outputSplit = token1.balanceOf(address(this)) - t1Before_split;

        // Constant-product slippage is path-independent on zero-fee output, so
        // the entire output gap is fee-attributable. Splitter pays strictly
        // more once any piece's cum is past safeHigh.
        assertLt(outputSplit, outputBig, "alert-crossing splitter must pay strictly more fee");
    }

    // ------------------------------------------------------------------
    // Symmetric test — same property on the OTHER direction.
    // ------------------------------------------------------------------

    function testAlertCrossingSplitterPaysStrictlyMoreOneForZero() public {
        uint256 swapTotal = 5e21;
        uint256 nSplits = 5;

        uint256 snap = vm.snapshot();

        // A) one big one-for-zero swap
        uint256 t0Before_big = token0.balanceOf(address(this));
        router.swapExactInputSingle(key, false, swapTotal, 1, address(this), block.timestamp + 100, "");
        uint256 outputBig = token0.balanceOf(address(this)) - t0Before_big;

        // B) split
        vm.revertTo(snap);
        uint256 t0Before_split = token0.balanceOf(address(this));
        uint256 perSwap = swapTotal / nSplits;
        for (uint256 i = 0; i < nSplits; ++i) {
            router.swapExactInputSingle(key, false, perSwap, 1, address(this), block.timestamp + 100, "");
        }
        uint256 outputSplit = token0.balanceOf(address(this)) - t0Before_split;

        assertLt(outputSplit, outputBig, "left-side splitter must pay strictly more");
    }

    // ------------------------------------------------------------------
    // Safe-zone trajectories — both whole and split pay flat safeFee, so
    // the outputs differ only by sub-pip rounding inside V4's fee
    // application. We assert near-equality, NOT strict-less.
    // ------------------------------------------------------------------

    function testSafeZoneSplitterAndBigSwapEssentiallyEqual() public {
        // A 1e18 input vs 1e22 reserves moves cum by < 100 (well under
        // safeHigh=334) — entire trajectory stays in safe zone for either
        // path. Both pay safeFee = 3000 pips throughout.
        uint256 swapTotal = 1e18;
        uint256 nSplits = 4;

        uint256 snap = vm.snapshot();

        uint256 t1Before_big = token1.balanceOf(address(this));
        router.swapExactInputSingle(key, true, swapTotal, 1, address(this), block.timestamp + 100, "");
        uint256 outputBig = token1.balanceOf(address(this)) - t1Before_big;

        vm.revertTo(snap);
        uint256 t1Before_split = token1.balanceOf(address(this));
        uint256 perSwap = swapTotal / nSplits;
        for (uint256 i = 0; i < nSplits; ++i) {
            router.swapExactInputSingle(key, true, perSwap, 1, address(this), block.timestamp + 100, "");
        }
        uint256 outputSplit = token1.balanceOf(address(this)) - t1Before_split;

        // Identical-fee scenario: outputs should match within 0.01% relative
        // tolerance (sub-pip rounding inside the per-swap fee application).
        assertApproxEqRel(outputBig, outputSplit, 1e14, "safe-zone outputs should be near-identical");
    }

    // ------------------------------------------------------------------
    // Cross-block test — splitting across a block boundary RESTORES the
    // splitter's ability to pay less, because the cumulative tracker
    // resets at the start of each new block window. This is the
    // intended behavior: a multi-block patient attacker pays normal
    // fees, only the same-block (atomic, MEV-bot-style) attack is
    // penalized.
    // ------------------------------------------------------------------

    function testSplitterAcrossBlocksDoesNotPayExtra() public {
        uint256 swapTotal = 5e21;
        uint256 nSplits = 5;

        uint256 snap = vm.snapshot();

        uint256 t1Before_big = token1.balanceOf(address(this));
        router.swapExactInputSingle(key, true, swapTotal, 1, address(this), block.timestamp + 100, "");
        uint256 outputBig = token1.balanceOf(address(this)) - t1Before_big;

        vm.revertTo(snap);
        uint256 t1Before_split = token1.balanceOf(address(this));
        uint256 perSwap = swapTotal / nSplits;
        for (uint256 i = 0; i < nSplits; ++i) {
            router.swapExactInputSingle(key, true, perSwap, 1, address(this), block.timestamp + 100, "");
            vm.roll(block.number + 1); // each swap in its own block window
        }
        uint256 outputSplit = token1.balanceOf(address(this)) - t1Before_split;

        // Each split starts in a FRESH window (cumBefore = 0) so each piece
        // pays only its own per-swap rate. The cumulative reset removes the
        // per-block "splitter penalty" the in-block test demonstrated —
        // outputs match the big swap within rounding noise (sub-wei per
        // 3e21 tokens). The point: the protection is SCOPED to the block
        // window; a patient multi-block attacker doesn't get punished.
        // Same-block splitting penalty in `testAlertCrossingSplitterPays...`
        // is the order of 1e15 wei; here the gap is < 100 wei. Three orders
        // of magnitude tighter is the meaningful regression target.
        uint256 diff = outputBig > outputSplit ? outputBig - outputSplit : outputSplit - outputBig;
        assertLt(diff, 1_000, "multi-block splitting incurs no meaningful penalty");
    }

    // ------------------------------------------------------------------
    // Compound-pieces sanity: a finer split should be EVEN MORE penalized
    // than a coarse split (same swapTotal, more pieces → deeper cum per
    // token → higher avg fee).
    // ------------------------------------------------------------------

    function testFinerSplitPaysMoreThanCoarserSplit() public {
        uint256 swapTotal = 5e21;
        uint256 snap = vm.snapshot();

        // A) 2 pieces
        uint256 t1A = token1.balanceOf(address(this));
        uint256 perA = swapTotal / 2;
        for (uint256 i = 0; i < 2; ++i) {
            router.swapExactInputSingle(key, true, perA, 1, address(this), block.timestamp + 100, "");
        }
        uint256 outputCoarse = token1.balanceOf(address(this)) - t1A;

        // B) 10 pieces (5x finer)
        vm.revertTo(snap);
        uint256 t1B = token1.balanceOf(address(this));
        uint256 perB = swapTotal / 10;
        for (uint256 i = 0; i < 10; ++i) {
            router.swapExactInputSingle(key, true, perB, 1, address(this), block.timestamp + 100, "");
        }
        uint256 outputFine = token1.balanceOf(address(this)) - t1B;

        // Finer split → deeper cum trajectory → higher fee total → less output.
        assertLt(outputFine, outputCoarse, "finer same-block split pays more fee");
    }
}
