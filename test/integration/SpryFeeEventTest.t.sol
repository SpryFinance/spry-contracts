// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {SmartFeeLib} from "../../contracts/libs/SmartFeeLib.sol";
import {SpryFeeParams} from "../../contracts/libs/SpryFeeTypes.sol";
import {HookMiner} from "../../script/HookMiner.sol";

/// @title SpryFeeEventTest
/// @notice Locks the semantics of the SpryHook.SpryFee event, the canonical
///         off-chain signal a subgraph relies on. Covers:
///           * shape (one emission per swap, exactly the right pool id),
///           * fee field has the OVERRIDE_FEE_FLAG stripped,
///           * fee equals SmartFeeLib.marginalFee for the same trajectory,
///           * zone/dispatchCase classifiers agree with the audited math,
///           * windowId equals the active windowStart and updates on reset.
contract SpryFeeEventTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    PoolKey internal key;
    PoolModifyLiquidityTest internal modifyRouter;
    PoolSwapTest internal swapRouter;
    ERC20Mock internal token0;
    ERC20Mock internal token1;

    // BLUE-CHIP tier, the same setup other hook tests use; gives all
    // three zones (safe / alert / danger) and both dispatch sides plenty
    // of room with a 1e22 liquidity seed.
    int24 internal constant TICK_SPACING = 60;
    uint64 internal constant BLOCK_WINDOW = 4;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    // Re-declared locally so vm.expectEmit / log parsing see a matching topic0.
    event SpryFee(
        PoolId indexed id,
        int256 cumBefore,
        int256 cumAfter,
        uint24 fee,
        uint8  zone,
        uint8  dispatchCase,
        uint64 windowId
    );

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        modifyRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(modifyRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, BLOCK_WINDOW)
        );
        hook = new SpryHook{salt: salt}(manager, BLOCK_WINDOW);
        require(address(hook) == predicted, "hook addr mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(1e22);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function _addLiquidity(int256 liquidityDelta) internal {
        modifyRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev SpryFee event signature, used to filter logs in vm.recordLogs().
    function _topic() internal pure returns (bytes32) {
        return keccak256(
            "SpryFee(bytes32,int256,int256,uint24,uint8,uint8,uint64)"
        );
    }

    /// @dev Collect every SpryFee emission since the last vm.recordLogs(),
    ///      filtered to our hook address. Returns parsed fields.
    function _collectSpryFee()
        internal
        returns (
            uint256 count,
            int256 lastCumBefore,
            int256 lastCumAfter,
            uint24 lastFee,
            uint8 lastZone,
            uint8 lastCase,
            uint64 lastWindowId,
            bytes32 lastPidTopic
        )
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 t = _topic();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != t) continue;
            count++;
            lastPidTopic = logs[i].topics[1];
            (
                lastCumBefore,
                lastCumAfter,
                lastFee,
                lastZone,
                lastCase,
                lastWindowId
            ) = abi.decode(logs[i].data, (int256, int256, uint24, uint8, uint8, uint64));
        }
    }

    // ==================================================================
    // Shape
    // ==================================================================

    /// @notice One swap → exactly one SpryFee emission for the right pool.
    function test_spryFee_emittedOncePerSwap() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (
            uint256 count,
            ,
            ,
            ,
            ,
            ,
            ,
            bytes32 pidTopic
        ) = _collectSpryFee();
        assertEq(count, 1, "expected exactly one SpryFee per swap");
        assertEq(pidTopic, PoolId.unwrap(key.toId()), "pid topic mismatch");
    }

    /// @notice The event's `fee` field is the CLEAN dynamic fee (no
    ///         OVERRIDE_FEE_FLAG OR-ed in). A subgraph reads `fee` directly
    ///         and must not see the override bit.
    function test_spryFee_feeFieldHasNoOverrideFlag() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (, , , uint24 fee, , , , ) = _collectSpryFee();
        assertTrue(fee < LPFeeLibrary.OVERRIDE_FEE_FLAG, "override bit must be stripped from event fee");
        // And it cannot exceed the BLUE-CHIP tier's capFee.
        SpryFeeParams memory p = hook.tierParams(2);
        assertLe(uint256(fee), uint256(p.capFee), "fee above tier capFee");
    }

    // ==================================================================
    // Agreement with the audited math
    // ==================================================================

    /// @notice The emitted fee equals the value `marginalFee` would
    ///         compute for the same (cumBefore, cumAfter, tier params).
    function test_spryFee_feeMatchesMarginalFee() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (
            ,
            int256 cumBefore,
            int256 cumAfter,
            uint24 fee,
            ,
            ,
            ,
        ) = _collectSpryFee();
        SpryFeeParams memory p = hook.tierParams(2);
        assertEq(
            uint256(fee),
            uint256(SmartFeeLib.marginalFee(cumBefore, cumAfter, p)),
            "event fee disagrees with marginalFee"
        );
    }

    /// @notice The emitted `zone` matches the library's classifier for the
    ///         post-swap cumulative.
    function test_spryFee_zoneMatchesClassifier() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (
            ,
            ,
            int256 cumAfter,
            ,
            uint8 zone,
            ,
            ,
        ) = _collectSpryFee();
        SpryFeeParams memory p = hook.tierParams(2);
        assertEq(uint256(zone), uint256(SmartFeeLib.zoneOf(cumAfter, p)), "zone mismatch");
    }

    /// @notice The emitted `dispatchCase` matches the library's classifier.
    function test_spryFee_dispatchCaseMatchesClassifier() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (
            ,
            int256 cumBefore,
            int256 cumAfter,
            ,
            ,
            uint8 dCase,
            ,
        ) = _collectSpryFee();
        assertEq(
            uint256(dCase),
            uint256(SmartFeeLib.dispatchCase(cumBefore, cumAfter)),
            "dispatch case mismatch"
        );
    }

    // ==================================================================
    // Window semantics
    // ==================================================================

    /// @notice After a swap, the event's windowId equals the pool's
    ///         windowStart (the persisted block number at which the
    ///         active window opened).
    function test_spryFee_windowIdMatchesActiveWindow() public {
        vm.recordLogs();
        _swap(true, -1e18);
        (, , , , , , uint64 windowId, ) = _collectSpryFee();
        (uint64 windowStart, ) = hook.poolWindow(key.toId());
        assertEq(windowId, windowStart, "windowId != pool's windowStart");
    }

    /// @notice After the window expires (≥ BLOCK_WINDOW blocks elapsed),
    ///         the next swap's event reports the new windowStart and
    ///         cumBefore == 0 (post-reset).
    function test_spryFee_windowIdAdvancesAfterReset() public {
        // First swap establishes a window.
        vm.recordLogs();
        _swap(true, -1e18);
        (, , , , , , uint64 firstWindow, ) = _collectSpryFee();

        // Roll past the window.
        vm.roll(block.number + BLOCK_WINDOW);

        vm.recordLogs();
        _swap(true, -1e18);
        (
            ,
            int256 cumBeforeAfterReset,
            ,
            ,
            ,
            ,
            uint64 secondWindow,

        ) = _collectSpryFee();

        assertGt(secondWindow, firstWindow, "windowId must advance after reset");
        assertEq(secondWindow, uint64(block.number), "windowId must equal current block");
        assertEq(cumBeforeAfterReset, int256(0), "cumBefore must be 0 immediately after a window reset");
    }

    // ==================================================================
    // Multi-swap continuity
    // ==================================================================

    /// @notice Within one window the event's `cumBefore` of swap N equals
    ///         the `cumAfter` of swap N-1, regardless of dispatch case,
    ///         the trajectory the subgraph reconstructs from the event
    ///         stream is contiguous.
    function test_spryFee_trajectoryContiguousWithinWindow() public {
        // Swap 1.
        vm.recordLogs();
        _swap(true, -1e18);
        (, , int256 cumAfter1, , , , , ) = _collectSpryFee();

        // Swap 2 in the SAME block (so same window).
        vm.recordLogs();
        _swap(true, -1e18);
        (, int256 cumBefore2, , , , , , ) = _collectSpryFee();

        assertEq(cumBefore2, cumAfter1, "trajectory broke between swaps in the same window");
    }
}
