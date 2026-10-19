// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {CoreExecutorDeployment, UpgradeExecutorsRecord} from "../../utils/UpgradeExecutorsRecord.sol";

/// @notice Core (ecosystem) side of the v35 upgrade — the registry bootstrap edge. The base
///         pipeline deploys the changed ecosystem implementations and pins them in a write-once
///         Core-domain `ProxyUpgradeTransition`; this edge also deploys the bound
///         `CoreUpgradeExecutor` the ecosystem `ProxyAdmin` lands under. The governance calls that
///         put those to work are derived from `RegistryBootstrapSequence`, not authored here.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v35 is DefaultCoreUpgrade {
    /// @notice The bound executor the ecosystem `ProxyAdmin` lands under. Deployed by this
    ///         prepare run.
    CoreUpgradeExecutor public coreUpgradeExecutor;

    /// @dev How {deployEcosystemUpgradeObjects} constructed it, for the output record.
    CoreExecutorDeployment internal executorDeployment;

    /// @inheritdoc DefaultCoreUpgrade
    /// @dev Every ecosystem implementation differs from the v0.34.0 build by runtime codehash. In
    ///      executable code only `L1Bridgehub`, `L1MessageRoot` and `L1ChainAssetHandler` changed;
    ///      the other six differ in their CBOR metadata alone, because sources in their import
    ///      closure (shared error and interface files) changed.
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](9);
        names[0] = "L1Bridgehub";
        names[1] = "L1MessageRoot";
        names[2] = "L1ChainAssetHandler";
        names[3] = "L1Nullifier";
        names[4] = "L1AssetRouter";
        names[5] = "L1NativeTokenVault";
        names[6] = "CTMDeploymentTracker";
        names[7] = "L1InteropHandler";
        names[8] = "ChainRegistrationSender";
    }

    /// @notice The core executor this run deployed.
    function getCoreUpgradeExecutor() public view virtual override returns (CoreUpgradeExecutor) {
        return coreUpgradeExecutor;
    }

    /// @inheritdoc DefaultCoreUpgrade
    function upgradeExecutorsRecord() internal override returns (bool recorded, string memory json) {
        require(executorDeployment.coreExecutor != address(0), "upgrade executor not deployed");
        return (true, UpgradeExecutorsRecord.serializeCore(executorDeployment));
    }

    /// @notice The bootstrap edge deploys the Core-domain transition and the bound executor that will
    ///         apply it (a recurring prepare finds the executor live). It declares no governance call
    ///         of its own: the whole edge — both domains — is derived from `RegistryBootstrapSequence`,
    ///         which the CTM prepare deploys once the migration exists and reads every call off (see
    ///         {CTMUpgrade_v35}).
    /// @dev All ride the CREATE2 factory: the Safe bundle replays factory transactions only, so
    ///      a plain CREATE would leave the bundle's calls pointing at codeless addresses.
    function deployEcosystemUpgradeObjects() public virtual override {
        deployCoreTransition();
        require(address(coreTransition) != address(0), "the bootstrap edge needs an ecosystem leg");
        (, bytes32 salt) = getCreate2FactoryParams();
        address owner = getOwnerAddress();
        address proxyAdmin = coreAddresses.shared.transparentProxyAdmin;
        require(proxyAdmin != address(0), "ecosystem ProxyAdmin not discovered");
        coreUpgradeExecutor = CoreUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(CoreUpgradeExecutor).creationCode,
                    abi.encode(owner, ProxyAdmin(proxyAdmin)),
                    "CoreUpgradeExecutor"
                )
            )
        );
        executorDeployment = CoreExecutorDeployment({
            coreExecutor: address(coreUpgradeExecutor),
            create2Salt: salt,
            initialOwner: owner,
            proxyAdmin: proxyAdmin
        });
    }
}
