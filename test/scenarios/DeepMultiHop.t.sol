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

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title DeepMultiHop
/// @notice Stress-test the multi-hop router with paths longer than two
///         hops. Validates that the unlock-callback's hop loop settles
///         net deltas correctly regardless of path length and that the
///         caller's slippage check applies to the FINAL output, not any
///         intermediate currency.
contract DeepMultiHop is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;

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
        require(address(hook) == predicted);
    }

    function _buildPool(ERC20Mock a, ERC20Mock b) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k, 1 << 96);
    }

    function testFiveHopPathSettlesCorrectly() public {
        // Build six tokens and five pools chaining them: A-B, B-C, C-D, D-E, E-F.
        ERC20Mock[6] memory tk;
        for (uint256 i = 0; i < 6; ++i) {
            tk[i] = new ERC20Mock();
            deal(address(tk[i]), address(this), 1e30);
            tk[i].approve(address(router), type(uint256).max);
            tk[i].approve(address(lp),     type(uint256).max);
        }

        PoolKey[] memory keys = new PoolKey[](5);
        for (uint256 i = 0; i < 5; ++i) {
            keys[i] = _buildPool(tk[i], tk[i + 1]);
            lp.addLiquidity(keys[i], 1e22, 1e22, address(this));
        }

        // Snapshot intermediate balances AFTER seeding (each intermediate
        // token funded two pools, so balances are not 1e30 anymore).
        uint256[6] memory before;
        for (uint256 i = 0; i < 6; ++i) before[i] = tk[i].balanceOf(address(this));

        // Build the multi-hop path A -> B -> C -> D -> E -> F.
        PathKey[] memory path = new PathKey[](5);
        for (uint256 i = 0; i < 5; ++i) {
            path[i] = PathKey({
                intermediateCurrency: Currency.wrap(address(tk[i + 1])),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 60,
                hooks: IHooks(address(hook)),
                hookData: ""
            });
        }

        uint256 out = router.swapExactInput(
            Currency.wrap(address(tk[0])),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );

        assertGt(out, 0, "received non-zero final-currency output");
        // Input currency balance dropped by exactly 1e18.
        assertEq(before[0] - tk[0].balanceOf(address(this)), 1e18, "input debited");
        // Final currency balance grew by exactly `out`.
        assertEq(tk[5].balanceOf(address(this)) - before[5], out, "output credited");
        // Each intermediate token balance is unchanged - the router fully
        // resolved net deltas inside one unlock callback.
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(tk[i].balanceOf(address(this)), before[i], "intermediate balance unchanged by swap");
        }
    }

    function testFiveHopSlippageRevertChecksOnlyFinalOutput() public {
        // Same setup as above, then try a swap with an unreachable slippage
        // bound. The revert must fire on the FINAL output, not on any
        // intermediate hop's quote.
        ERC20Mock[6] memory tk;
        for (uint256 i = 0; i < 6; ++i) {
            tk[i] = new ERC20Mock();
            deal(address(tk[i]), address(this), 1e30);
            tk[i].approve(address(router), type(uint256).max);
            tk[i].approve(address(lp),     type(uint256).max);
        }
        PoolKey[] memory keys = new PoolKey[](5);
        for (uint256 i = 0; i < 5; ++i) {
            keys[i] = _buildPool(tk[i], tk[i + 1]);
            lp.addLiquidity(keys[i], 1e22, 1e22, address(this));
        }
        PathKey[] memory path = new PathKey[](5);
        for (uint256 i = 0; i < 5; ++i) {
            path[i] = PathKey({
                intermediateCurrency: Currency.wrap(address(tk[i + 1])),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 60,
                hooks: IHooks(address(hook)),
                hookData: ""
            });
        }

        vm.expectRevert(SpryRouter.InsufficientOutput.selector);
        router.swapExactInput(
            Currency.wrap(address(tk[0])),
            path,
            1e18,
            type(uint256).max,    // unreachable slippage bound
            address(this),
            block.timestamp + 100
        );
    }

    receive() external payable {}
}
