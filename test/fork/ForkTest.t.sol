// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {LPHelper} from "../utils/LPHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title ForkTest
/// @notice Smoke-test the SpryHook + SpryRouter against a real, already-
///         deployed Uniswap V4 PoolManager via a forked RPC. The fork is
///         only created when both env vars are set so the suite stays
///         green in plain `forge test`. CI sets these for a Sepolia run.
///
/// Env vars consumed (read with vm.envOr to keep the test optional):
///   FORK_RPC_URL       - JSON-RPC endpoint (e.g. an Alchemy/Sepolia URL)
///   V4_POOL_MANAGER    - address of the canonical PoolManager on that chain
///
/// When FORK_RPC_URL is empty, every test in this contract returns early
/// and Foundry records them as passing.
contract ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    PoolKey internal key;

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    bool internal forkActive;

    modifier onlyFork() {
        if (!forkActive) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // No RPC -> mark as skipped. setUp returns; modifier short-circuits each test.
            forkActive = false;
            return;
        }

        vm.createSelectFork(rpc);

        address managerAddr = vm.envAddress("V4_POOL_MANAGER");
        manager = IPoolManager(managerAddr);

        // Deploy our periphery against the live PoolManager.
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "fork: hook addr mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);
        lp.addLiquidity(key, 1e22, 1e22, address(this));

        forkActive = true;
    }

    /// @notice The hook's mined address must encode BEFORE_SWAP_FLAG and
    ///         only that flag, regardless of the chain we fork.
    function testForkHookAddressEncodesPermissions() public view onlyFork {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG);
    }

    /// @notice End-to-end smoke: a single-hop swap against the live
    ///         PoolManager must succeed and deliver non-zero output.
    function testForkSwapSingleHop() public onlyFork {
        uint256 balBefore = token1.balanceOf(address(this));
        uint256 amountOut = router.swapExactInputSingle(
            key,
            true,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");
        assertGt(amountOut, 0);
        assertEq(token1.balanceOf(address(this)) - balBefore, amountOut);
    }

    /// @notice Manager state read via StateLibrary on the live deployment.
    function testForkPoolStateReadable() public view onlyFork {
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(_pid());
        uint128 liquidity = manager.getLiquidity(_pid());
        assertGt(sqrtPriceX96, 0);
        assertGt(liquidity, 0);
    }

    function _pid() internal view returns (PoolId) {
        return key.toId();
    }

    receive() external payable {}
}
