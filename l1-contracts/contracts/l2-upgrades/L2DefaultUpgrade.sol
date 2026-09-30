// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2DefaultUpgrade} from "../upgrades/IL2DefaultUpgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2DefaultUpgrade, the L2 side of a regular (non-genesis) protocol upgrade.
/// @dev Not tied to a single release: it re-runs the upgrade path of the force-deployed contracts'
/// initialization, which is safe to repeat on a chain at any protocol version from v31 on.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2DefaultUpgrade is IL2DefaultUpgrade {
    /// @inheritdoc IL2DefaultUpgrade
    function upgrade(
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external {
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData,
            false // isGenesisUpgrade
        );
    }
}
