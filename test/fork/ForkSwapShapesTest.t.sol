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
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title ForkSwapShapesTest
/// @notice End-to-end coverage of swap and liquidity shapes that the
///         original `ForkTest.t.sol` doesn't reach, executed against a
///         live, canonical Uniswap V4 PoolManager via an RPC fork.
///
///         Same opt-in mechanism as `ForkTest`:
///           FORK_RPC_URL      - JSON-RPC endpoint (required to activate)
///           V4_POOL_MANAGER   - canonical PoolManager address on that chain
///         When `FORK_RPC_URL` is empty every test in this file returns
///         immediately and Foundry records them as passing, so default
///         `forge test` stays green offline.
contract ForkSwapShapesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;
    ERC20Mock internal tokenC;

    PoolKey internal keyAB;          // tokenA <-> tokenB (sorted)
    PoolKey internal keyBC;          // tokenB <-> tokenC (sorted)
    PoolKey internal keyETH;         // native ETH <-> tokenA

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant SEED = 1e22;

    bool internal forkActive;

    modifier onlyFork() {
        if (!forkActive) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkActive = false;
            return;
        }

        vm.createSelectFork(rpc);

        manager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        router = new SpryRouter(manager, IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        lp = new LPHelper(manager);

        // Three ERC20 mocks for multi-hop + ETH-pair coverage.
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        ERC20Mock c = new ERC20Mock();
        // Assign a canonical alphabetic order so the test reads naturally:
        // tokenA < tokenB < tokenC by address.
        (tokenA, tokenB, tokenC) = _sortThree(a, b, c);

        deal(address(tokenA), address(this), 1e30);
        deal(address(tokenB), address(this), 1e30);
        deal(address(tokenC), address(this), 1e30);
        deal(address(this), 1000 ether);
        tokenA.approve(address(router), type(uint256).max);
        tokenA.approve(address(lp),     type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenB.approve(address(lp),     type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);

        // Mine the hook salt against the LIVE PoolManager address.
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        hook = new SpryHook{salt: salt}(manager, uint64(1));
        require(address(hook) == predicted, "fork: hook addr mismatch");

        keyAB = _erc20Pool(tokenA, tokenB);
        keyBC = _erc20Pool(tokenB, tokenC);
        keyETH = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenA)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(keyAB, SQRT_PRICE_1_1);
        manager.initialize(keyBC, SQRT_PRICE_1_1);
        manager.initialize(keyETH, SQRT_PRICE_1_1);

        lp.addLiquidity(keyAB, SEED, SEED, address(this));
        lp.addLiquidity(keyBC, SEED, SEED, address(this));
        lp.addLiquidity{value: 50 ether}(keyETH, 50 ether, 50 ether, address(this));

        forkActive = true;
    }

    function _sortThree(ERC20Mock a, ERC20Mock b, ERC20Mock c)
        private
        pure
        returns (ERC20Mock x, ERC20Mock y, ERC20Mock z)
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

    function _erc20Pool(ERC20Mock t0, ERC20Mock t1) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // ---------------------------------------------------------------------
    // 1. Exact-output single swap against the live PoolManager.
    // ---------------------------------------------------------------------
    function testForkExactOutputSingle() public onlyFork {
        uint256 tokenABefore = tokenA.balanceOf(address(this));
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        uint256 amountOutWanted = 1e18;

        uint256 amountIn = router.swapExactOutputSingle(
            keyAB,
            true,             // sell tokenA for tokenB
            amountOutWanted,
            type(uint256).max,
            address(this),
            block.timestamp + 100
        ,
        "");

        assertGt(amountIn, 0, "router reports non-zero input");
        assertEq(
            tokenBBefore + amountOutWanted,
            tokenB.balanceOf(address(this)),
            "received exactly the requested output"
        );
        assertEq(
            tokenABefore - amountIn,
            tokenA.balanceOf(address(this)),
            "paid exactly the reported input"
        );
    }

    // ---------------------------------------------------------------------
    // 2. Native-ETH pool: add (in setUp), swap, remove, all on real V4.
    // ---------------------------------------------------------------------
    function testForkNativeETHRoundTrip() public onlyFork {
        // Snapshot pre-swap state.
        uint256 ethBefore = address(this).balance;
        uint256 tokABefore = tokenA.balanceOf(address(this));

        // Swap 1 ETH for tokenA against the LIVE manager.
        uint256 received = router.swapExactInputSingle{value: 1 ether}(
            keyETH,
            true,             // currency0 (native ETH) -> currency1 (tokenA)
            1 ether,
            1,
            address(this),
            block.timestamp + 100
        ,
        "");
        assertGt(received, 0, "received tokenA from ETH swap");
        assertEq(tokenA.balanceOf(address(this)) - tokABefore, received);
        assertEq(ethBefore - address(this).balance, 1 ether);

        // Confirm we can still pull liquidity out — remove a sliver of LP.
        PoolId pid = keyETH.toId();
        uint128 liq = manager.getLiquidity(pid);
        uint128 burnAmount = uint128(uint256(liq) / 10);
        (uint256 a0, uint256 a1) = lp.removeLiquidity(keyETH, burnAmount, address(this), address(this));
        assertGt(a0, 0, "removed ETH");
        assertGt(a1, 0, "removed tokenA");
    }

    // ---------------------------------------------------------------------
    // 3. Multi-hop A -> B -> C against the live PoolManager.
    // ---------------------------------------------------------------------
    function testForkMultiHopThreeTokenPath() public onlyFork {
        uint256 aBefore = tokenA.balanceOf(address(this));
        uint256 cBefore = tokenC.balanceOf(address(this));
        uint256 bBefore = tokenB.balanceOf(address(this));

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        uint256 out = router.swapExactInput(
            Currency.wrap(address(tokenA)),
            path,
            1e18,
            1,
            address(this),
            block.timestamp + 100
        );

        assertGt(out, 0, "final-currency output is non-zero");
        assertEq(aBefore - tokenA.balanceOf(address(this)), 1e18, "input debited exactly");
        assertEq(tokenC.balanceOf(address(this)) - cBefore, out, "output credited exactly");
        // Intermediate balance unchanged by the multi-hop — the unlock
        // callback settled net deltas in one atomic flush.
        assertEq(tokenB.balanceOf(address(this)), bBefore, "tokenB transit balance unchanged");
    }

    // ---------------------------------------------------------------------
    // 4. Full round-trip on a live pool: add, swap, remove. Asserts that
    //    fees accrued during the swap leave the LP strictly better off
    //    than the principal they deposited.
    // ---------------------------------------------------------------------
    function testForkAddSwapRemoveRoundTrip() public onlyFork {
        // Use keyBC so we don't interfere with state recorded by other tests.
        // Lone-LP scenario: this contract is the only depositor on this pool
        // beyond the setUp seed (which we own).
        uint256 aIn = 1e21;
        uint256 bIn = 1e21;
        (uint128 liq, , ) = lp.addLiquidity(keyBC, aIn, bIn, address(this));
        assertGt(liq, 0);

        // Generate fee flow: a series of balanced round-trip swaps.
        for (uint256 i = 0; i < 10; ++i) {
            router.swapExactInputSingle(keyBC, true, 5e19, 1, address(this), block.timestamp + 100, "");
            router.swapExactInputSingle(keyBC, false, 5e19, 1, address(this), block.timestamp + 100, "");
        }

        uint256 bBefore = tokenB.balanceOf(address(this));
        uint256 cBefore = tokenC.balanceOf(address(this));

        (uint256 out0, uint256 out1) = lp.removeLiquidity(keyBC, liq, address(this), address(this));

        uint256 b0 = tokenB.balanceOf(address(this)) - bBefore;
        uint256 c0 = tokenC.balanceOf(address(this)) - cBefore;
        assertEq(b0 + c0, out0 + out1, "router-reported amounts match balance delta");

        // Sum of withdrawals must equal or exceed the principal — balanced
        // swap flow leaves the spot price untouched, so any positive
        // delta is pure fee accrual against the live PoolManager.
        assertGe(out0 + out1, aIn + bIn, "LP value never decreases under balanced flow");
    }

    receive() external payable {}
}
