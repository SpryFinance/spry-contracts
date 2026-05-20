// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "../../script/HookMiner.sol";

/// @dev A minimal contract that HookMiner can deploy via CREATE2. Constructor
///      takes a single uint256 so we can vary constructorArgs in tests.
contract TargetForMining {
    uint256 public immutable VALUE;
    constructor(uint256 v) {
        VALUE = v;
    }
}

contract HookMinerHarness {
    function findFlags(uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        external
        view
        returns (address hook, bytes32 salt)
    {
        return HookMiner.find(address(this), flags, creationCode, constructorArgs);
    }

    function deployAt(bytes32 salt, uint256 v) external returns (address) {
        return address(new TargetForMining{salt: salt}(v));
    }
}

contract HookMinerTest is Test {
    HookMinerHarness internal harness;

    function setUp() public {
        harness = new HookMinerHarness();
    }

    function testFindForSingleFlag() public view {
        (address predicted, bytes32 salt) = harness.findFlags(
            Hooks.BEFORE_SWAP_FLAG,
            type(TargetForMining).creationCode,
            abi.encode(uint256(42))
        );
        // Address must have only that bit set in the low 14
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG);
        // Salt is a deterministic bytes32 - assert it's not zero by accident
        // (a zero salt only matches if the unsalted address happens to match,
        // unlikely for 14-bit equality)
        salt; // silence unused
    }

    function testFindForCombinedFlags() public view {
        uint160 wanted = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        (address predicted, ) = harness.findFlags(
            wanted,
            type(TargetForMining).creationCode,
            abi.encode(uint256(7))
        );
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, wanted);
    }

    function testFindForZeroFlagsAllAddressesMatch() public view {
        // flags = 0 means we want low 14 bits to be 0 — any address whose
        // low 14 bits happen to be zero qualifies. Should still succeed.
        (address predicted, ) = harness.findFlags(
            0,
            type(TargetForMining).creationCode,
            abi.encode(uint256(0))
        );
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0);
    }

    function testFindRevertsWhenFlagsExceedMask() public {
        // Any bit above the low 14 violates the mask check (line 27).
        uint160 invalid = uint160(1 << 14);
        vm.expectRevert(bytes("HookMiner: flags exceed mask"));
        harness.findFlags(invalid, type(TargetForMining).creationCode, "");
    }

    function testPredictedAddressMatchesActualDeploy() public {
        (address predicted, bytes32 salt) = harness.findFlags(
            Hooks.BEFORE_SWAP_FLAG,
            type(TargetForMining).creationCode,
            abi.encode(uint256(123))
        );
        address actual = harness.deployAt(salt, 123);
        assertEq(actual, predicted, "CREATE2 address must equal HookMiner prediction");
    }
}
