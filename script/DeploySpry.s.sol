// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {SpryHook} from "../contracts/SpryHook.sol";
import {SpryRouter} from "../contracts/SpryRouter.sol";
import {HookMiner} from "../contracts/HookMiner.sol";

/// @title DeploySpry
/// @notice Deploys SpryHook (at a salt-mined CREATE2 address that encodes
///         the BEFORE_SWAP permission bits) and SpryRouter against the
///         canonical Uniswap V4 PoolManager.
/// @dev    Required environment:
///           V4_POOL_MANAGER   address of the canonical PoolManager on the
///                             target chain (mainnet, Sepolia, Base, etc.)
///           PRIVATE_KEY       deployer key (forge --broadcast)
///
/// Example:
///   V4_POOL_MANAGER=0x... \
///     forge script script/v4/DeploySpry.s.sol \
///       --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY
contract DeploySpry is Script {
    /// Canonical foundry CREATE2 deployer used by `new C{salt: s}(args)`.
    address internal constant FORGE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (SpryHook hook, SpryRouter router) {
        address managerAddr = vm.envAddress("V4_POOL_MANAGER");
        IPoolManager manager = IPoolManager(managerAddr);

        console.log("Deploying against PoolManager:", managerAddr);

        // Mine a salt whose resulting CREATE2 address has the BEFORE_SWAP
        // permission bit set (and only that bit). Pure math, no broadcast.
        (address predicted, bytes32 salt) = HookMiner.find(
            FORGE_CREATE2,
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager)
        );
        console.log("Predicted hook address:", predicted);
        console.logBytes32(salt);

        vm.startBroadcast();
        hook = new SpryHook{salt: salt}(manager);
        require(address(hook) == predicted, "Deploy: hook address mismatch");
        router = new SpryRouter(manager);
        vm.stopBroadcast();

        console.log("SpryHook deployed at:    ", address(hook));
        console.log("SpryRouter deployed at:", address(router));
    }
}
