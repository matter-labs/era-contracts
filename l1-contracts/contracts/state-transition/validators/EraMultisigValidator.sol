// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {AddressHasNoCode} from "../../common/L1ContractErrors.sol";
import {ValidatorTimelock} from "./ValidatorTimelock.sol";
import {IValidatorTimelock} from "./interfaces/IValidatorTimelock.sol";
import {IEraMultisigValidator} from "./interfaces/IEraMultisigValidator.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A multisig wrapper around `ValidatorTimelock` that requires a threshold of approvals
/// before batch execution can proceed. Designed for Era chains (not ZKsync OS chains) that want
/// additional security through 2FA: independent nodes verify the execution and sign off on the
/// state transition before it can be finalized on L1.
/// @dev This contract sits between the executor EOA and the `ValidatorTimelock`. Commit and prove
/// calls are forwarded directly, while execute calls require that enough multisig members have
/// pre-approved the exact execution parameters via `approveHash`.
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract EraMultisigValidator is IEraMultisigValidator, ValidatorTimelock, EIP712Upgradeable {
    /// @dev EIP-712 typehash for the ExecuteBatches struct.
    bytes32 internal constant EXECUTE_BATCHES_TYPEHASH =
        keccak256(
            "ExecuteBatches(address chainAddress,uint256 processBatchFrom,uint256 processBatchTo,bytes batchData)"
        );

    /// @inheritdoc IEraMultisigValidator
    address public override validatorTimelock;

    /// @inheritdoc IEraMultisigValidator
    mapping(address => bool) public override executionMultisigMember;

    /// @inheritdoc IEraMultisigValidator
    mapping(address => mapping(bytes32 => bool)) public override individualApprovals;

    /// @dev Addresses that have approved a given hash. Iterated at execution time
    /// to count only current members.
    mapping(bytes32 => address[]) internal hashApprovers;

    /// @inheritdoc IEraMultisigValidator
    uint256 public override threshold;

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[44] private __gap;

    constructor(address _bridgeHub) ValidatorTimelock(_bridgeHub) {
        _disableInitializers();
    }

    /// @dev Disable the inherited 2-param `initialize` from `ValidatorTimelock` / `IValidatorTimelock`.
    function initialize(address, uint32) external pure override(ValidatorTimelock, IValidatorTimelock) {
        revert InitializeNotAvailable();
    }

    /// @inheritdoc IEraMultisigValidator
    function initialize(
        address _initialOwner,
        uint32 _initialExecutionDelay,
        address _validatorTimelock
    ) external initializer {
        _validatorTimelockInit(_initialOwner, _initialExecutionDelay);
        _initializeEraMultisig(_validatorTimelock);
    }

    /// @dev Shared initialization logic for EIP-712 and the validator timelock address.
    function _initializeEraMultisig(address _validatorTimelock) internal {
        __EIP712_init("EraMultisigValidator", "1");
        if (_validatorTimelock.code.length == 0) {
            revert AddressHasNoCode(_validatorTimelock);
        }
        validatorTimelock = _validatorTimelock;
    }

    /// @inheritdoc IEraMultisigValidator
    function approveHash(bytes32 _hash) external {
        if (!executionMultisigMember[msg.sender]) {
            revert NotSigner();
        }
        if (individualApprovals[msg.sender][_hash]) {
            revert AlreadySigned();
        }
        individualApprovals[msg.sender][_hash] = true;
        hashApprovers[_hash].push(msg.sender);
        emit HashApproved(msg.sender, _hash);
    }

    /// @inheritdoc IEraMultisigValidator
    function getApprovals(bytes32 _hash) public view returns (uint256) {
        uint256 count = 0;
        address[] storage approvers = hashApprovers[_hash];
        uint256 length = approvers.length;
        for (uint256 i = 0; i < length; i++) {
            if (executionMultisigMember[approvers[i]]) {
                count += 1;
            }
        }
        return count;
    }

    /// @inheritdoc IEraMultisigValidator
    function changeThreshold(uint256 _newThreshold) external onlyOwner {
        threshold = _newThreshold;
        emit ThresholdChanged(_newThreshold);
    }

    /// @inheritdoc IEraMultisigValidator
    function changeExecutionMultisigMember(
        address[] memory _addressesToAdd,
        address[] memory _addressesToRemove
    ) external onlyOwner {
        for (uint256 i = 0; i < _addressesToAdd.length; i++) {
            executionMultisigMember[_addressesToAdd[i]] = true;
            emit MultisigMemberChanged(_addressesToAdd[i], true);
        }
        for (uint256 i = 0; i < _addressesToRemove.length; i++) {
            executionMultisigMember[_addressesToRemove[i]] = false;
            emit MultisigMemberChanged(_addressesToRemove[i], false);
        }
    }

    /// @inheritdoc IValidatorTimelock
    function precommitSharedBridge(
        address _chainAddress,
        uint256 _l2BlockNumber,
        bytes calldata _l2Block
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, PRECOMMITTER_ROLE) {
        _propagateToValidatorTimelock();
    }

    /// @inheritdoc IValidatorTimelock
    function revertBatchesSharedBridge(
        address _chainAddress,
        uint256 _newLastBatch
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, REVERTER_ROLE) {
        _propagateToValidatorTimelock();
    }

    /// @inheritdoc IValidatorTimelock
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, COMMITTER_ROLE) {
        _propagateToValidatorTimelock();
    }

    /// @inheritdoc IValidatorTimelock
    function proveBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, PROVER_ROLE) {
        _propagateToValidatorTimelock();
    }

    /// @inheritdoc IValidatorTimelock
    /// @dev In addition to the base role check, this override requires that the execution parameters
    /// have been approved by at least `threshold` multisig members before forwarding.
    function executeBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, EXECUTOR_ROLE) {
        bytes32 approvedHash = calculateHash(_chainAddress, _processBatchFrom, _processBatchTo, _batchData);
        if (getApprovals(approvedHash) < threshold) {
            revert NotEnoughSignatures();
        }
        _propagateToValidatorTimelock();
    }

    /// @inheritdoc IEraMultisigValidator
    function calculateHash(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        EXECUTE_BATCHES_TYPEHASH,
                        _chainAddress,
                        _processBatchFrom,
                        _processBatchTo,
                        keccak256(_batchData)
                    )
                )
            );
    }

    /// @dev Forwards the current calldata to the downstream `ValidatorTimelock`.
    function _propagateToValidatorTimelock() internal {
        address validatorTimelock_ = validatorTimelock;
        assembly {
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(0, 0, calldatasize())
            // Call the ValidatorTimelock contract, returns 0 on error
            let result := call(gas(), validatorTimelock_, 0, 0, calldatasize(), 0, 0)
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
