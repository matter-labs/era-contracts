// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ISystemContext} from "../state-transition/l2-deps/ISystemContext.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

ISystemContext constant SYSTEM_CONTEXT_CONTRACT = ISystemContext(payable(address(uint160(0x8000 + 0x0b))));

error InvalidChainId();

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The l2 component of the genesis upgrade.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    /// @notice The function that is delegateCalled from the complex upgrader.
    /// @dev It is used to set the chainId and to deploy the force deployments.
    /// @param _isZKsyncOS whether the chain runs in ZKsync OS mode
    /// @param _chainId the chain id
    /// @param _ctmDeployer the address of the ctm deployer
    /// @param _fixedForceDeploymentsData the force deployments data
    /// @param _additionalForceDeploymentsData the additional force deployments data
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
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);

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
