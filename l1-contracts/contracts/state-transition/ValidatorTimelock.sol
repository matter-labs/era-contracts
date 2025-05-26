// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "./AccessControlEnumerablePerChainAddressUpgradeable.sol";
import {LibMap} from "./libraries/LibMap.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IZKChain} from "./chain-interfaces/IZKChain.sol";
import {TimeNotReached, NotAZKChain} from "../common/L1ContractErrors.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

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
contract ValidatorTimelock is IExecutor, Ownable2StepUpgradeable, AccessControlEnumerablePerChainAddressUpgradeable {
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
    bytes32 public constant OPTIONAL_COMMITTER_ADMIN_ROLE = keccak256("OPTIONAL_COMMITTER_ADMIN_ROLE");

    /// @notice Optional admin role hash for managing REVERTER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_REVERTER_ADMIN_ROLE = keccak256("OPTIONAL_REVERTER_ADMIN_ROLE");

    /// @notice Optional admin role hash for managing PROVER_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_PROVER_ADMIN_ROLE = keccak256("OPTIONAL_PROVER_ADMIN_ROLE");

    /// @notice Optional admin role hash for managing EXECUTOR_ROLE assignments.
    /// @dev Note, that it is optional, meaning that by default the admin role is held by the chain admin
    bytes32 public constant OPTIONAL_EXECUTOR_ADMIN_ROLE = keccak256("OPTIONAL_EXECUTOR_ADMIN_ROLE");

    /// @notice The address of the bridgehub
    IBridgehub public immutable BRIDGE_HUB;

    /// @notice The delay between committing and executing batches is changed.
    event NewExecutionDelay(uint256 _newExecutionDelay);

    /// @dev The mapping of ZK chain address => batch number => timestamp when it was committed.
    mapping(address chainAddress => LibMap.Uint32Map batchNumberToTimestampMapping) internal committedBatchTimestamp;

    /// @dev The delay between committing and executing batches.
    uint32 public executionDelay;

    constructor(address _bridgehubAddr) {
        BRIDGE_HUB = IBridgehub(_bridgehubAddr);
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializer for the contract.
    /// @dev Expected to be delegatecalled in the constructor of the TransparentUpgradeableProxy
    /// @param _initialOwner The initial owner of the Validator timelock.
    /// @param _executionDelay The initial execution delay, i.e. minimal time between a batch is committed and executed.
    function initialize(address _initialOwner, uint32 _executionDelay) external initializer {
        _transferOwnership(_initialOwner);
        executionDelay = _executionDelay;
    }

    /// @dev Set the delay between committing and executing batches.
    function setExecutionDelay(uint32 _executionDelay) external onlyOwner {
        executionDelay = _executionDelay;
        emit NewExecutionDelay(_executionDelay);
    }

    /// @dev Returns the timestamp when `_l2BatchNumber` was committed.
    function getCommittedBatchTimestamp(address _chainAddress, uint256 _l2BatchNumber) external view returns (uint256) {
        return committedBatchTimestamp[_chainAddress].get(_l2BatchNumber);
    }

    /// @notice Revokes the specified validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to revoke.
    /// @dev Note that the access control is managed by the inner `revokeRole` functions.
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

    /// @notice Convenience wrapper to revoke all validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to remove.
    function removeValidatorByAddress(address _chainAddress, address _validator) public {
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

    /// @notice Convenience wrapper to revoke all validator roles for a given validator on the target chain.
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _validator The address of the validator to remove.
    function removeValidator(uint256 _chainId, address _validator) external {
        removeValidatorByAddress(BRIDGE_HUB.getZKChain(_chainId), _validator);
    }

    /// @notice Grants the specified validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to update.
    /// @param params Flags indicating which roles to grant.
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

    /// @notice Convenience wrapper to grant all validator roles for a given validator on the target chain.
    /// @param _chainAddress The address identifier of the ZK chain.
    /// @param _validator The address of the validator to add.
    function addValidatorByAddress(address _chainAddress, address _validator) public {
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

    /// @notice Convenience wrapper to grant all validator roles for a given validator on the target chain.
    /// @param _chainId The chain Id of the ZK chain.
    /// @param _validator The address of the validator to add.
    function addValidator(uint256 _chainId, address _validator) external {
        addValidatorByAddress(BRIDGE_HUB.getZKChain(_chainId), _validator);
    }

    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    function precommitSharedBridge(
        address _chainAddress, // Changed from uint256
        uint256, // _l2BlockNumber (unused in this specific implementation)
        bytes calldata // _l2Block (unused in this specific implementation)
    ) public onlyRole(_chainAddress, PRECOMMITTER_ROLE) {
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Records the timestamp for all provided committed batches and make
    /// a call to the zkChain diamond contract with the same calldata.
    function commitBatchesSharedBridge(
        address _chainAddress, // Changed from uint256
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata // _batchData (unused in this specific implementation)
    ) external onlyRole(_chainAddress, COMMITTER_ROLE) {
        unchecked {
            // This contract is only a temporary solution, that hopefully will be disabled until 2106 year, so...
            // It is safe to cast.
            uint32 timestamp = uint32(block.timestamp);
            // We disable this check because calldata array length is cheap.
            for (uint256 i = _processBatchFrom; i <= _processBatchTo; ++i) {
                committedBatchTimestamp[_chainAddress].set(i, timestamp);
            }
        }
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: If the batch is reverted, it needs to be committed first before the execution.
    /// So it's safe to not override the committed batches.
    function revertBatchesSharedBridge(
        address _chainAddress,
        uint256 /*_l2BatchNumber*/
    ) external onlyRole(_chainAddress, REVERTER_ROLE) {
        // Changed from uint256
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Make a call to the zkChain diamond contract with the same calldata.
    /// Note: We don't track the time when batches are proven, since all information about
    /// the batch is known on the commit stage and the proved is not finalized (may be reverted).
    function proveBatchesSharedBridge(
        address _chainAddress, // Changed from uint256
        uint256, // _processBatchFrom (unused in this specific implementation)
        uint256, // _processBatchTo (unused in this specific implementation)
        bytes calldata // _proofData (unused in this specific implementation)
    ) external onlyRole(_chainAddress, PROVER_ROLE) {
        _propagateToZKChain(_chainAddress);
    }

    /// @dev Check that batches were committed at least X time ago and
    /// make a call to the zkChain diamond contract with the same calldata.
    function executeBatchesSharedBridge(
        address _chainAddress, // Changed from uint256
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata // _batchData (unused in this specific implementation)
    ) external onlyRole(_chainAddress, EXECUTOR_ROLE) {
        uint256 delay = executionDelay; // uint32
        unchecked {
            // We disable this check because calldata array length is cheap.
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
        // Changed from uint256
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
        // ensureing that this role is only available to chains that are part of the ecosystem is enough
        // to ensure that this contract only works with such chains.

        // Firstly, we check that the chain is indeed a part of the ecosystem
        uint256 chainId = IZKChain(_chainAddress).getChainId();
        require(IBridgehub(BRIDGE_HUB).getZKChain(chainId) == _chainAddress, NotAZKChain(_chainAddress));

        // Now, we can extract the admin
        return IZKChain(_chainAddress).getAdmin();
    }
}
