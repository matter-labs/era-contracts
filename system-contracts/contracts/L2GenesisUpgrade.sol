// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SYSTEM_CONTEXT_CONTRACT, DEPLOYER_SYSTEM_CONTRACT, L2_STANDARD_TRIGGER_ACCOUNT_ADDR} from "./Constants.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {InvalidChainId} from "contracts/SystemContractErrors.sol";
import {IL2GenesisUpgrade} from "./interfaces/IL2GenesisUpgrade.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";
import {IContractDeployer} from "./interfaces/IContractDeployer.sol";

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
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);
        // Execute the call to set addresses in BridgeHub.
        (bool success, bytes memory returnData) = SystemContractHelper.mimicCall(
            address(DEPLOYER_SYSTEM_CONTRACT),
            L2_STANDARD_TRIGGER_ACCOUNT_ADDR,
            abi.encodeCall(
                IContractDeployer.updateInteropAccountVersion,
                (IContractDeployer.AccountAbstractionVersion.Version1)
            )
        );

        // Revert with the original revert reason if the call failed.
        /// @dev Propagate the revert reason from the failed call.
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), returndatasize())
            }
        }

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );

        emit UpgradeComplete(_chainId);
    }
}
