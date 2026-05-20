// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Brute-force searches CREATE2 salts until the resulting hook
///         address has its low 14 bits equal to the desired permission flags.
/// @dev    V4 derives a hook's permissions from its address's low 14 bits.
///         Production deploys mine the salt off-chain; this on-chain version
///         is for tests and for deployment scripts that prefer determinism
///         over speed. Solidity loop typically converges within a few
///         thousand iterations for a single-flag mask.
library HookMiner {
    /// @param deployer        CREATE2 deployer (address of the contract that will call CREATE2)
    /// @param flags           target permission bitmap, must be a subset of Hooks.ALL_HOOK_MASK
    /// @param creationCode    runtime + constructor bytecode of the hook (e.g. type(SpryHook).creationCode)
    /// @param constructorArgs abi.encoded constructor arguments
    /// @return hook  address the hook will be deployed to
    /// @return salt  CREATE2 salt that produces `hook`
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hook, bytes32 salt) {
        require(flags & Hooks.ALL_HOOK_MASK == flags, "HookMiner: flags exceed mask");

        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        unchecked {
            for (uint256 i = 0; i < type(uint256).max; ++i) {
                salt = bytes32(i);
                hook = _computeAddress(deployer, salt, initCodeHash);
                if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags) return (hook, salt);
            }
        }
        // unreachable
        revert("HookMiner: not found");
    }

    function _computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
            )
        );
    }
}
