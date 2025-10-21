// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ISystemContext} from "../state-transition/l2-deps/ISystemContext.sol";
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
    // slither-disable-next-line locked-ether
    function genesisUpgrade(
        bool _isZKsyncOS,
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external {
        if (_chainId == 0) {
            revert InvalidChainId();
        }

        // On ZKsyncOS, the chain Id is a part of implicit block properties
        // and so does not need to set inside the genesis upgrade.
        if (!_isZKsyncOS) {
            ISystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR).setChainId(_chainId);
        }

        // solhint-disable-next-line func-named-parameters
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _isZKsyncOS,
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData,
            true
        );

        emit UpgradeComplete(_chainId);
    }
}
