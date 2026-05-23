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
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title GasRegressionTest
/// @notice Pins gas-cost ceilings for the four primary swap paths through
///         SpryRouter + SpryHook. Each ceiling is set ~30% above the
///         current observed cost so a small optimizer drift doesn't fire
///         a false alarm — but a structural regression (e.g. a refactor
///         that adds an SLOAD per swap, or that mis-inlines a library
///         function) will trip the relevant assertion.
///
///         The four pinned paths:
///           1. Safe-zone swap         (cheap path: no E.pow, one slot write)
///           2. Alert-zone swap        (one linear-area multiply)
///           3. Danger-zone swap       (two PRB-Math E.pow calls)
///           4. Two-hop multi-hop swap (two beforeSwap calls + transient
///                                      accounting)
///
///         If a future change legitimately moves gas costs (e.g. an
///         intentional optimization), update the constants below
///         deliberately — that single-commit-of-record is the audit trail
///         the test is designed to force.
contract GasRegressionTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

    ERC20Mock internal token0;
    ERC20Mock internal token1;
    ERC20Mock internal token2;
    PoolKey internal keyAB;
    PoolKey internal keyBC;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    // -----------------------------------------------------------------
    // Gas ceilings — pinned ~30% above observed local cost. Update only
    // alongside a deliberate optimization commit.
    // -----------------------------------------------------------------
    uint256 internal constant GAS_CEIL_SAFE_SWAP       = 270_000;
    uint256 internal constant GAS_CEIL_ALERT_SWAP      = 280_000;
    uint256 internal constant GAS_CEIL_DANGER_SWAP     = 330_000;
    uint256 internal constant GAS_CEIL_MULTIHOP_2_SAFE = 450_000;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        router  = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp      = new LPHelper(manager);

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
        ERC20Mock c = new ERC20Mock();
        (token0, token1, token2) = _sortThree(a, b, c);

        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        deal(address(token2), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token2.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        token2.approve(address(lp),     type(uint256).max);

        keyAB = _erc20Key(token0, token1);
        keyBC = _erc20Key(token1, token2);
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, 1e22, 1e22, address(this));
        lp.addLiquidity(keyBC, 1e22, 1e22, address(this));
    }

    function _sortThree(ERC20Mock a, ERC20Mock b, ERC20Mock c)
        internal
        pure
        returns (ERC20Mock, ERC20Mock, ERC20Mock)
    {
        ERC20Mock[3] memory arr = [a, b, c];
        for (uint256 i = 0; i < 2; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (address(arr[j]) < address(arr[i])) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        return (arr[0], arr[1], arr[2]);
    }

    function _erc20Key(ERC20Mock x, ERC20Mock y) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(x)),
            currency1: Currency.wrap(address(y)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------
    // 1. Safe zone: tiny swap, |delta| << safeHigh, so the entire
    //    marginal integration stays inside the safe zone — no
    //    alertArea or dangerArea calls.
    // ------------------------------------------------------------------
    function testGasSafeZoneSwap() public {
        uint256 amount = 1e18;  // 0.01% of reserves → delta ≈ 0 → safe
        uint256 gasBefore = gasleft();
        router.swapExactInputSingle(keyAB, true, amount, 1, address(this), block.timestamp + 100, "");
        uint256 used = gasBefore - gasleft();

        (, int128 signedCum) = hook.poolWindow(keyAB.toId());
        uint256 absCum = signedCum >= 0 ? uint256(int256(signedCum)) : uint256(-int256(signedCum));
        assertLt(absCum, 250, "safe-zone swap did not land in safe zone");

        emit log_named_uint("[GAS] safe-zone swap   ", used);
        assertLt(used, GAS_CEIL_SAFE_SWAP, "safe-zone swap exceeded gas ceiling");
    }

    // ------------------------------------------------------------------
    // 2. Alert zone: larger swap that pushes delta past the safe-zone
    //    boundary into the linear-ramp range, exercising alertArea
    //    inside SmartFeeLib._integral. No E.pow yet.
    // ------------------------------------------------------------------
    function testGasAlertZoneSwap() public {
        uint256 amount = 2e22;  // pushes delta to ~-400, deep into left alert
        uint256 gasBefore = gasleft();
        router.swapExactInputSingle(keyAB, true, amount, 1, address(this), block.timestamp + 100, "");
        uint256 used = gasBefore - gasleft();

        (, int128 signedCum) = hook.poolWindow(keyAB.toId());
        uint256 absCum = signedCum >= 0 ? uint256(int256(signedCum)) : uint256(-int256(signedCum));
        assertGt(absCum, 250, "alert-zone swap did not enter alert range");
        assertLt(absCum, 500, "alert-zone swap overshot into danger");

        emit log_named_uint("[GAS] alert-zone swap  ", used);
        assertLt(used, GAS_CEIL_ALERT_SWAP, "alert-zone swap exceeded gas ceiling");
    }

    // ------------------------------------------------------------------
    // 3. Danger-zone integration. A single swap's per-mille delta is
    //    bounded by ±1000 (constant-product asymptotic), so danger is
    //    only reachable by pre-pushing the cumulative past ±1000 via
    //    earlier swaps within the same block window. After the pre-
    //    setup the measured swap's marginalFee must integrate over a
    //    range that spans into danger — invoking PRB-Math E.pow twice
    //    in the antiderivative computation.
    //
    //    We verify the cum actually landed in danger before claiming
    //    to have measured the danger path.
    // ------------------------------------------------------------------
    function testGasDangerZoneSwap() public {
        // Pre-setup: three large same-direction swaps land the cumulative
        // inside the DANGER range (|cum| ∈ (alertEnd=500, dangerEnd=1000)).
        // Stopping at three keeps cum well below dangerEnd so the measured
        // swap's marginal integrates over the danger zone (invoking
        // dangerArea + two E.pow calls) rather than spilling into cap.
        for (uint256 i = 0; i < 3; ++i) {
            router.swapExactInputSingle(keyAB, true, 1e22, 1, address(this), block.timestamp + 100, "");
        }

        (, int128 signedCum) = hook.poolWindow(keyAB.toId());
        uint256 absCum = signedCum >= 0 ? uint256(int256(signedCum)) : uint256(-int256(signedCum));
        assertGt(absCum, 500, "pre-setup failed to push cum past alertEnd");
        assertLt(absCum, 1_000, "pre-setup overshot - cum past dangerEnd into cap");

        // Measure: a small same-direction swap. cumBefore is in the
        // danger zone (|cum| ∈ (500, 1000)), cumAfter pushes further
        // but stays within danger — so dangerArea is exercised end-
        // to-end, invoking two E.pow calls in the antiderivative.
        uint256 gasBefore = gasleft();
        router.swapExactInputSingle(keyAB, true, 1e21, 1, address(this), block.timestamp + 100, "");
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("[GAS] danger-zone swap ", used);
        assertLt(used, GAS_CEIL_DANGER_SWAP, "danger-zone swap exceeded gas ceiling");
    }

    // ------------------------------------------------------------------
    // 4. Two-hop multi-hop swap (A → B → C). Both hops stay in safe.
    //    Two `beforeSwap` calls + two cumulative-window writes + V4's
    //    transient-delta accounting across hops.
    // ------------------------------------------------------------------
    function testGasMultiHopTwoSafeHops() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 amount = 1e18;
        uint256 gasBefore = gasleft();
        router.swapExactInput(
            Currency.wrap(address(token0)),
            path,
            amount,
            1,
            address(this),
            block.timestamp + 100
        );
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("[GAS] multi-hop (2 safe)", used);
        assertLt(used, GAS_CEIL_MULTIHOP_2_SAFE, "multi-hop (2 safe hops) exceeded gas ceiling");
    }

    receive() external payable {}
}
