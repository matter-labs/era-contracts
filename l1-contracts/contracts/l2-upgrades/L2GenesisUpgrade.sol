// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

import {InvalidChainId} from "../common/L1ContractErrors.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The l2 component of the genesis upgrade.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    /// @notice The function that is delegateCalled from the complex upgrader.
    /// @dev It is used to set the chainId and to deploy the force deployments.
    /// @param _chainId the chain id
    /// @param _ctmDeployer the address of the ctm deployer
    /// @param _fixedForceDeploymentsData the force deployments data
    /// @param _additionalForceDeploymentsData the additional force deployments data
    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable {
        if (_chainId == 0) {
            revert InvalidChainId();
        }

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData,
            true
        );

        emit UpgradeComplete(_chainId);
    }
}
