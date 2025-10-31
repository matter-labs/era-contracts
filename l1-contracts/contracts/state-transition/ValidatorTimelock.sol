// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "./AccessControlEnumerablePerChainAddressUpgradeable.sol";
import {LibMap} from "./libraries/LibMap.sol";
import {IZKChain} from "./chain-interfaces/IZKChain.sol";
import {NotAZKChain, TimeNotReached} from "../common/L1ContractErrors.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IValidatorTimelock} from "./IValidatorTimelock.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Intermediate smart contract between the validator EOA account and the ZK chains state transition diamond smart contract.
/// @dev The primary purpose of this contract is to provide a trustless means of delaying batch execution without
/// modifying the main zkChain diamond contract. As such, even if this contract is compromised, it will not impact the main
/// contract.
/// @dev ZKsync actively monitors the chain activity and reacts to any suspicious activity by freezing the chain.
/// This allows time for investigation and mitigation before resuming normal operations.
/// @dev The contract overloads all of the 5 methods, that are used in state transition. When the batch is committed,
/// the timestamp is stored for it. Later, when the owner calls the batch execution, the contract checks that batch
/// was committed not earlier than X time ago.
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract ValidatorTimelock is
    IValidatorTimelock,
    Ownable2StepUpgradeable,
    AccessControlEnumerablePerChainAddressUpgradeable
{
    using LibMap for LibMap.Uint32Map;

    /// @inheritdoc IValidatorTimelock
    string public constant override getName = "ValidatorTimelock";

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override PRECOMMITTER_ROLE = keccak256("PRECOMMITTER_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override COMMITTER_ROLE = keccak256("COMMITTER_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override REVERTER_ROLE = keccak256("REVERTER_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override PROVER_ROLE = keccak256("PROVER_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override OPTIONAL_PRECOMMITTER_ADMIN_ROLE = keccak256("OPTIONAL_PRECOMMITTER_ADMIN_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override OPTIONAL_COMMITTER_ADMIN_ROLE = keccak256("OPTIONAL_COMMITTER_ADMIN_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override OPTIONAL_REVERTER_ADMIN_ROLE = keccak256("OPTIONAL_REVERTER_ADMIN_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override OPTIONAL_PROVER_ADMIN_ROLE = keccak256("OPTIONAL_PROVER_ADMIN_ROLE");

    /// @inheritdoc IValidatorTimelock
    bytes32 public constant override OPTIONAL_EXECUTOR_ADMIN_ROLE = keccak256("OPTIONAL_EXECUTOR_ADMIN_ROLE");

    /// @inheritdoc IValidatorTimelock
    IL1Bridgehub public immutable override BRIDGE_HUB;

    /// @dev The mapping of ZK chain address => batch number => timestamp when it was committed.
    mapping(address chainAddress => LibMap.Uint32Map batchNumberToTimestampMapping) internal committedBatchTimestamp;

    /// @inheritdoc IValidatorTimelock
    uint32 public override executionDelay;

    constructor(address _bridgehubAddr) {
        BRIDGE_HUB = IL1Bridgehub(_bridgehubAddr);
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @inheritdoc IValidatorTimelock
    function initialize(address _initialOwner, uint32 _initialExecutionDelay) external virtual initializer {
        _validatorTimelockInit(_initialOwner, _initialExecutionDelay);
    }

    function _validatorTimelockInit(address _initialOwner, uint32 _initialExecutionDelay) internal onlyInitializing {
        _transferOwnership(_initialOwner);
        executionDelay = _initialExecutionDelay;
    }

    /// @inheritdoc IValidatorTimelock
    function setExecutionDelay(uint32 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
        emit NewExecutionDelay(_executionDelay);
    }

    /// @inheritdoc IValidatorTimelock
    function getCommittedBatchTimestamp(address _chainAddress, uint256 _l2BatchNumber) external view returns (uint256) {
        return committedBatchTimestamp[_chainAddress].get(_l2BatchNumber);
    }

    /// @inheritdoc IValidatorTimelock
    function removeValidatorRoles(
        address _chainAddress,
        address _validator,
        ValidatorRotationParams memory params
    ) public {
        if (params.rotatePrecommitterRole) {
            revokeRole(_chainAddress, PRECOMMITTER_ROLE, _validator);
        }
        if (params.rotateCommitterRole) {
            revokeRole(_chainAddress, COMMITTER_ROLE, _validator);
        }
        if (params.rotateReverterRole) {
            revokeRole(_chainAddress, REVERTER_ROLE, _validator);
        }
        if (params.rotateProverRole) {
            revokeRole(_chainAddress, PROVER_ROLE, _validator);
        }
        if (params.rotateExecutorRole) {
            revokeRole(_chainAddress, EXECUTOR_ROLE, _validator);
        }
    }

    /// @inheritdoc IValidatorTimelock
    function removeValidator(address _chainAddress, address _validator) public {
        removeValidatorRoles(
            _chainAddress,
            _validator,
            ValidatorRotationParams({
                rotatePrecommitterRole: true,
                rotateCommitterRole: true,
                rotateReverterRole: true,
                rotateProverRole: true,
                rotateExecutorRole: true
            })
        );
    }

    /// @inheritdoc IValidatorTimelock
    function removeValidatorForChainId(uint256 _chainId, address _validator) external {
        removeValidator(BRIDGE_HUB.getZKChain(_chainId), _validator);
    }

    /// @inheritdoc IValidatorTimelock
    function addValidatorRoles(
        address _chainAddress,
        address _validator,
        ValidatorRotationParams memory params
    ) public {
        if (params.rotatePrecommitterRole) {
            grantRole(_chainAddress, PRECOMMITTER_ROLE, _validator);
        }
        if (params.rotateCommitterRole) {
            grantRole(_chainAddress, COMMITTER_ROLE, _validator);
        }
        if (params.rotateReverterRole) {
            grantRole(_chainAddress, REVERTER_ROLE, _validator);
        }
        if (params.rotateProverRole) {
            grantRole(_chainAddress, PROVER_ROLE, _validator);
        }
        if (params.rotateExecutorRole) {
            grantRole(_chainAddress, EXECUTOR_ROLE, _validator);
        }
    }

    /// @inheritdoc IValidatorTimelock
    function addValidator(address _chainAddress, address _validator) public {
        addValidatorRoles(
            _chainAddress,
            _validator,
            ValidatorRotationParams({
                rotatePrecommitterRole: true,
                rotateCommitterRole: true,
                rotateReverterRole: true,
                rotateProverRole: true,
                rotateExecutorRole: true
            })
        );
    }

    /// @inheritdoc IValidatorTimelock
    function addValidatorForChainId(uint256 _chainId, address _validator) external {
        addValidator(BRIDGE_HUB.getZKChain(_chainId), _validator);
    }

    /// @inheritdoc IValidatorTimelock
    function hasRoleForChainId(uint256 _chainId, bytes32 _role, address _address) public view returns (bool) {
        return hasRole(BRIDGE_HUB.getZKChain(_chainId), _role, _address);
    }

    /// @inheritdoc IValidatorTimelock
    function precommitSharedBridge(
        address _chainAddress,
        uint256, // _l2BlockNumber (unused in this specific implementation)
        bytes calldata // _l2Block (unused in this specific implementation)
    ) public onlyRole(_chainAddress, PRECOMMITTER_ROLE) {
        _propagateToZKChain(_chainAddress);
    }

    /// @inheritdoc IValidatorTimelock
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata // _batchData (unused in this specific implementation)
    ) public virtual onlyRole(_chainAddress, COMMITTER_ROLE) {
        _recordBatchCommitment(_chainAddress, _processBatchFrom, _processBatchTo);
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Records the timestamp of batch commitment for the given chain address.
    /// To be used from `commitBatchesSharedBridge`
    function _recordBatchCommitment(address _chainAddress, uint256 _processBatchFrom, uint256 _processBatchTo) internal {
        unchecked {
            // This contract is only a temporary solution, that hopefully will be disabled until 2106 year, so...
            // It is safe to cast.
            uint32 timestamp = uint32(block.timestamp);
            for (uint256 i = _processBatchFrom; i <= _processBatchTo; ++i) {
                committedBatchTimestamp[_chainAddress].set(i, timestamp);
            }
        }
    }

    /// @inheritdoc IValidatorTimelock
    function revertBatchesSharedBridge(
        address _chainAddress,
        uint256 /*_newLastBatch*/
    ) external onlyRole(_chainAddress, REVERTER_ROLE) {
        _propagateToZKChain(_chainAddress);
    }

    /// @inheritdoc IValidatorTimelock
    function proveBatchesSharedBridge(
        address _chainAddress,
        uint256, // _processBatchFrom (unused in this specific implementation)
        uint256, // _processBatchTo (unused in this specific implementation)
        bytes calldata // _proofData (unused in this specific implementation)
    ) external onlyRole(_chainAddress, PROVER_ROLE) {
        _propagateToZKChain(_chainAddress);
    }

    /// @inheritdoc IValidatorTimelock
    function executeBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata // _batchData (unused in this specific implementation)
    ) external onlyRole(_chainAddress, EXECUTOR_ROLE) {
        uint256 delay = executionDelay; // uint32
        unchecked {
            for (uint256 i = _processBatchFrom; i <= _processBatchTo; ++i) {
                uint256 commitBatchTimestamp = committedBatchTimestamp[_chainAddress].get(i);

                // Note: if the `commitBatchTimestamp` is zero, that means either:
                // * The batch was committed, but not through this contract.
                // * The batch wasn't committed at all, so execution will fail in the ZKsync contract.
                // We allow executing such batches.

                if (block.timestamp < commitBatchTimestamp + delay) {
                    revert TimeNotReached(commitBatchTimestamp + delay, block.timestamp);
                }
            }
        }
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Call the zkChain diamond contract with the same calldata as this contract was called.
    /// Note: it is called the zkChain diamond contract, not delegatecalled!
    function _propagateToZKChain(address _chainAddress) internal {
        assembly {
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(0, 0, calldatasize())
            // Call method of the ZK chain diamond contract returns 0 on error
            let result := call(gas(), _chainAddress, 0, 0, calldatasize(), 0, 0)
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

    /// @inheritdoc AccessControlEnumerablePerChainAddressUpgradeable
    function _getChainAdmin(address _chainAddress) internal view override returns (address) {
        // This function is expected to be rarely used and so additional checks could be added here.
        // Since all ZK-chain related roles require that the owner of the `DEFAULT_ADMIN_ROLE` sets them,
        // ensuring that this role is only available to chains that are part of the ecosystem is enough
        // to ensure that this contract only works with such chains.

        // Firstly, we check that the chain is indeed a part of the ecosystem
        uint256 chainId = IZKChain(_chainAddress).getChainId();
        if (IL1Bridgehub(BRIDGE_HUB).getZKChain(chainId) != _chainAddress) {
            revert NotAZKChain(_chainAddress);
        }

        // Now, we can extract the admin
        return IZKChain(_chainAddress).getAdmin();
    }
}
