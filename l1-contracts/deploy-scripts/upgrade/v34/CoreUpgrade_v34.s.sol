// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";

/// @notice Core (ecosystem) side of the v34 upgrade: deploys the new shared-singleton
///         implementation set, pins it in a write-once `CoreRegistry` (the enum-indexed
///         inventory — one slot per `L1EcosystemContract` member, inert slots explicit), and
///         deploys the bound `CoreUpgradeExecutor` the ecosystem `ProxyAdmin` lands under
///         together with the lifecycle coordinator every later upgrade runs through. The
///         governance calls that put those to work are derived from `RegistryBootstrapSequence`
///         over this registry, not authored here.
contract CoreUpgrade_v34 is DefaultCoreUpgrade {
    /// @notice The bound executor the ecosystem `ProxyAdmin` lands under. Deployed by this
    ///         prepare run.
    CoreUpgradeExecutor public coreUpgradeExecutor;

    /// @notice The lifecycle coordinator of every upgrade after this edge. Deployed by this
    ///         prepare run; the CTM prepare constructs its executor answering to it.
    EcosystemUpgradeExecutor public ecosystemUpgradeExecutor;

    /// @notice Deploy the v34 ecosystem-wide implementation set (implementations only).
    function deployNewEcosystemContractsL1() public virtual override {
        // Defensive: on ecosystems whose discovery misses the ChainRegistrationSender proxy
        // (see the v32 script for the introspection edge case), read it from the bridgehub so
        // the force-deployments data carries the correct aliased sender.
        if (coreAddresses.bridgehub.proxies.chainRegistrationSender == address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = IBridgehubBase(
                coreAddresses.bridgehub.proxies.bridgehub
            ).chainRegistrationSender();
        }

        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub");
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier");
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter");
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault");
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract("CTMDeploymentTracker");
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler");
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender"
        );
    }

    /// @notice The coordinator this run deployed — the CTM prepare constructs its executor
    ///         answering to it.
    function getEcosystemUpgradeExecutor() public view virtual override returns (address) {
        return address(ecosystemUpgradeExecutor);
    }

    /// @notice The core executor this run deployed.
    function getCoreUpgradeExecutor() public view virtual override returns (CoreUpgradeExecutor) {
        return coreUpgradeExecutor;
    }

    /// @notice The bootstrap edge deploys the registry, the bound executor that will apply it and
    ///         the coordinator every later operation runs through (a recurring prepare finds both
    ///         live). It declares no governance call of its own: the whole edge — both domains —
    ///         is derived from `RegistryBootstrapSequence`, which the CTM prepare deploys once the
    ///         migration exists and reads every call off (see {CTMUpgrade_v34}).
    /// @dev All ride the CREATE2 factory: the Safe bundle replays factory transactions only, so
    ///      a plain CREATE would leave the stage-1 calls pointing at codeless addresses.
    function deployEcosystemUpgradeObjects() public virtual override {
        deployCoreRegistry();
        require(address(coreRegistry) != address(0), "v34 deploys every ecosystem implementation");
        coreUpgradeExecutor = CoreUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(CoreUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        ProxyAdmin(coreAddresses.shared.transparentProxyAdmin),
                        // The audited-object anchor for every registry this executor accepts,
                        // taken from the artifact those registries are DEPLOYED from (see
                        // {BytecodeUtils.getDeployedBytecodeHash}).
                        BytecodeUtils.getDeployedBytecodeHash("CoreRegistry.sol", "CoreRegistry")
                    ),
                    "CoreUpgradeExecutor"
                )
            )
        );
        ecosystemUpgradeExecutor = EcosystemUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(EcosystemUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        coreUpgradeExecutor,
                        // Same anchoring for the operations the coordinator accepts.
                        BytecodeUtils.getDeployedBytecodeHash(
                            "EcosystemUpgradeOperation.sol",
                            "EcosystemUpgradeOperation"
                        )
                    ),
                    "EcosystemUpgradeExecutor"
                )
            )
        );
    }
}
