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
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title Permit2SupportTest
/// @notice End-to-end coverage of the router's Permit2 integration:
///         the *ViaPermit2 swap entry points, the `permit()` forwarding
///         inherited from Permit2Forwarder, and their composition with
///         multicall to deliver permit2 + swap in one transaction.
///
///         We deploy the OFFICIAL Permit2 bytecode at its canonical
///         address (0x000000000022D473030F116dDEE9F6B43aC78BA3) via
///         v4-periphery's `DeployPermit2` helper (which uses vm.etch).
///         This is the exact Permit2 every mainnet chain has, so the
///         tests exercise real Permit2 logic — not a mock.
contract Permit2SupportTest is Test, DeployPermit2 {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    IAllowanceTransfer internal permit2;
    PoolKey internal key;

    // Deterministic owner so we have a known private key for signing.
    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;

    // Permit2's EIP-712 typehashes (from
    // lib/v4-periphery/lib/permit2/src/libraries/PermitHash.sol). Defined
    // here so we don't pull a 0.8.17 file into our 0.8.26 test compile.
    bytes32 internal constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        owner = vm.addr(OWNER_PK);

        // Etch the canonical Permit2 bytecode at its mainnet address.
        permit2 = IAllowanceTransfer(deployPermit2());

        manager = IPoolManager(new PoolManager(address(this)));
        router = new SpryRouter(manager, permit2);
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

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Seed liquidity from the test contract.
        deal(address(token0), address(this), 1e30);
        deal(address(token1), address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        lp.addLiquidity(key, 1e22, 1e22, address(this));

        // Owner: tokens + the standard one-time approval to Permit2 itself.
        // After this, swaps only need a Permit2-signed message — no further
        // token-level approval to the router.
        deal(address(token0), owner, 1e24);
        deal(address(token1), owner, 1e24);
        vm.startPrank(owner);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Helpers — build + sign a Permit2 PermitSingle message
    // -----------------------------------------------------------------
    function _buildPermitSingle(address token, uint160 amount, uint48 expiration)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory permitSingle)
    {
        (, , uint48 nonce) = permit2.allowance(owner, token, address(router));
        permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token,
                amount: amount,
                expiration: expiration,
                nonce: nonce
            }),
            spender: address(router),
            sigDeadline: uint256(expiration)
        });
    }

    function _signPermitSingle(IAllowanceTransfer.PermitSingle memory p)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 detailsHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, p.details));
        bytes32 structHash = keccak256(
            abi.encode(_PERMIT_SINGLE_TYPEHASH, detailsHash, p.spender, p.sigDeadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------------
    // 1. permit2 + swap in ONE multicall — owner never approved the router
    //    on token0 directly, only on Permit2 (one-time, done in setUp).
    // ---------------------------------------------------------------------
    function testPermit2PlusSwapInOneCall() public {
        uint160 amount = 1e18;
        uint48 expiration = uint48(block.timestamp + 100);

        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), amount, expiration);
        bytes memory signature = _signPermitSingle(permitSingle);

        // No direct router allowance on token0.
        assertEq(token0.allowance(owner, address(router)), 0, "no direct router allowance");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, signature));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingleViaPermit2,
            (key, true, amount, 1, owner, block.timestamp + 100, "")
        );

        uint256 t0Before = token0.balanceOf(owner);
        uint256 t1Before = token1.balanceOf(owner);

        vm.prank(owner);
        bytes[] memory results = router.multicall(calls);
        uint256 amountOut = abi.decode(results[1], (uint256));

        assertGt(amountOut, 0);
        assertEq(t0Before - token0.balanceOf(owner), amount, "owner debited exactly via Permit2");
        assertEq(token1.balanceOf(owner) - t1Before, amountOut, "owner credited amountOut");
        // Direct token allowance still zero — we never touched it.
        assertEq(token0.allowance(owner, address(router)), 0, "direct allowance untouched");
    }

    // ---------------------------------------------------------------------
    // 2. permit2 + exact-output single swap.
    // ---------------------------------------------------------------------
    function testPermit2PlusExactOutputSingle() public {
        uint160 maxIn = 5e18;
        uint48 expiration = uint48(block.timestamp + 100);

        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), maxIn, expiration);
        bytes memory signature = _signPermitSingle(permitSingle);

        uint256 wantOut = 1e18;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, signature));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactOutputSingleViaPermit2,
            (key, true, wantOut, uint256(maxIn), owner, block.timestamp + 100, "")
        );

        uint256 t1Before = token1.balanceOf(owner);
        vm.prank(owner);
        bytes[] memory results = router.multicall(calls);
        uint256 amountIn = abi.decode(results[1], (uint256));

        assertGt(amountIn, 0);
        assertLe(amountIn, maxIn);
        assertEq(token1.balanceOf(owner) - t1Before, wantOut, "owner received exact requested amount");
    }

    // ---------------------------------------------------------------------
    // 3. Multi-hop exact-input via Permit2.
    // ---------------------------------------------------------------------
    function testPermit2PlusMultiHopExactInput() public {
        // Build a third token + a second pool so we can multi-hop.
        ERC20Mock tokenC = new ERC20Mock();
        deal(address(tokenC), address(this), 1e30);
        deal(address(tokenC), owner, 1e24);
        tokenC.approve(address(router), type(uint256).max);
        tokenC.approve(address(lp),     type(uint256).max);
        vm.prank(owner);
        tokenC.approve(address(permit2), type(uint256).max);

        (Currency cFirst, Currency cSecond) = address(token1) < address(tokenC)
            ? (Currency.wrap(address(token1)), Currency.wrap(address(tokenC)))
            : (Currency.wrap(address(tokenC)), Currency.wrap(address(token1)));
        PoolKey memory keyBC = PoolKey({
            currency0: cFirst,
            currency1: cSecond,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyBC, SQRT_PRICE_1_1);
        lp.addLiquidity(keyBC, 1e22, 1e22, address(this));

        uint160 amountIn = 1e18;
        uint48 expiration = uint48(block.timestamp + 100);
        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), amountIn, expiration);
        bytes memory signature = _signPermitSingle(permitSingle);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
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

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, signature));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputViaPermit2,
            (Currency.wrap(address(token0)), path, uint256(amountIn), 1, owner, block.timestamp + 100)
        );

        uint256 cBefore = tokenC.balanceOf(owner);
        vm.prank(owner);
        router.multicall(calls);
        assertGt(tokenC.balanceOf(owner) - cBefore, 0, "owner received tokenC via multi-hop Permit2 path");
    }

    // ---------------------------------------------------------------------
    // 5. Wrong signer — Permit2 rejects the permit, the chained swap's
    //    settle fails because no allowance exists in Permit2's ledger.
    // ---------------------------------------------------------------------
    function testWrongSignerCausesPermit2SwapRevert() public {
        uint160 amount = 1e18;
        uint48 expiration = uint48(block.timestamp + 100);

        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), amount, expiration);

        // Sign with the wrong key.
        bytes32 detailsHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permitSingle.details));
        bytes32 structHash = keccak256(abi.encode(
            _PERMIT_SINGLE_TYPEHASH, detailsHash, permitSingle.spender, permitSingle.sigDeadline
        ));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBADBAD), digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, badSig));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingleViaPermit2,
            (key, true, amount, 1, owner, block.timestamp + 100, "")
        );

        // Permit2Forwarder.permit swallows the bad-sig revert via try/catch,
        // so the multicall continues. But the swap then has no Permit2
        // allowance to draw from and reverts atomically.
        vm.prank(owner);
        vm.expectRevert();
        router.multicall(calls);
    }

    // ---------------------------------------------------------------------
    // 6. Expired sigDeadline — Permit2 rejects the permit; swap reverts.
    // ---------------------------------------------------------------------
    function testExpiredSigDeadlineCausesPermit2SwapRevert() public {
        uint160 amount = 1e18;
        uint48 expiration = uint48(block.timestamp + 100);

        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), amount, expiration);
        bytes memory signature = _signPermitSingle(permitSingle);

        // Warp past the sigDeadline.
        vm.warp(uint256(expiration) + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, signature));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingleViaPermit2,
            (key, true, amount, 1, owner, block.timestamp + 100, "")
        );

        vm.prank(owner);
        vm.expectRevert();
        router.multicall(calls);
    }

    // ---------------------------------------------------------------------
    // 7. Front-run resistance — a third party replays the same Permit2
    //    signature first. Permit2Forwarder's try/catch swallows the
    //    duplicate-permit revert; the chained swap still completes because
    //    the allowance is now in Permit2's ledger.
    // ---------------------------------------------------------------------
    function testFrontRunnerCannotDoSPermit2Multicall() public {
        uint160 amount = 1e18;
        uint48 expiration = uint48(block.timestamp + 100);

        IAllowanceTransfer.PermitSingle memory permitSingle =
            _buildPermitSingle(address(token0), amount, expiration);
        bytes memory signature = _signPermitSingle(permitSingle);

        // Front-runner submits the same Permit2 message first.
        address frontRunner = address(0xF1);
        vm.prank(frontRunner);
        permit2.permit(owner, permitSingle, signature);
        // Owner's permit2 nonce has bumped; the same sig wouldn't work
        // standalone again.

        // Owner's multicall — the inner permit call reverts inside
        // Permit2Forwarder's try/catch, but the swap still works because
        // the allowance is in place from the front-runner's tx.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Permit2Forwarder.permit, (owner, permitSingle, signature));
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingleViaPermit2,
            (key, true, amount, 1, owner, block.timestamp + 100, "")
        );

        uint256 t0Before = token0.balanceOf(owner);
        vm.prank(owner);
        router.multicall(calls);
        assertEq(t0Before - token0.balanceOf(owner), amount, "swap completed despite the front-run");
    }

    // ---------------------------------------------------------------------
    // 8. Permit2 path for a native-ETH leg must revert with the explicit
    //    Permit2NativeUnsupported selector. Permit2 cannot mediate ETH.
    // ---------------------------------------------------------------------
    function testPermit2NativeETHReverts() public {
        // Build a native-ETH pool.
        PoolKey memory keyETH = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token0)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyETH, SQRT_PRICE_1_1);
        deal(address(this), 100 ether);
        lp.addLiquidity{value: 10 ether}(keyETH, 10 ether, 10 ether, address(this));

        // Owner: zeroForOne = true means ETH-in, which Permit2 can't mediate.
        deal(owner, 5 ether);
        vm.prank(owner);
        vm.expectRevert(SpryRouter.Permit2NativeUnsupported.selector);
        router.swapExactInputSingleViaPermit2{value: 1 ether}(
            keyETH, true, 1 ether, 1, owner, block.timestamp + 100
        ,
        "");
    }

    // ---------------------------------------------------------------------
    // 9. Direct ERC20 path (`swapExactInputSingle`, no Permit2) still works.
    //    Sanity check that adding the Permit2 paths didn't break the
    //    non-Permit2 surface.
    // ---------------------------------------------------------------------
    function testDirectPathStillWorks() public {
        // Owner approves the router directly on token0 — the classic flow.
        vm.prank(owner);
        token0.approve(address(router), type(uint256).max);

        uint256 t1Before = token1.balanceOf(owner);
        vm.prank(owner);
        uint256 amountOut = router.swapExactInputSingle(
            key, true, 1e18, 1, owner, block.timestamp + 100
        ,
        "");
        assertGt(amountOut, 0);
        assertEq(token1.balanceOf(owner) - t1Before, amountOut, "direct path still credits owner");
    }

    receive() external payable {}
}
