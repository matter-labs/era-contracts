// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {AccessControlEnumerablePerChainUpgradeable} from "./AccessControlEnumerablePerChainUpgradeable.sol";
import {LibMap} from "./libraries/LibMap.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IChainTypeManager} from "./IChainTypeManager.sol";
import {Unauthorized, TimeNotReached, ZeroAddress} from "../common/L1ContractErrors.sol";

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
contract ValidatorTimelock is IExecutor, Ownable2StepUpgradeable, AccessControlEnumerablePerChainUpgradeable {
    using LibMap for LibMap.Uint32Map;

    /// @dev Part of the IBase interface. Not used in this contract.
    string public constant override getName = "ValidatorTimelock";

    /// @notice Role hash for addresses allowed to precommit batches on a chain.
    bytes32 public constant PRECOMMITTER_ROLE = keccak256("PRECOMMITTER_ROLE");

    /// @notice Role hash for addresses allowed to commit batches on a chain.
    bytes32 public constant COMMITTER_ROLE = keccak256("COMMITTER_ROLE");

    /// @notice Role hash for addresses allowed to revert batches on a chain.
    bytes32 public constant REVERTER_ROLE = keccak256("REVERTER_ROLE");

    /// @notice Role hash for addresses allowed to prove batches on a chain.
    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    /// @notice Role hash for addresses allowed to execute batches on a chain.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Optional admin role hash for managing PRECOMMITTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_PRECOMMITTER_ADMIN_ROLE = keccak256("OPTIONAL_PRECOMMITTER_ADMIN_ROLE");

    /// @notice Optional admin role hash for managing COMMITTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_COMMITTER_ADMIN_ROLE = keccak256("OPTIONAL_COMMITTER_MANAGER_ROLE");

    /// @notice Optional admin role hash for managing REVERTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_REVERTER_ADMIN_ROLE = keccak256("OPTIONAL_REVERTER_MANAGER_ROLE");

    /// @notice Optional admin role hash for managing PROVER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_PROVER_ADMIN_ROLE = keccak256("OPTIONAL_PROVER_MANAGER_ROLE");

    /// @notice Optional admin role hash for managing EXECUTOR_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_EXECUTOR_ADMIN_ROLE = keccak256("OPTIONAL_EXECUTOR_MANAGER_ROLE");

    /// @notice The delay between committing and executing batches is changed.
    event NewExecutionDelay(uint256 _newExecutionDelay);

    /// @dev The chainTypeManager smart contract.
    IChainTypeManager public chainTypeManager;

    /// @dev The mapping of L2 chainId => batch number => timestamp when it was committed.
    mapping(uint256 chainId => LibMap.Uint32Map batchNumberToTimestampMapping) internal committedBatchTimestamp;

    /// @dev The delay between committing and executing batches.
    uint32 public executionDelay;

    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializer for the contract.
    /// @dev Expected to be delegatecalled in the constructor of the TransparentUpgradeableProxy
    /// @param _initialOwner The initial owner of the Validator timelock.
    /// @param _executionDelay The initial execution delay, i.e. minimal time between a batch is comitted and executed.
    function initialize(address _initialOwner, uint32 _executionDelay) external initializer {
        _transferOwnership(_initialOwner);
        executionDelay = _executionDelay;
    }

    /// @notice Checks if the caller is the admin of the chain.
    modifier onlyChainAdmin(uint256 _chainId) {
        if (msg.sender != chainTypeManager.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Sets a new state transition manager.
    function setChainTypeManager(IChainTypeManager _chainTypeManager) external onlyOwner {
        if (address(_chainTypeManager) == address(0)) {
            revert ZeroAddress();
        }
        chainTypeManager = _chainTypeManager;
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

    /// @notice Revokes the specified validator roles for a given validator on the target chain.
    /// @param _chainId The identifier of the L2 chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to revoke.
    /// @dev Note that the access control is managed by the inner `revokeRole` functions.
    function removeValidatorRoles(
        uint256 _chainId,
        address _validator,
        ValidatorRotationParams memory params
    ) public        {
        if (params.rotatePrecommitterRole) {
            revokeRole(_chainId, PRECOMMITTER_ROLE, _validator);
        }
        if (params.rotateCommitterRole) {
            revokeRole(_chainId, COMMITTER_ROLE, _validator);
        }
        if (params.rotateReverterRole) {
            revokeRole(_chainId, REVERTER_ROLE, _validator);
        }
        if (params.rotateProverRole) {
            revokeRole(_chainId, PROVER_ROLE, _validator);
        }
        if (params.rotateExecutorRole) {
            revokeRole(_chainId, EXECUTOR_ROLE, _validator);
        }
    }

    /// @notice Convenience wrapper to revoke all validator roles for a given validator on the target chain.
    /// @param _chainId The identifier of the L2 chain.
    /// @param _validator The address of the validator to remove.
    function removeValidator(
        uint256 _chainId,
        address _validator
    ) external {
        removeValidatorRoles(
            _chainId,
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

    /// @notice Grants the specified validator roles for a given validator on the target chain.
    /// @param _chainId The identifier of the L2 chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to grant.
    function addValidatorRoles(
        uint256 _chainId,
        address _validator,
        ValidatorRotationParams memory params
    ) public {
        if (params.rotatePrecommitterRole) {
            grantRole(_chainId, PRECOMMITTER_ROLE, _validator);
        }
        if (params.rotateCommitterRole) {
            grantRole(_chainId, COMMITTER_ROLE, _validator);
        }
        if (params.rotateReverterRole) {
            grantRole(_chainId, REVERTER_ROLE, _validator);
        }
        if (params.rotateProverRole) {
            grantRole(_chainId, PROVER_ROLE, _validator);
        }
        if (params.rotateExecutorRole) {
            grantRole(_chainId, EXECUTOR_ROLE, _validator);
        }
    }

    /// @notice Convenience wrapper to grant all validator roles for a given validator on the target chain.
    /// @param _chainId The identifier of the L2 chain.
    /// @param _validator The address of the validator to add.
    function addValidator(
        uint256 _chainId,
        address _validator
    ) external {        
        addValidatorRoles(
            _chainId,
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


    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    function precommitSharedBridge(
        uint256 _chainId,
        uint256,
        bytes calldata
    ) external onlyRole(_chainId, PRECOMMITTER_ROLE) {
        _propagateToZKChain(_chainId);
    }

    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the zkChain diamond contract with the same calldata.
    function commitBatchesSharedBridge(
        uint256 _chainId,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata
    ) external onlyRole(_chainId, COMMITTER_ROLE) {
        unchecked {
            // This contract is only a temporary solution, that hopefully will be disabled until 2106 year, so...
            // It is safe to cast.
            uint32 timestamp = uint32(block.timestamp);
            // We disable this check because calldata array length is cheap.
            for (uint256 i = _processBatchFrom; i <= _processBatchTo; ++i) {
                committedBatchTimestamp[_chainId].set(i, timestamp);
            }
        }
        _propagateToZKChain(_chainId);
    }

    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatchesSharedBridge(uint256 _chainId, uint256) external onlyRole(_chainId, REVERTER_ROLE) {
        _propagateToZKChain(_chainId);
    }

    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatchesSharedBridge(
        uint256 _chainId,
        uint256, // _processBatchFrom
        uint256, // _processBatchTo
        bytes calldata
    ) external onlyRole(_chainId, PROVER_ROLE) {
        _propagateToZKChain(_chainId);
    }

    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the zkChain diamond contract with the same calldata.
    function executeBatchesSharedBridge(
        uint256 _chainId,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata
    ) external onlyRole(_chainId, EXECUTOR_ROLE) {
        uint256 delay = executionDelay; // uint32
        unchecked {
            // We disable this check because calldata array length is cheap.
            for (uint256 i = _processBatchFrom; i <= _processBatchTo; ++i) {
                uint256 commitBatchTimestamp = committedBatchTimestamp[_chainId].get(i);

                // Note: if the `commitBatchTimestamp` is zero, that means either:
                // * The batch was committed, but not through this contract.
                // * The batch wasn't committed at all, so execution will fail in the ZKsync contract.
                // We allow executing such batches.

                if (block.timestamp < commitBatchTimestamp + delay) {
                    revert TimeNotReached(commitBatchTimestamp + delay, block.timestamp);
                }
            }
        }
        _propagateToZKChain(_chainId);
    }

    /// @dev Call the zkChain diamond contract with the same calldata as this contract was called.
    /// Note: it is called the zkChain diamond contract, not delegatecalled!
    function _propagateToZKChain(uint256 _chainId) internal {
        // Note, that it is important to use chain type manager and
        // the legacy method here for obtaining the chain id in order for
        // this contract to before the CTM upgrade is finalized.
        address contractAddress = chainTypeManager.getHyperchain(_chainId);
        if (contractAddress == address(0)) {
            revert ZeroAddress();
        }
        assembly {
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(0, 0, calldatasize())
            // Call method of the ZK chain diamond contract returns 0 on error
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

    /// @inheritdoc AccessControlEnumerablePerChainUpgradeable
    function _getChainAdmin(uint256 _chainId) internal view override returns (address) {
        return chainTypeManager.getChainAdmin(_chainId);
    }
}
