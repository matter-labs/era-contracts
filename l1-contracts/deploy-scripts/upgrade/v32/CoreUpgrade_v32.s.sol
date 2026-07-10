// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {CoreUpgradeParams} from "../default-upgrade/UpgradeParams.sol";

/// @notice Script used for the v32 (atomic interop) upgrade flow, upgrading from v31.
/// @dev v32 is storage-compatible but NOT function-preserving (see `CTMUpgrade_v32`). Compared
///      to v31, the core side collapses to pure implementation deploys:
///      - no new proxies (AssetTracker / ChainRegistrationSender were v31 introductions; on the
///        v31 baseline every proxy already exists and is discovered by introspection);
///      - no wiring or ownership calls (`setAddresses`, `setAssetTracker`, `acceptOwnership` were
///        one-shot v31 introductions);
///      - no reinitializers (storage is compatible as-is);
///      - no legacy-gateway decommission and no token migration (v31 one-offs).
///      The base's stage-1 proxy upgrades cover everything: implementations deployed via CREATE2
///      land on their existing address when unchanged, making those swaps no-ops.
/// @dev v32 is intended to be the first registry-driven upgrade — see `CTMUpgrade_v32` notes.
contract CoreUpgrade_v32 is Script, DefaultCoreUpgrade {
    /// @notice Single-call entry point invoked by the protocol-ops CLI.
    ///         Runs the ecosystem-wide core deploys; CTM deploys are handled by `CTMUpgrade_v32`.
    function noGovernancePrepare(CoreUpgradeParams memory _params) public {
        initializeWithArgs(
            _params.bridgehubProxyAddress,
            _params.isZKsyncOS,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// @notice Deploy the v32 ecosystem-wide implementation set (implementations only).
    function deployNewEcosystemContractsL1() public virtual override {
        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub", false);
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot", false);
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier", false);
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter", false);
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault", false);
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract(
            "CTMDeploymentTracker",
            false
        );
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler", false);
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender",
            false
        );
    }

    /// @notice Override to properly set deployerAddress in upgrade context.
    /// @dev In Forge scripts with vm.broadcast(), msg.sender is the script address, but the
    ///      actual deployer is the broadcast key — same fix as every upgrade script needs.
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();
        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:", config.deployerAddress);
    }
}
