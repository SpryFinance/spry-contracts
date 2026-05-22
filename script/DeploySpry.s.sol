// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {SpryHook} from "../contracts/SpryHook.sol";
import {SpryRouter} from "../contracts/SpryRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeploySpry
/// @notice Deploys SpryHook (at a salt-mined CREATE2 address that encodes
///         the BEFORE_SWAP permission bits) and SpryRouter against the
///         canonical Uniswap V4 PoolManager. Liquidity management is
///         provided by Uniswap's canonical PositionManager (see V4_POSITION_MANAGER
///         below) — Spry does not redeploy or wrap it.
/// @dev    Required environment:
///           V4_POOL_MANAGER       address of the canonical PoolManager on
///                                 the target chain (mainnet, Sepolia, Base, ...)
///           V4_POSITION_MANAGER   address of Uniswap's PositionManager on
///                                 the target chain. The script does NOT
///                                 call into it — it verifies the address
///                                 has bytecode so operators don't ship a
///                                 deployment that points users at a void.
///           SPRY_BLOCK_WINDOW     number of blocks the per-pool cumulative
///                                 window covers, chosen to span the same
///                                 wall-clock attack horizon on every chain.
///                                 No default: the operator MUST set this
///                                 consciously. Recommended values per
///                                 chain are documented on `SpryHook.BLOCK_WINDOW`.
///           PRIVATE_KEY           deployer key (forge --broadcast)
///         Optional environment:
///           V4_PERMIT2            address of Permit2 on the target chain.
///                                 Defaults to the canonical cross-chain
///                                 address (0x000...22D473..A3). Set this on
///                                 networks where Permit2 is deployed at a
///                                 non-canonical address.
///
/// Example (Ethereum mainnet):
///   V4_POOL_MANAGER=0x... \
///   V4_POSITION_MANAGER=0x... \
///   SPRY_BLOCK_WINDOW=1 \
///     forge script script/DeploySpry.s.sol \
///       --rpc-url $RPC --broadcast --private-key $PRIVATE_KEY
contract DeploySpry is Script {
    /// Canonical foundry CREATE2 deployer used by `new C{salt: s}(args)`.
    address internal constant FORGE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Cross-chain canonical Permit2 deployment. Same address on every EVM
    /// chain where Permit2 has been deployed.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public returns (SpryHook hook, SpryRouter router) {
        address managerAddr     = vm.envAddress("V4_POOL_MANAGER");
        address positionMgrAddr = vm.envAddress("V4_POSITION_MANAGER");
        address permit2Addr     = vm.envOr("V4_PERMIT2", CANONICAL_PERMIT2);
        uint64  blockWindow     = uint64(vm.envUint("SPRY_BLOCK_WINDOW"));
        IPoolManager manager    = IPoolManager(managerAddr);

        require(blockWindow > 0, "Deploy: SPRY_BLOCK_WINDOW must be > 0");

        console.log("PoolManager:           ", managerAddr);
        console.log("PositionManager:       ", positionMgrAddr);
        console.log("Permit2:               ", permit2Addr);
        console.log("BLOCK_WINDOW:          ", blockWindow);

        // Sanity-check that every external dependency the deployment depends
        // on actually has code at the supplied address. Catching this at
        // deploy is cheaper than discovering it after wallets are wired up.
        require(managerAddr.code.length     > 0, "Deploy: no code at PoolManager address");
        require(positionMgrAddr.code.length > 0, "Deploy: no code at PositionManager address");
        require(permit2Addr.code.length     > 0, "Deploy: no code at Permit2 address");

        // Mine a salt whose resulting CREATE2 address has the BEFORE_SWAP
        // permission bit set (and only that bit). Pure math, no broadcast.
        (address predicted, bytes32 salt) = HookMiner.find(
            FORGE_CREATE2,
            Hooks.BEFORE_SWAP_FLAG,
            type(SpryHook).creationCode,
            abi.encode(manager, blockWindow)
        );
        console.log("Predicted hook address:", predicted);
        console.logBytes32(salt);

        vm.startBroadcast();
        hook = new SpryHook{salt: salt}(manager, blockWindow);
        require(address(hook) == predicted, "Deploy: hook address mismatch");
        router = new SpryRouter(manager, IAllowanceTransfer(permit2Addr));
        vm.stopBroadcast();

        console.log("SpryHook deployed at:  ", address(hook));
        console.log("SpryRouter deployed at:", address(router));
        console.log("(LP UX provided by PositionManager at:", positionMgrAddr, ")");
    }
}
