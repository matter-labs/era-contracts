// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValidatorTimelock} from "./IValidatorTimelock.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IEraMultisigValidator is IValidatorTimelock {
    /// @notice Emitted when a multisig member approves a batch execution hash.
    /// @param member The address of the approving member.
    /// @param hash The approved batch execution hash.
    event HashApproved(address indexed member, bytes32 indexed hash);

    /// @notice Emitted when the approval threshold is changed.
    /// @param newThreshold The new threshold value.
    event ThresholdChanged(uint256 newThreshold);

    /// @notice Emitted when a multisig member is added or removed.
    /// @param member The address of the member being modified.
    /// @param isMember Whether the address is now a member.
    event MultisigMemberChanged(address indexed member, bool isMember);

    /// @notice The downstream `ValidatorTimelock` to which calls are forwarded.
    function validatorTimelock() external view returns (address);

    /// @notice Whether an address is a member of the execution multisig.
    function executionMultisigMember(address _member) external view returns (bool);

    /// @notice Whether a specific member has approved a given execution hash.
    function individualApprovals(address _member, bytes32 _hash) external view returns (bool);

    /// @notice Returns the number of approvals for a given hash from addresses that are
    /// currently multisig members. Approvals from removed members are not counted.
    /// @param _hash The execution hash to query.
    function getApprovals(bytes32 _hash) external view returns (uint256);

    /// @notice The number of approvals required before `executeBatchesSharedBridge` can proceed.
    function threshold() external view returns (uint256);

    /// @notice Initializer for a fresh proxy deployment.
    /// @param _initialOwner The initial owner of this contract.
    /// @param _initialExecutionDelay The initial execution delay for the timelock.
    /// @param _validatorTimelock The address of the downstream `ValidatorTimelock` (must be a deployed contract).
    function initialize(address _initialOwner, uint32 _initialExecutionDelay, address _validatorTimelock) external;

    /// @notice Registers the caller's approval for a given execution hash.
    /// @dev Reverts if the caller is not a multisig member or has already approved this hash.
    /// @param _hash The execution hash to approve (computed via `calculateHash`).
    function approveHash(bytes32 _hash) external;

    /// @notice Updates the number of approvals required for execution.
    /// @param _newThreshold The new approval threshold.
    function changeThreshold(uint256 _newThreshold) external;

    /// @notice Adds and/or removes members of the execution multisig.
    /// @param _addressesToAdd Addresses to grant multisig membership.
    /// @param _addressesToRemove Addresses to revoke multisig membership.
    function changeExecutionMultisigMember(
        address[] calldata _addressesToAdd,
        address[] calldata _addressesToRemove
    ) external;

    /// @notice Computes the EIP-712 digest used for multisig approval of a batch execution.
    /// @param _chainAddress The address of the ZK chain.
    /// @param _processBatchFrom The first batch number in the range.
    /// @param _processBatchTo The last batch number in the range.
    /// @param _batchData The batch execution data.
    /// @return The EIP-712 typed data hash of the execution parameters.
    function calculateHash(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) external view returns (bytes32);
}
