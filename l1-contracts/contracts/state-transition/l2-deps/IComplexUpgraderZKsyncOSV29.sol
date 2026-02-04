// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The interface for the complex upgrader that was used for zksync os chains before v0.30.0
interface IComplexUpgraderZKsyncOSV29 {
    /// @notice Information about the force deployment.
    /// @dev This struct is used to store the information about the force deployment.
    /// @dev For ZKsyncOS, the `deployedBytecodeInfo` is the abi-encoded tuple of `(bytes32, uint32, bytes32)`,
    /// for Era, it is the abi-encoded `bytes32`.
    /// @dev Note, that ZKsyncOS does not support constructors, so the `deployedBytecodeInfo` should only describe the
    /// deployed bytecode.
    /// @param isZKsyncOS whether the deployment is for ZKsyncOS or Era.
    /// @param deployedBytecodeInfo the bytecode information for deployment.
    /// @param newAddress the address where the contract should be deployed.
    // solhint-disable-next-line gas-struct-packing
    struct UniversalForceDeploymentInfo {
        bool isZKsyncOS;
        bytes deployedBytecodeInfo;
        address newAddress;
    }

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev Compatible with Era only.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev Similar to `forceDeployAndUpgrade`, but allows for universal force deployments, that
    /// work for both ZKsyncOS and Era.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgradeUniversal(
        UniversalForceDeploymentInfo[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
