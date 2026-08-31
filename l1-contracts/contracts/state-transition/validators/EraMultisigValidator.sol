// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {AddressHasNoCode} from "../../common/L1ContractErrors.sol";
import {
    AlreadySigned,
    ExecutionDelayNotConfigurable,
    InitializeNotAvailable,
    MemberAlreadyExists,
    MemberDoesNotExist,
    NotEnoughSignatures,
    NotSigner
} from "../L1StateTransitionErrors.sol";
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
/// @dev This contract itself does NOT enforce the timelock in any way, it just forwards the calls to the underlying
/// `ValidatorTimelock` after checking for multisig approvals. Since the server reads the execution delay off whichever
/// validator it talks to, all the execution delay getters are overridden to read through to the downstream
/// `ValidatorTimelock`, which is the contract that actually enforces the delay. The matching setters are disabled
/// here for the same reason: the delay must be configured on the contract that enforces it, otherwise a caller
/// would get a successful transaction that changes nothing.
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
        // Initialize the required EIP-712 domain to generate signatures for batch hashes
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
        for (uint256 i = 0; i < length; ++i) {
            if (executionMultisigMember[approvers[i]]) {
                ++count;
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
        address[] calldata _addressesToAdd,
        address[] calldata _addressesToRemove
    ) external onlyOwner {
        uint256 removeLength = _addressesToRemove.length;
        for (uint256 i = 0; i < removeLength; ++i) {
            address member = _addressesToRemove[i];
            if (!executionMultisigMember[member]) {
                revert MemberDoesNotExist(member);
            }
            executionMultisigMember[member] = false;
            emit MultisigMemberChanged(member, false);
        }
        uint256 addLength = _addressesToAdd.length;
        for (uint256 i = 0; i < addLength; ++i) {
            address member = _addressesToAdd[i];
            if (executionMultisigMember[member]) {
                revert MemberAlreadyExists(member);
            }
            executionMultisigMember[member] = true;
            emit MultisigMemberChanged(member, true);
        }
    }

    /// @inheritdoc IValidatorTimelock
    /// @dev Skips `_recordBatchCommitment` since this contract is upstream of the downstream
    /// `ValidatorTimelock` which records and enforces the timelock itself.
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256,
        uint256,
        bytes calldata
    ) public override(ValidatorTimelock, IValidatorTimelock) onlyRole(_chainAddress, COMMITTER_ROLE) {
        _propagateToAddress(_getPropagationAddress(_chainAddress));
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
        _propagateToAddress(_getPropagationAddress(_chainAddress));
    }

    /// @dev Returns `validatorTimelock` so that all inherited forwarding functions route calls
    /// to the downstream `ValidatorTimelock` rather than directly to the ZK chain.
    function _getPropagationAddress(address) internal view override returns (address) {
        return validatorTimelock;
    }

    /// @inheritdoc IValidatorTimelock
    /// @dev Read through to the downstream `ValidatorTimelock`: it is the contract that enforces the
    /// delay, so its value is the only one that matters. The delay stored in this contract is unused.
    function executionDelay() public view override(ValidatorTimelock, IValidatorTimelock) returns (uint32) {
        return IValidatorTimelock(validatorTimelock).executionDelay();
    }

    /// @inheritdoc IValidatorTimelock
    /// @dev Read through to the downstream `ValidatorTimelock`, see `executionDelay`.
    function chainExecutionDelay(
        address _chainAddress
    ) public view override(ValidatorTimelock, IValidatorTimelock) returns (uint32) {
        return IValidatorTimelock(validatorTimelock).chainExecutionDelay(_chainAddress);
    }

    /// @inheritdoc IValidatorTimelock
    /// @dev Read through to the downstream `ValidatorTimelock`, see `executionDelay`.
    function getExecutionDelay(
        address _chainAddress
    ) public view override(ValidatorTimelock, IValidatorTimelock) returns (uint32) {
        return IValidatorTimelock(validatorTimelock).getExecutionDelay(_chainAddress);
    }

    /// @dev Disable the inherited `setExecutionDelay`. Since the getters read through to the downstream
    /// `ValidatorTimelock`, writing the delay here would silently have no effect on the enforced delay.
    /// The ecosystem-wide delay must be set on the downstream `ValidatorTimelock` instead.
    function setExecutionDelay(uint32) external pure override(ValidatorTimelock, IValidatorTimelock) {
        revert ExecutionDelayNotConfigurable();
    }

    /// @dev Disable the inherited `increaseChainExecutionDelay`, see `setExecutionDelay`.
    /// A chain admin must raise the delay on the downstream `ValidatorTimelock` instead.
    function increaseChainExecutionDelay(
        address,
        uint32
    ) external pure override(ValidatorTimelock, IValidatorTimelock) {
        revert ExecutionDelayNotConfigurable();
    }

    /// @dev Disable the inherited `setChainExecutionDelay`, see `setExecutionDelay`.
    function setChainExecutionDelay(address, uint32) external pure override(ValidatorTimelock, IValidatorTimelock) {
        revert ExecutionDelayNotConfigurable();
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
}
