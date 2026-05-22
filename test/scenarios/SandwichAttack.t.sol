// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";

/// @title SandwichAttack
/// @notice Models the classic sandwich attack:
///           1. attacker (bob) sees alice's pending swap in the mempool
///           2. bob front-runs with a swap in the same direction
///           3. alice's swap executes at the now-worse price
///           4. bob back-runs in the opposite direction to realize his profit
///         A static-fee AMM lets the attacker pocket the price impact alice
///         paid for. Spry's dynamic fee should make the back-run leg pay a
///         strictly higher fee than the front-run leg — that asymmetry is
///         the whole point of the SmartFee curve.
contract SandwichAttack is ScenarioBase {
    function testSandwichBackrunPaysStrictlyHigherFee() public {
        // Sizes chosen so the front-run alone pushes us out of the safe zone,
        // and the post-victim state pushes the back-run further into alert.
        uint256 frontRunAmt = 7e21;  // 70% of seed reserve in
        uint256 victimAmt   = 2e21;
        uint256 backRunAmt  = 7e21;

        // --- Phase 1: front-run (bob sells token0 for token1) -----------
        // zeroForOne=true means token0 in, token1 out. Adding token0 to the
        // pool lowers the price (token1/token0), so sqrtPriceX96 decreases.
        uint256 priceBeforeFront = _sqrtPriceX96();
        uint24 frontFeePips = _peekFee(true, frontRunAmt);
        _swapExactIn(bob, true, frontRunAmt);
        uint256 priceAfterFront = _sqrtPriceX96();
        assertLt(priceAfterFront, priceBeforeFront, "front-run pushed price down");

        // --- Phase 2: victim swap (alice swaps in the same direction) ---
        _swapExactIn(alice, true, victimAmt);

        // --- Phase 3: back-run (bob swaps token1 back for token0) -------
        uint24 backFeePips = _peekFee(false, backRunAmt);
        _swapExactIn(bob, false, backRunAmt);

        // The whole point of SmartFee: the back-run, which is the leg that
        // captures the sandwich's profit, must pay a strictly higher fee
        // than the entry leg. Without this asymmetry the curve would be
        // marketing, not protection.
        assertGt(backFeePips, frontFeePips, "back-run must pay more than front-run");
    }

    /// @notice Bob attempts the sandwich but alice's swap is too small to
    ///         matter. The fee curve still penalizes the back-run because
    ///         Bob's own front-run already skewed the pool.
    function testSandwichSelfPenalizesEvenWithSmallVictim() public {
        uint256 frontRun = 7e21;
        uint256 victim   = 1e16; // tiny — alice's swap barely registers
        uint256 backRun  = 7e21;

        uint24 frontFee = _peekFee(true, frontRun);
        _swapExactIn(bob, true, frontRun);
        _swapExactIn(alice, true, victim);
        uint24 backFee = _peekFee(false, backRun);
        _swapExactIn(bob, false, backRun);

        // Bob's own large front-run is enough to push his back-run into a
        // higher fee zone — the curve self-discourages MEV regardless of
        // victim size.
        assertGt(backFee, frontFee, "self-penalty applies");
    }

    /// @dev Reads the dynamic fee the hook would return for a hypothetical
    ///      exact-input swap right now, by calling the lib directly with
    ///      live pool state.
    function _peekFee(bool zeroForOne, uint256 amountIn) internal view returns (uint24) {
        return SmartFeeLib.getDynamicFee(
            _sqrtPriceX96(),
            _poolLiquidity(),
            zeroForOne,
            -int256(amountIn),
            hook.tierParams(2)
        );
    }
}
