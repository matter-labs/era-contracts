// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2V33Upgrade} from "../upgrades/IL2V33Upgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V33Upgrade, the L2 side of the v33 upgrade.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V33Upgrade is IL2V33Upgrade {
    /// @inheritdoc IL2V33Upgrade
    function upgrade(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external {
        // solhint-disable-next-line func-named-parameters
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _isZKsyncOS,
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData,
            false // isGenesisUpgrade
        );
    }
}
