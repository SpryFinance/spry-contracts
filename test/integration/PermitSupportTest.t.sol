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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {SpryHook} from "../../contracts/SpryHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";
import {SpryRouter} from "../../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPHelper} from "../utils/LPHelper.sol";

/// @title PermitSupportTest
/// @notice Validates the router's EIP-2612 `selfPermit` + `multicall`
///         integration. The two together let a user execute
///         `approve + swap` in a single transaction by signing an
///         off-chain permit message instead of submitting a separate
///         `approve()` tx first.
contract PermitSupportTest is Test {
    IPoolManager internal manager;
    SpryHook internal hook;
    SpryRouter internal router;
    LPHelper internal lp;
    PermitToken internal token0;
    PermitToken internal token1;
    PoolKey internal key;

    // Deterministic owner so we have a known private key for signing.
    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;

    function setUp() public {
        owner = vm.addr(OWNER_PK);

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

        // Deploy two ERC20Permit-enabled tokens; sort canonically.
        PermitToken a = new PermitToken("AAA");
        PermitToken b = new PermitToken("BBB");
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
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lp),     type(uint256).max);
        token1.approve(address(lp),     type(uint256).max);
        lp.addLiquidity(key, 1e22, 1e22, address(this));

        // Mint balances to owner — but do NOT approve the router.
        // The whole point: owner has zero allowance until permit fires.
        token0.mint(owner, 1e24);
        token1.mint(owner, 1e24);
    }

    /// @dev Build EIP-712 hash for a permit signed by `OWNER_PK`. The
    ///      structure follows OZ's ERC20Permit which uses the canonical
    ///      EIP-2612 typehash.
    function _signPermit(
        PermitToken token,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );
        (v, r, s) = vm.sign(OWNER_PK, digest);
    }

    // ---------------------------------------------------------------------
    // 1. permit + swap in a SINGLE tx via multicall — owner never called
    //    approve(), yet the swap succeeds.
    // ---------------------------------------------------------------------
    function testPermitPlusSwapInOneCall() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token0, address(router), amountIn, deadline);

        // Sanity: owner has zero allowance on the router before the call.
        assertEq(token0.allowance(owner, address(router)), 0, "no prior allowance");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, 1, owner, deadline, "")
        );

        uint256 t0Before = token0.balanceOf(owner);
        uint256 t1Before = token1.balanceOf(owner);

        vm.prank(owner);
        bytes[] memory results = router.multicall(calls);
        uint256 amountOut = abi.decode(results[1], (uint256));

        assertGt(amountOut, 0, "received non-zero output");
        assertEq(t0Before - token0.balanceOf(owner), amountIn, "owner debited exactly amountIn");
        assertEq(token1.balanceOf(owner) - t1Before, amountOut, "owner credited amountOut");
        // The selfPermit consumed the permitted allowance entirely.
        assertEq(token0.allowance(owner, address(router)), 0, "allowance consumed by swap");
    }

    // ---------------------------------------------------------------------
    // 2. Expired permit deadline — the selfPermit's try/catch swallows the
    //    token-level error, so the multicall continues. But the subsequent
    //    swap reverts with the ERC20 allowance failure (no approval was set).
    // ---------------------------------------------------------------------
    function testExpiredPermitCausesSwapRevert() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token0, address(router), amountIn, deadline);

        // Warp past the deadline so the token's permit call rejects the sig.
        vm.warp(deadline + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, 1, owner, deadline + 100, "")
        );

        // selfPermit swallows the expiry error; the swap then reverts because
        // no allowance was set.
        vm.prank(owner);
        vm.expectRevert();
        router.multicall(calls);
    }

    // ---------------------------------------------------------------------
    // 4. Wrong signer — sig was made by `attacker`, not `owner`. selfPermit
    //    swallows the bad-sig revert; the swap then reverts on missing allowance.
    // ---------------------------------------------------------------------
    function testWrongSignerCausesSwapRevert() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;

        // Sign with a DIFFERENT private key while claiming to be `owner`.
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, address(router), amountIn, token0.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token0.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBADBAD), digest);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, 1, owner, deadline, "")
        );

        vm.prank(owner);
        vm.expectRevert();
        router.multicall(calls);
        // Allowance still zero.
        assertEq(token0.allowance(owner, address(router)), 0, "no allowance from forged sig");
    }

    // ---------------------------------------------------------------------
    // 5. Front-run resistance: if a third party submits the same permit
    //    signature first, the owner's own multicall must still complete
    //    (because the resulting allowance is already set). This is what
    //    selfPermit's try/catch protects against.
    // ---------------------------------------------------------------------
    function testFrontRunnerCannotDoSMulticall() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token0, address(router), amountIn, deadline);

        // A front-runner replays the permit BEFORE the owner's tx lands.
        address frontRunner = address(0xF1);
        vm.prank(frontRunner);
        token0.permit(owner, address(router), amountIn, deadline, v, r, s);
        // Token nonce has now incremented; the same sig would no longer work.
        assertEq(token0.allowance(owner, address(router)), amountIn, "front-runner set the allowance");

        // Owner's own multicall — selfPermit will revert internally, but
        // the catch swallows it, and the subsequent swap still works
        // because the allowance is now in place.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, 1, owner, deadline, "")
        );

        uint256 t0Before = token0.balanceOf(owner);
        vm.prank(owner);
        router.multicall(calls);
        assertEq(t0Before - token0.balanceOf(owner), amountIn, "owner's swap completed");
    }

    // ---------------------------------------------------------------------
    // 6. Multicall preserves msg.sender across delegate calls — the swap
    //    in calls[1] sees `owner` as the payer, NOT the router itself.
    // ---------------------------------------------------------------------
    function testMulticallPreservesSender() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token0, address(router), amountIn, deadline);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, 1, owner, deadline, "")
        );

        uint256 ownerT0 = token0.balanceOf(owner);
        vm.prank(owner);
        router.multicall(calls);

        // If multicall had NOT preserved msg.sender, _settle would have
        // tried to pull tokens from the router itself, which has no balance
        // approved to be spent by the router. That path would revert.
        // The fact that owner's balance dropped proves the router pulled
        // from `owner`, not from `address(router)`.
        assertEq(ownerT0 - token0.balanceOf(owner), amountIn, "owner paid, not router");
    }

    // ---------------------------------------------------------------------
    // 7. Multicall reverts atomically when ANY inner call reverts. The
    //    swap in calls[1] uses an unreachable amountOutMin so it fails;
    //    no state change must persist (including selfPermit's allowance).
    // ---------------------------------------------------------------------
    function testMulticallAtomicityOnInnerFailure() public {
        uint256 amountIn = 1e18;
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token0, address(router), amountIn, deadline);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.selfPermit,
            (address(token0), amountIn, deadline, v, r, s)
        );
        // Demand an impossibly high output — swap reverts.
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, amountIn, type(uint256).max, owner, deadline, "")
        );

        vm.prank(owner);
        vm.expectRevert();
        router.multicall(calls);

        // Allowance was rolled back along with the swap.
        assertEq(token0.allowance(owner, address(router)), 0, "allowance rolled back on multicall revert");
        assertEq(token0.nonces(owner), 0, "nonce rolled back on multicall revert");
    }

    // ---------------------------------------------------------------------
    // 8. Bare multicall (no permit involved) — chained swaps in opposite
    //    directions. Confirms multicall works for non-permit flows too.
    // ---------------------------------------------------------------------
    function testMulticallBareDoubleSwap() public {
        // This call is from address(this), which already has both tokens
        // approved at the router.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, true, 1e18, 1, address(this), block.timestamp + 100, "")
        );
        calls[1] = abi.encodeCall(
            SpryRouter.swapExactInputSingle,
            (key, false, 1e18, 1, address(this), block.timestamp + 100, "")
        );
        bytes[] memory results = router.multicall(calls);
        uint256 out0 = abi.decode(results[0], (uint256));
        uint256 out1 = abi.decode(results[1], (uint256));
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    receive() external payable {}
}

/// @notice An ERC20 with native EIP-2612 permit support, used as the
///         test token in this suite.
contract PermitToken is ERC20Permit {
    constructor(string memory name) ERC20(name, name) ERC20Permit(name) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
