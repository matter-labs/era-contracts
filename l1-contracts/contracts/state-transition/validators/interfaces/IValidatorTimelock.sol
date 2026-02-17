// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL1Bridgehub} from "../../../core/bridgehub/IL1Bridgehub.sol";
import {IExecutor} from "../../chain-interfaces/IExecutor.sol";
import {ICommitter} from "../../chain-interfaces/ICommitter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IValidatorTimelock is IExecutor, ICommitter {
    /// @notice Struct specifying which validator roles to grant or revoke in a single call.
    /// @param rotatePrecommitterRole Whether to rotate the PRECOMMITTER_ROLE.
    /// @param rotateCommitterRole Whether to rotate the COMMITTER_ROLE.
    /// @param rotateReverterRole Whether to rotate the REVERTER_ROLE.
    /// @param rotateProverRole Whether to rotate the PROVER_ROLE.
    /// @param rotateExecutorRole Whether to rotate the EXECUTOR_ROLE.
    struct ValidatorRotationParams {
        bool rotatePrecommitterRole;
        bool rotateCommitterRole;
        bool rotateReverterRole;
        bool rotateProverRole;
        bool rotateExecutorRole;
    }

    /// @notice The delay between committing and executing batches is changed.
    event NewExecutionDelay(uint256 _newExecutionDelay);

    /// @notice Role hash for addresses allowed to precommit batches on a chain.
    function PRECOMMITTER_ROLE() external view returns (bytes32);
    /// @notice Role hash for addresses allowed to commit batches on a chain.
    function COMMITTER_ROLE() external view returns (bytes32);
    /// @notice Role hash for addresses allowed to revert batches on a chain.
    function REVERTER_ROLE() external view returns (bytes32);
    /// @notice Role hash for addresses allowed to prove batches on a chain.
    function PROVER_ROLE() external view returns (bytes32);
    /// @notice Role hash for addresses allowed to execute batches on a chain.
    function EXECUTOR_ROLE() external view returns (bytes32);
    /// @notice Optional admin role hash for managing PRECOMMITTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    function OPTIONAL_PRECOMMITTER_ADMIN_ROLE() external view returns (bytes32);
    /// @notice Optional admin role hash for managing COMMITTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    function OPTIONAL_COMMITTER_ADMIN_ROLE() external view returns (bytes32);
    /// @notice Optional admin role hash for managing REVERTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    function OPTIONAL_REVERTER_ADMIN_ROLE() external view returns (bytes32);
    /// @notice Optional admin role hash for managing PROVER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    function OPTIONAL_PROVER_ADMIN_ROLE() external view returns (bytes32);
    /// @notice Optional admin role hash for managing EXECUTOR_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    function OPTIONAL_EXECUTOR_ADMIN_ROLE() external view returns (bytes32);

    /// @notice The address of the bridgehub
    function BRIDGE_HUB() external view returns (IL1Bridgehub);
    /// @dev The delay between committing and executing batches.
    function executionDelay() external view returns (uint32);
    /// @dev Part of the IBase interface. Not used in this contract.
    function getName() external pure returns (string memory);

    /// @notice Initializer for the contract.
    /// @dev Expected to be delegatecalled in the constructor of the TransparentUpgradeableProxy
    /// @param _initialOwner The initial owner of the Validator timelock.
    /// @param _initialExecutionDelay The initial execution delay, i.e. minimal time between a batch is committed and executed.
    function initialize(address _initialOwner, uint32 _initialExecutionDelay) external;
    /// @dev Set the delay between committing and executing batches.
    function setExecutionDelay(uint32 _executionDelay) external;
    /// @dev Returns the timestamp when `_l2BatchNumber` was committed.
    function getCommittedBatchTimestamp(address _chainAddress, uint256 _l2BatchNumber) external view returns (uint256);

    /// @notice Revokes the specified validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to revoke.
    /// @dev Note that the access control is managed by the inner `revokeRole` functions.
    function removeValidatorRoles(
        address _chainAddress,
        address _validator,
        ValidatorRotationParams memory params
    ) external;
    /// @notice Convenience wrapper to revoke all validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to remove.
    function removeValidator(address _chainAddress, address _validator) external;
    /// @notice Convenience wrapper to revoke all validator roles for a given validator on the target chain.
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _validator The address of the validator to remove.
    function removeValidatorForChainId(uint256 _chainId, address _validator) external;
    /// @notice Grants the specified validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to grant.
    function addValidatorRoles(
        address _chainAddress,
        address _validator,
        ValidatorRotationParams memory params
    ) external;
    /// @notice Convenience wrapper to grant all validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to add.
    function addValidator(address _chainAddress, address _validator) external;
    /// @notice Convenience wrapper to grant all validator roles for a given validator on the target chain.
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _validator The address of the validator to add.
    function addValidatorForChainId(uint256 _chainId, address _validator) external;
    /// @notice Convenience wrapper to retrieve whether a certain address has a role for a chain.
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _role The bytes32 ID of the role.
    /// @param _address The address that may have the role.
    function hasRoleForChainId(uint256 _chainId, bytes32 _role, address _address) external view returns (bool);

    // Chain interaction functions
    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    function precommitSharedBridge(address _chainAddress, uint256 _l2BlockNumber, bytes calldata _l2Block) external;
    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the zkChain diamond contract with the same calldata.
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) external;
    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatchesSharedBridge(address _chainAddress, uint256 _newLastBatch) external;
    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _proofData
    ) external;
    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the zkChain diamond contract with the same calldata.
    function executeBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) external;
}
