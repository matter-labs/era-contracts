// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./libraries/LibMap.sol";
import "./interfaces/IExecutor.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Intermediate smart contract between the validator EOA account and the zkSync smart contract.
/// @dev The primary purpose of this contract is to provide a trustless means of delaying batch execution without
/// modifying the main zkSync contract. As such, even if this contract is compromised, it will not impact the main
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

    /// @notice The validator address is changed.
    event NewValidator(address _oldValidator, address _newValidator);

    /// @dev The main zkSync smart contract.
    address public immutable zkSyncContract;

    /// @dev The mapping of L2 batch number => timestamp when it was committed.
    LibMap.Uint32Map internal committedBatchTimestamp;

    /// @dev The address that can commit/revert/validate/execute batches.
    address public validator;

    /// @dev The delay between committing and executing batches.
    uint32 public executionDelay;

    constructor(address _initialOwner, address _zkSyncContract, uint32 _executionDelay, address _validator) {
        _transferOwnership(_initialOwner);
        zkSyncContract = _zkSyncContract;
        executionDelay = _executionDelay;
        validator = _validator;
    }

    /// @dev Set new validator address.
    function setValidator(address _newValidator) external onlyOwner {
        address oldValidator = validator;
        validator = _newValidator;
        emit NewValidator(oldValidator, _newValidator);
    }

    /// @dev Set the delay between committing and executing batches.
    function setExecutionDelay(uint32 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
        emit NewExecutionDelay(_executionDelay);
    }

    /// @notice Checks if the caller is a validator.
    modifier onlyValidator() {
        require(msg.sender == validator, "8h");
        _;
    }

    /// @dev Returns the timestamp when `_l2BatchNumber` was committed.
    function getCommittedBatchTimestamp(uint256 _l2BatchNumber) external view returns (uint256) {
        return committedBatchTimestamp.get(_l2BatchNumber);
    }

    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the zkSync contract with the same calldata.
    function commitBatches(
        StoredBatchInfo calldata,
        CommitBatchInfo[] calldata _newBatchesData
    ) external onlyValidator {
        unchecked {
            // This contract is only a temporary solution, that hopefully will be disabled until 2106 year, so...
            // It is safe to cast.
            uint32 timestamp = uint32(block.timestamp);
            for (uint256 i = 0; i < _newBatchesData.length; ++i) {
                committedBatchTimestamp.set(_newBatchesData[i].batchNumber, timestamp);
            }
        }

        _propagateToZkSync();
    }

    /// @dev Make a call to the zkSync contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatches(uint256) external onlyValidator {
        _propagateToZkSync();
    }

    /// @dev Make a call to the zkSync contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatches(
        StoredBatchInfo calldata,
        StoredBatchInfo[] calldata,
        ProofInput calldata
    ) external onlyValidator {
        _propagateToZkSync();
    }

    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the zkSync contract with the same calldata.
    function executeBatches(StoredBatchInfo[] calldata _newBatchesData) external onlyValidator {
        uint256 delay = executionDelay; // uint32
        unchecked {
            for (uint256 i = 0; i < _newBatchesData.length; ++i) {
                uint256 commitBatchTimestamp = committedBatchTimestamp.get(_newBatchesData[i].batchNumber);

                // Note: if the `commitBatchTimestamp` is zero, that means either:
                // * The batch was committed, but not through this contract.
                // * The batch wasn't committed at all, so execution will fail in the zkSync contract.
                // We allow executing such batches.
                require(block.timestamp >= commitBatchTimestamp + delay, "5c"); // The delay is not passed
            }
        }

        _propagateToZkSync();
    }

    /// @dev Call the zkSync contract with the same calldata as this contract was called.
    /// Note: it is called the zkSync contract, not delegatecalled!
    function _propagateToZkSync() internal {
        address contractAddress = zkSyncContract;
        assembly {
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(0, 0, calldatasize())
            // Call method of the zkSync contract returns 0 on error
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
