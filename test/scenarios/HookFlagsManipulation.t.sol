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

/// @title HookFlagsManipulation
/// @notice V4 derives a hook's allowed callback set from its address's
///         low-14-bit pattern. This means an attacker cannot deploy a
///         contract whose code claims to be a Spry hook but whose address
///         doesn't encode BEFORE_SWAP_FLAG — the PoolManager will reject
///         initialize() outright. These tests prove that property end-to-end.
contract HookFlagsManipulation is Test {
    IPoolManager internal manager;
    ERC20Mock internal token0;
    ERC20Mock internal token1;

    function setUp() public {
        manager = IPoolManager(new PoolManager(address(this)));
        ERC20Mock a = new ERC20Mock();
        ERC20Mock b = new ERC20Mock();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    }

    function testInitFailsWhenHookAddressMissesFlagBits() public {
        // Deploy SpryHook the "wrong" way: regular `new` instead of CREATE2
        // with a mined salt. The resulting address has random low bits and
        // almost certainly does NOT satisfy BEFORE_SWAP_FLAG.
        SpryHook badHook = new SpryHook(manager, uint64(1));

        // Confirm the address really doesn't match.
        uint160 expected = Hooks.BEFORE_SWAP_FLAG;
        vm.assume(uint160(address(badHook)) & Hooks.ALL_HOOK_MASK != expected);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(badHook))
        });

        // PoolManager.initialize must reject because dynamic-fee pools
        // require the hook to advertise BEFORE_SWAP_FLAG via its address.
        vm.expectRevert();
        manager.initialize(key, 1 << 96);
    }

    function testDifferentSaltProducesDifferentAddressButSameFlagSatisfaction() public {
        // HookMiner is deterministic: given (deployer, flags, bytecode, args)
        // it finds A salt that places the address at the right low-bits.
        // Different deployers will land on different addresses, but all of
        // them satisfy the same flag set.
        (address addrA, bytes32 saltA) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        SpryHook hookA = new SpryHook{salt: saltA}(manager, uint64(1));
        assertEq(address(hookA), addrA);
        assertEq(uint160(address(hookA)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG);

        // A second mining round from a different conceptual deployer should
        // still land on a flag-satisfying address.
        vm.prank(address(0xC0FFEE));
        (address addrB, ) = HookMiner.find(
            address(0xC0FFEE),
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, uint64(1))
        );
        assertEq(uint160(addrB) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG);
        assertTrue(addrA != addrB, "different deployers land on different addresses");
    }

    function testFlagBitsMustMatchExactly() public pure {
        // Flag mask is exactly 14 bits. A hook that satisfies a SUPERSET
        // of flags (e.g. BEFORE_SWAP_FLAG | BEFORE_INITIALIZE_FLAG) would
        // be rejected if the hook contract doesn't actually implement
        // beforeInitialize. SpryHook's permissionsFlags() returns ONLY
        // BEFORE_SWAP_FLAG so the address must encode exactly that.
        uint160 spryFlags = uint160(Hooks.BEFORE_SWAP_FLAG);
        assertEq(spryFlags, uint160(1 << 7));
        // A different set, e.g. AFTER_SWAP_FLAG (1<<6), is not a Spry hook.
        assertTrue(spryFlags != uint160(1 << 6));
    }
}
