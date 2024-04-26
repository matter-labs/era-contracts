// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {LibMap} from "./libraries/LibMap.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IStateTransitionManager} from "./IStateTransitionManager.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Intermediate smart contract between the validator EOA account and the hyperchains state transition diamond smart contract.
/// @dev The primary purpose of this contract is to provide a trustless means of delaying batch execution without
/// modifying the main hyperchain diamond contract. As such, even if this contract is compromised, it will not impact the main
/// contract.
/// @dev zkSync actively monitors the chain activity and reacts to any suspicious activity by freezing the chain.
/// This allows time for investigation and mitigation before resuming normal operations.
/// @dev The contract overloads all of the 4 methods, that are used in state transition. When the batch is committed,
/// the timestamp is stored for it. Later, when the owner calls the batch execution, the contract checks that batch
/// was committed not earlier than X time ago.
contract ValidatorTimelock is IExecutor, Ownable2Step {
    using LibMap for LibMap.Uint32Map;

    /// @dev Part of the IBase interface. Not used in this contract.
    string public constant override getName = "ValidatorTimelock";

    /// @notice The delay between committing and executing batches is changed.
    event NewExecutionDelay(uint256 _newExecutionDelay);

    /// @notice A new validator has been added.
    event ValidatorAdded(uint256 indexed _chainId, address _addedValidator);

    /// @notice A validator has been removed.
    event ValidatorRemoved(uint256 indexed _chainId, address _removedValidator);

    /// @notice Error for when an address is already a validator.
    error AddressAlreadyValidator(uint256 _chainId);

    /// @notice Error for when an address is not a validator.
    error ValidatorDoesNotExist(uint256 _chainId);

    /// @dev The stateTransitionManager smart contract.
    IStateTransitionManager public stateTransitionManager;

    /// @dev The mapping of L2 chainId => batch number => timestamp when it was committed.
    mapping(uint256 chainId => LibMap.Uint32Map batchNumberToTimestampMapping) internal committedBatchTimestamp;

    /// @dev The address that can commit/revert/validate/execute batches.
    mapping(uint256 _chainId => mapping(address _validator => bool)) public validators;

    /// @dev The delay between committing and executing batches.
    uint32 public executionDelay;

    /// @dev Era's chainID
    uint256 immutable ERA_CHAIN_ID;

    constructor(address _initialOwner, uint32 _executionDelay, uint256 _eraChainId) {
        _transferOwnership(_initialOwner);
        executionDelay = _executionDelay;
        ERA_CHAIN_ID = _eraChainId;
    }

    /// @notice Checks if the caller is the admin of the chain.
    modifier onlyChainAdmin(uint256 _chainId) {
        require(msg.sender == stateTransitionManager.getChainAdmin(_chainId), "ValidatorTimelock: only chain admin");
        _;
    }

    /// @notice Checks if the caller is a validator.
    modifier onlyValidator(uint256 _chainId) {
        require(validators[_chainId][msg.sender], "ValidatorTimelock: only validator");
        _;
    }

    /// @dev Sets a new state transition manager.
    function setStateTransitionManager(IStateTransitionManager _stateTransitionManager) external onlyOwner {
        stateTransitionManager = _stateTransitionManager;
    }

    /// @dev Sets an address as a validator.
    function addValidator(uint256 _chainId, address _newValidator) external onlyChainAdmin(_chainId) {
        if (validators[_chainId][_newValidator]) {
            revert AddressAlreadyValidator(_chainId);
        }
        validators[_chainId][_newValidator] = true;
        emit ValidatorAdded(_chainId, _newValidator);
    }

    /// @dev Removes an address as a validator.
    function removeValidator(uint256 _chainId, address _validator) external onlyChainAdmin(_chainId) {
        if (!validators[_chainId][_validator]) {
            revert ValidatorDoesNotExist(_chainId);
        }
        validators[_chainId][_validator] = false;
        emit ValidatorRemoved(_chainId, _validator);
    }

    /// @dev Set the delay between committing and executing batches.
    function setExecutionDelay(uint32 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
        emit NewExecutionDelay(_executionDelay);
    }

    /// @dev Returns the timestamp when `_l2BatchNumber` was committed.
    function getCommittedBatchTimestamp(uint256 _chainId, uint256 _l2BatchNumber) external view returns (uint256) {
        return committedBatchTimestamp[_chainId].get(_l2BatchNumber);
    }

    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the hyperchain diamond contract with the same calldata.
    function commitBatches(
        StoredBatchInfo calldata,
        CommitBatchInfo[] calldata _newBatchesData
    ) external onlyValidator(ERA_CHAIN_ID) {
        _commitBatchesInner(ERA_CHAIN_ID, _newBatchesData);
    }

    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the hyperchain diamond contract with the same calldata.
    function commitBatchesSharedBridge(
        uint256 _chainId,
        StoredBatchInfo calldata,
        CommitBatchInfo[] calldata _newBatchesData
    ) external onlyValidator(_chainId) {
        _commitBatchesInner(_chainId, _newBatchesData);
    }

    function _commitBatchesInner(uint256 _chainId, CommitBatchInfo[] calldata _newBatchesData) internal {
        unchecked {
            // This contract is only a temporary solution, that hopefully will be disabled until 2106 year, so...
            // It is safe to cast.
            uint32 timestamp = uint32(block.timestamp);
            for (uint256 i = 0; i < _newBatchesData.length; ++i) {
                committedBatchTimestamp[_chainId].set(_newBatchesData[i].batchNumber, timestamp);
            }
        }

        _propagateToZkSyncHyperchain(_chainId);
    }

    /// @dev Make a call to the hyperchain diamond contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatches(uint256) external onlyValidator(ERA_CHAIN_ID) {
        _propagateToZkSyncHyperchain(ERA_CHAIN_ID);
    }

    /// @dev Make a call to the hyperchain diamond contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatchesSharedBridge(uint256 _chainId, uint256) external onlyValidator(_chainId) {
        _propagateToZkSyncHyperchain(_chainId);
    }

    /// @dev Make a call to the hyperchain diamond contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatches(
        StoredBatchInfo calldata,
        StoredBatchInfo[] calldata,
        ProofInput calldata
    ) external onlyValidator(ERA_CHAIN_ID) {
        _propagateToZkSyncHyperchain(ERA_CHAIN_ID);
    }

    /// @dev Make a call to the hyperchain diamond contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatchesSharedBridge(
        uint256 _chainId,
        StoredBatchInfo calldata,
        StoredBatchInfo[] calldata,
        ProofInput calldata
    ) external onlyValidator(_chainId) {
        _propagateToZkSyncHyperchain(_chainId);
    }

    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the hyperchain diamond contract with the same calldata.
    function executeBatches(StoredBatchInfo[] calldata _newBatchesData) external onlyValidator(ERA_CHAIN_ID) {
        _executeBatchesInner(ERA_CHAIN_ID, _newBatchesData);
    }

    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the hyperchain diamond contract with the same calldata.
    function executeBatchesSharedBridge(
        uint256 _chainId,
        StoredBatchInfo[] calldata _newBatchesData
    ) external onlyValidator(_chainId) {
        _executeBatchesInner(_chainId, _newBatchesData);
    }

    function _executeBatchesInner(uint256 _chainId, StoredBatchInfo[] calldata _newBatchesData) internal {
        uint256 delay = executionDelay; // uint32
        unchecked {
            for (uint256 i = 0; i < _newBatchesData.length; ++i) {
                uint256 commitBatchTimestamp = committedBatchTimestamp[_chainId].get(_newBatchesData[i].batchNumber);

                // Note: if the `commitBatchTimestamp` is zero, that means either:
                // * The batch was committed, but not through this contract.
                // * The batch wasn't committed at all, so execution will fail in the zkSync contract.
                // We allow executing such batches.

                require(block.timestamp >= commitBatchTimestamp + delay, "5c"); // The delay is not passed
            }
        }
        _propagateToZkSyncHyperchain(_chainId);
    }

    /// @dev Call the hyperchain diamond contract with the same calldata as this contract was called.
    /// Note: it is called the hyperchain diamond contract, not delegatecalled!
    function _propagateToZkSyncHyperchain(uint256 _chainId) internal {
        address contractAddress = stateTransitionManager.getHyperchain(_chainId);
        assembly {
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(0, 0, calldatasize())
            // Call method of the hyperchain diamond contract returns 0 on error
            let result := call(gas(), contractAddress, 0, 0, calldatasize(), 0, 0)
            // Get the size of the last return data
            let size := returndatasize()
            // Copy the size length of bytes from return data at zero position to pointer position
            returndatacopy(0, 0, size)
            // Depending on the result value
            switch result
            case 0 {
                // End execution and revert state changes
                revert(0, size)
            }
            default {
                // Return data with length of size at pointers position
                return(0, size)
            }
        }
    }
}
