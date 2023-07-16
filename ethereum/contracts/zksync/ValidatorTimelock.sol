// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IExecutor.sol";

/// @author Matter Labs
/// @notice Intermediate smart contract between the validator EOA account and the zkSync smart contract.
/// @dev The primary purpose of this contract is to provide a trustless means of delaying block execution without
/// modifying the main zkSync contract. As such, even if this contract is compromised, it will not impact the main contract.
/// @dev zkSync actively monitors the chain activity and reacts to any suspicious activity by freezing the chain.
/// This allows time for investigation and mitigation before resuming normal operations.
/// @dev The contract overloads all of the 4 methods, that are used in state transition. When the block is committed, the
/// timestamp is stored for it. Later, when the owner calls the block execution, the contract checks that block
/// was committed not earlier than X time ago.
contract ValidatorTimelock is IExecutor, Ownable2Step {
    /// @dev Part of the IBase interface. Not used in this contract.
    string public constant override getName = "ValidatorTimelock";

    /// @notice The delay between committing and executing blocks is changed.
    event NewExecutionDelay(uint256 _newExecutionDelay);

    /// @notice The validator address is changed.
    event NewValidator(address _oldValidator, address _newValidator);

    /// @dev The main zkSync smart contract.
    address public immutable zkSyncContract;

    /// @dev The mapping of L2 block number => timestamp when it was commited.
    mapping(uint256 => uint256) public committedBlockTimestamp;

    /// @dev The address that can commit/revert/validate/execute blocks.
    address public validator;

    /// @dev The delay between committing and executing blocks.
    uint256 public executionDelay;

    constructor(
        address _initialOwner,
        address _zkSyncContract,
        uint256 _executionDelay,
        address _validator
    ) {
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

    /// @dev Set the delay between committing and executing blocks.
    function setExecutionDelay(uint256 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
        emit NewExecutionDelay(_executionDelay);
    }

    /// @notice Checks if the caller is a validator.
    modifier onlyValidator() {
        require(msg.sender == validator, "8h");
        _;
    }

    /// @dev Records the timestamp for all provided committed blocks and make
    /// a call to the zkSync contract with the same calldata.
    function commitBlocks(StoredBlockInfo calldata, CommitBlockInfo[] calldata _newBlocksData) external onlyValidator {
        for (uint256 i = 0; i < _newBlocksData.length; ++i) {
            committedBlockTimestamp[_newBlocksData[i].blockNumber] = block.timestamp;
        }

        _propagateToZkSync();
    }

    /// @dev Make a call to the zkSync contract with the same calldata.
    /// Note: If the block is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed blocks.
    function revertBlocks(uint256) external onlyValidator {
        _propagateToZkSync();
    }

    /// @dev Make a call to the zkSync contract with the same calldata.
    /// Note: We don't track the time when blocks are proven, since all information about
    /// the block is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBlocks(
        StoredBlockInfo calldata,
        StoredBlockInfo[] calldata,
        ProofInput calldata
    ) external onlyValidator {
        _propagateToZkSync();
    }

    /// @dev Check that blocks were committed at least X time ago and
    /// make a call to the zkSync contract with the same calldata.
    function executeBlocks(StoredBlockInfo[] calldata _newBlocksData) external onlyValidator {
        for (uint256 i = 0; i < _newBlocksData.length; ++i) {
            uint256 commitBlockTimestamp = committedBlockTimestamp[_newBlocksData[i].blockNumber];

            // Note: if the `commitBlockTimestamp` is zero, that means either:
            // * The block was committed, but not though this contract.
            // * The block wasn't committed at all, so execution will fail in the zkSync contract.
            // We allow executing such blocks.

            require(block.timestamp > commitBlockTimestamp + executionDelay, "5c"); // The delay is not passed
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
