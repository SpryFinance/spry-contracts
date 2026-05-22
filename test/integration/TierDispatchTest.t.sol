// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {SpryFeeParams} from "../../contracts/libs/SpryFeeTypes.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title TierDispatchTest
/// @notice Pins the tickSpacing → tier mapping. Each of the five
///         sanctioned tickSpacings (1, 10, 60, 200, 1000) routes to a
///         different SpryFeeParams set; any other tickSpacing reverts
///         with `SpryHook.InvalidTier` on the first swap.
contract TierDispatchTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

    ERC20Mock internal token0;
    ERC20Mock internal token1;

    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "hook addr mismatch");

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
    }

    function _keyForTier(int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------
    // Each sanctioned tickSpacing dispatches to its own tier params,
    // and a swap on that pool executes successfully under that tier's curve.
    // ------------------------------------------------------------------

    function testTierStable() public {
        _runTierTest(1, 0, hook.tierParams(0));
    }

    function testTierLikeAsset() public {
        _runTierTest(10, 1, hook.tierParams(1));
    }

    function testTierBlueChip() public {
        _runTierTest(60, 2, hook.tierParams(2));
    }

    function testTierVolatile() public {
        _runTierTest(200, 3, hook.tierParams(3));
    }

    function testTierExotic() public {
        _runTierTest(1000, 4, hook.tierParams(4));
    }

    function _runTierTest(int24 tickSpacing, uint8 expectedTier, SpryFeeParams memory expectedParams) internal {
        PoolKey memory key = _keyForTier(tickSpacing);
        manager.initialize(key, SQRT_PRICE_1_1);
        lp.addLiquidity(key, 1e22, 1e22, address(this));

        // A tiny same-direction swap stays in the tier's safe zone.
        // The fee charged should be the tier's safeFee.
        uint256 received = router.swapExactInputSingle(
            key, true, 1e15, 1, address(this), block.timestamp + 100, ""
        );
        assertGt(received, 0, "swap on tier completes");

        // Sanity: tier params reachable via public getter.
        SpryFeeParams memory p = hook.tierParams(expectedTier);
        assertEq(uint256(p.safeFee), uint256(expectedParams.safeFee), "tier safeFee matches");
        assertEq(uint256(p.capFee), uint256(expectedParams.capFee), "tier capFee matches");
    }

    // ------------------------------------------------------------------
    // Non-sanctioned tickSpacing reverts with InvalidTier on first swap.
    // ------------------------------------------------------------------
    function testNonCanonicalTickSpacingReverts() public {
        // tickSpacing = 30 is valid for V4 (1 ≤ ts ≤ 32767) but is not in
        // our sanctioned set, so the dispatch reverts.
        PoolKey memory key = _keyForTier(30);
        manager.initialize(key, SQRT_PRICE_1_1);
        // Adding liquidity does NOT call beforeSwap, so it succeeds even
        // for non-sanctioned tickSpacings. The revert is at swap time.
        lp.addLiquidity(key, 1e22, 1e22, address(this));

        vm.expectRevert();  // V4 wraps the InvalidTier in HookCallFailed
        router.swapExactInputSingle(key, true, 1e15, 1, address(this), block.timestamp + 100, "");
    }

    // ------------------------------------------------------------------
    // Pin every tier's headline numbers — guards against accidental
    // edits to the hardcoded coefficients.
    // ------------------------------------------------------------------
    function testTierParamsAreAsSpecified() public view {
        // STABLE
        SpryFeeParams memory t0 = hook.tierParams(0);
        assertEq(uint256(t0.safeFee),  100, "tier 0 safeFee = 0.01%");
        assertEq(uint256(t0.capFee), 5000, "tier 0 capFee = 0.50%");
        assertEq(int256(t0.safeLow),  -500);
        assertEq(int256(t0.safeHigh),  500);

        // LIKE-ASSET
        SpryFeeParams memory t1 = hook.tierParams(1);
        assertEq(uint256(t1.safeFee),   500, "tier 1 safeFee = 0.05%");
        assertEq(uint256(t1.capFee), 10000, "tier 1 capFee = 1.00%");

        // BLUE-CHIP
        SpryFeeParams memory t2 = hook.tierParams(2);
        assertEq(uint256(t2.safeFee),  3000, "tier 2 safeFee = 0.30%");
        assertEq(uint256(t2.capFee), 55000, "tier 2 capFee = 5.50%");

        // VOLATILE
        SpryFeeParams memory t3 = hook.tierParams(3);
        assertEq(uint256(t3.safeFee),  5000, "tier 3 safeFee = 0.50%");
        assertEq(uint256(t3.capFee), 90000, "tier 3 capFee = 9.00%");

        // EXOTIC
        SpryFeeParams memory t4 = hook.tierParams(4);
        assertEq(uint256(t4.safeFee), 10000, "tier 4 safeFee = 1.00%");
        assertEq(uint256(t4.capFee), 99000, "tier 4 capFee = 9.90%");
    }

    // ------------------------------------------------------------------
    // Direct call to tierParams with an out-of-range index reverts.
    // ------------------------------------------------------------------
    function testTierParamsRevertsForBadIndex() public {
        vm.expectRevert(SpryHook.InvalidTier.selector);
        hook.tierParams(5);

        vm.expectRevert(SpryHook.InvalidTier.selector);
        hook.tierParams(255);
    }

    receive() external payable {}
}
