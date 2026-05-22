// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";

/// @notice Pure-coverage suite: exercises every no-op IHooks entry point on
///         SpryHook (impersonating PoolManager) so their selector returns
///         and onlyPoolManager guards are covered. The functional hooks are
///         covered by SpryHookTest's integration runs.
contract SpryHookCoverageTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    PoolKey internal key;

    address internal nonManager = makeAddr("nonManager");

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));

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
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------
    // Drift guard: the deployed hook's address bits must encode exactly
    // the permission set returned by `permissionsFlags()`. V4 reads the
    // low 14 bits of the hook address at runtime to decide which
    // callbacks to invoke; the hook contract has no other way to opt
    // into a callback. If a future refactor adds a flag to
    // `permissionsFlags()` (e.g., AFTER_SWAP_FLAG) without also updating
    // every HookMiner call site, deployment will succeed but V4 will
    // silently skip the newly-claimed callback. This test fails first.
    // ------------------------------------------------------------------
    function testHookAddressBitsMatchPermissionsFlags() public view {
        uint160 flags = hook.permissionsFlags();
        // V4 stores hook permission flags in the low 14 bits of the hook
        // address (see Hooks.ALL_HOOK_MASK == (1 << 14) - 1).
        uint160 mask = uint160((1 << 14) - 1);
        assertEq(
            uint160(address(hook)) & mask,
            flags & mask,
            "hook address bits do not encode permissionsFlags()"
        );
        // Pin the expected flag set so any change to permissionsFlags()
        // requires a deliberate test update.
        assertEq(
            flags,
            Hooks.BEFORE_SWAP_FLAG,
            "permissionsFlags() drifted from BEFORE_SWAP_FLAG"
        );
    }

    // ------------------------------------------------------------------
    // Each entry point, called as PoolManager, returns the right selector.
    // ------------------------------------------------------------------

    function testBeforeInitializeReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.beforeInitialize(address(this), key, 1 << 96);
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    function testAfterInitializeReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.afterInitialize(address(this), key, 1 << 96, 0);
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    function testBeforeAddLiquidityReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.beforeAddLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)}),
            ""
        );
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function testAfterAddLiquidityReturnsSelectorAndZeroDelta() public {
        vm.prank(address(manager));
        (bytes4 sel, BalanceDelta d) = hook.afterAddLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            ""
        );
        assertEq(sel, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d), 0);
    }

    function testBeforeRemoveLiquidityReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.beforeRemoveLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: -1, salt: bytes32(0)}),
            ""
        );
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function testAfterRemoveLiquidityReturnsSelectorAndZeroDelta() public {
        vm.prank(address(manager));
        (bytes4 sel, BalanceDelta d) = hook.afterRemoveLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: -1, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            ""
        );
        assertEq(sel, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d), 0);
    }

    function testAfterSwapReturnsSelectorAndZeroInt128() public {
        vm.prank(address(manager));
        (bytes4 sel, int128 hookDelta) = hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 1}),
            BalanceDelta.wrap(0),
            ""
        );
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(hookDelta, int128(0));
    }

    function testBeforeDonateReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.beforeDonate(address(this), key, 0, 0, "");
        assertEq(sel, IHooks.beforeDonate.selector);
    }

    function testAfterDonateReturnsSelector() public {
        vm.prank(address(manager));
        bytes4 sel = hook.afterDonate(address(this), key, 0, 0, "");
        assertEq(sel, IHooks.afterDonate.selector);
    }

    // ------------------------------------------------------------------
    // onlyPoolManager guard on each entry point.
    // ------------------------------------------------------------------

    function testNoopsRevertWhenCallerIsNotPoolManager() public {
        ModifyLiquidityParams memory mlp =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 1});

        vm.startPrank(nonManager);

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.beforeInitialize(nonManager, key, 1 << 96);

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.afterInitialize(nonManager, key, 1 << 96, 0);

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(nonManager, key, mlp, "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.afterAddLiquidity(nonManager, key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(nonManager, key, mlp, "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(nonManager, key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.afterSwap(nonManager, key, sp, BalanceDelta.wrap(0), "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.beforeDonate(nonManager, key, 0, 0, "");

        vm.expectRevert(SpryHook.NotPoolManager.selector);
        hook.afterDonate(nonManager, key, 0, 0, "");

        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Constructor guard: BLOCK_WINDOW cannot be zero. A zero window
    // would degenerate the cumulative tracker into a no-op because
    // every swap would trip the `block.number >= windowStart + 0`
    // condition and immediately reset.
    // -----------------------------------------------------------------
    function testConstructorRejectsZeroBlockWindow() public {
        vm.expectRevert(SpryHook.ZeroBlockWindow.selector);
        new SpryHook(manager, uint64(0));
    }

    function testConstructorAcceptsAndPersistsBlockWindow() public {
        // Different chains pin different values; the immutable preserves
        // whatever the deployer passed.
        SpryHook h1 = new SpryHook(manager, uint64(1));
        SpryHook h6 = new SpryHook(manager, uint64(6));
        SpryHook h48 = new SpryHook(manager, uint64(48));
        assertEq(h1.BLOCK_WINDOW(),  1);
        assertEq(h6.BLOCK_WINDOW(),  6);
        assertEq(h48.BLOCK_WINDOW(), 48);
    }
}
