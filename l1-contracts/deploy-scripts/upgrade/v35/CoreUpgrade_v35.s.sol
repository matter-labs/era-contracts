// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v35 upgrade — the registry bootstrap edge. The base
///         pipeline deploys the changed ecosystem implementations and pins them in a write-once
///         `CoreTransition`; this edge also deploys the bound `CoreUpgradeExecutor` the ecosystem
///         `ProxyAdmin` lands under and the lifecycle coordinator every later upgrade runs through.
///         The governance calls that put those to work are derived from `RegistryBootstrapSequence`
///         over this registry, not authored here.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v35 is DefaultCoreUpgrade {
    /// @notice The bound executor the ecosystem `ProxyAdmin` lands under. Deployed by this
    ///         prepare run.
    CoreUpgradeExecutor public coreUpgradeExecutor;

    /// @notice The lifecycle coordinator of every upgrade after this edge. Deployed by this
    ///         prepare run; the CTM prepare constructs its executor answering to it.
    EcosystemUpgradeExecutor public ecosystemUpgradeExecutor;

    /// @inheritdoc DefaultCoreUpgrade
    /// @dev Every installable ecosystem implementation differs from the v0.34.0 build by runtime
    ///      codehash. In executable code only `L1Bridgehub`, `L1MessageRoot` and
    ///      `L1ChainAssetHandler` changed; the other four differ in their CBOR metadata alone,
    ///      because sources in their import closure (shared error and interface files) changed.
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](7);
        names[0] = "L1Bridgehub";
        names[1] = "L1MessageRoot";
        names[2] = "L1ChainAssetHandler";
        names[3] = "L1Nullifier";
        names[4] = "L1AssetRouter";
        names[5] = "L1NativeTokenVault";
        names[6] = "CTMDeploymentTracker";
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
    ///         migration exists and reads every call off (see {CTMUpgrade_v35}).
    /// @dev All ride the CREATE2 factory: the Safe bundle replays factory transactions only, so
    ///      a plain CREATE would leave the stage-1 calls pointing at codeless addresses.
    function deployEcosystemUpgradeObjects() public virtual override {
        deployCoreTransition();
        require(address(coreTransition) != address(0), "the bootstrap edge needs an ecosystem leg");
        coreUpgradeExecutor = CoreUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(CoreUpgradeExecutor).creationCode,
                    abi.encode(getOwnerAddress(), ProxyAdmin(coreAddresses.shared.transparentProxyAdmin)),
                    "CoreUpgradeExecutor"
                )
            )
        );
        ecosystemUpgradeExecutor = EcosystemUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(EcosystemUpgradeExecutor).creationCode,
                    abi.encode(getOwnerAddress(), coreUpgradeExecutor),
                    "EcosystemUpgradeExecutor"
                )
            )
        );
    }
}
