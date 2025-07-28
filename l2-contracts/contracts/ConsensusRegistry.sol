// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {IConsensusRegistry} from "./interfaces/IConsensusRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry
/// @dev Manages validator nodes and committees for the L2 consensus protocol,
/// owned by Matter Labs Multisig. This contract facilitates
/// the rotation of validator committees, which represent a subset of validator nodes
/// expected to actively participate in the consensus process during a specific time window.
/// @dev Designed for use with a proxy for upgradability.
contract ConsensusRegistry is IConsensusRegistry, Initializable, Ownable2StepUpgradeable {
    /// @dev An array to keep track of validator owners.
    address[] public validatorOwners;
    /// @dev A mapping of validator owners => validators.
    mapping(address => Validator) public validators;
    /// @dev A mapping for enabling efficient lookups when checking whether a given validator public key exists.
    mapping(bytes32 => bool) public validatorPubKeyHashes;
    /// @dev An array to keep track of removed validators that may be eligible for deletion.
    address[] public removedValidators;
    /// @dev Mapping to track the index of each validator in the removedValidators array (stored as index + 1, 0 means not present)
    mapping(address => uint256) private removedValidatorIndices;
    /// @dev Counter that keeps track of the number of active leader validators. We use it to check if there's at
    /// least one active leader validator before we commit the validator committee.
    uint256 public activeLeaderValidatorsCount;
    /// @dev Counter that increments with each new commit to the validator committee. It is used to track the current
    /// and pending validator committees.
    uint64 public validatorsCommit;
    /// @dev Block number when the last commit to the validator committee becomes active.
    uint256 public validatorsCommitBlock;
    /// @dev The delay in blocks before a committee commit becomes active.
    uint256 public committeeActivationDelay;
    /// @dev Represents the leader selection process configuration.
    LeaderSelection public leaderSelection;

    /// @dev Maximum number of removed validators to attempt deletion in one call
    uint256 private constant MAX_CLEANUP_BATCH_SIZE = 2;

    modifier onlyOwnerOrValidatorOwner(address _validatorOwner) {
        if (owner() != msg.sender && _validatorOwner != msg.sender) {
            revert UnauthorizedOnlyOwnerOrValidatorOwner();
        }
        _;
    }

    function initialize(address _initialOwner) external initializer {
        if (_initialOwner == address(0)) {
            revert InvalidInputValidatorOwnerAddress();
        }
        _transferOwnership(_initialOwner);

        // Initialize leaderSelection with default values
        leaderSelection = LeaderSelection({
            latest: LeaderSelectionAttr({frequency: 1, weighted: false}),
            snapshot: LeaderSelectionAttr({frequency: 1, weighted: false}),
            snapshotCommit: 0,
            previousSnapshot: LeaderSelectionAttr({frequency: 1, weighted: false}),
            previousSnapshotCommit: 0
        });
    }

    function add(
        address _validatorOwner,
        bool _validatorIsLeader,
        bool _validatorIsActive,
        uint256 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP
    ) external onlyOwner {
        // Try to delete removed validators to free up space
        _tryDeleteRemovedValidators(MAX_CLEANUP_BATCH_SIZE);

        // Verify input.
        _verifyInputAddress(_validatorOwner);
        _verifyValidatorWeight(_validatorWeight);
        _verifyInputBLS12_381PublicKey(_validatorPubKey);
        _verifyInputBLS12_381Signature(_validatorPoP);

        // Check if validator already exists.
        if (_isValidatorOwnerExists(_validatorOwner)) {
            // If it already exists, we only allow re-adding if the validator is currently removed.
            Validator storage validator = validators[_validatorOwner];

            if (!validator.latest.removed) {
                revert ValidatorOwnerExists();
            }

            // Re-add the removed validator by updating its attributes
            bytes32 oldPubKeyHash = _hashValidatorPubKey(validator.latest.pubKey);
            bytes32 newPubKeyHash = _hashValidatorPubKey(_validatorPubKey);

            // Verify new public key doesn't already exist (unless it's the same key)
            if (oldPubKeyHash != newPubKeyHash) {
                _verifyValidatorPubKeyDoesNotExist(newPubKeyHash);
                // Remove old public key hash and add new one
                delete validatorPubKeyHashes[oldPubKeyHash];
                validatorPubKeyHashes[newPubKeyHash] = true;
            }

            // Ensure validator snapshot before updating
            _ensureValidatorSnapshot(validator);

            // Update validator attributes
            validator.latest.active = _validatorIsActive;
            validator.latest.removed = false;
            validator.latest.leader = _validatorIsLeader;
            validator.latest.weight = _validatorWeight;
            validator.latest.pubKey = _validatorPubKey;
            validator.latest.proofOfPossession = _validatorPoP;

            // Remove from removedValidators array since it's being re-added
            _removeFromRemovedValidators(_validatorOwner);
        } else {
            // Normal addition flow (validator doesn't exist or was deleted)
            bytes32 validatorPubKeyHash = _hashValidatorPubKey(_validatorPubKey);
            _verifyValidatorPubKeyDoesNotExist(validatorPubKeyHash);
            validatorPubKeyHashes[validatorPubKeyHash] = true;

            uint32 ownerIdx = uint32(validatorOwners.length);
            validatorOwners.push(_validatorOwner);

            validators[_validatorOwner] = Validator({
                ownerIdx: ownerIdx,
                latest: ValidatorAttr({
                    active: _validatorIsActive,
                    removed: false,
                    leader: _validatorIsLeader,
                    weight: _validatorWeight,
                    pubKey: _validatorPubKey,
                    proofOfPossession: _validatorPoP
                }),
                snapshot: ValidatorAttr({
                    active: false,
                    removed: false,
                    leader: false,
                    weight: 0,
                    pubKey: BLS12_381PublicKey({a: bytes32(0), b: bytes32(0), c: bytes32(0)}),
                    proofOfPossession: BLS12_381Signature({a: bytes32(0), b: bytes16(0)})
                }),
                snapshotCommit: validatorsCommit,
                previousSnapshot: ValidatorAttr({
                    active: false,
                    removed: false,
                    leader: false,
                    weight: 0,
                    pubKey: BLS12_381PublicKey({a: bytes32(0), b: bytes32(0), c: bytes32(0)}),
                    proofOfPossession: BLS12_381Signature({a: bytes32(0), b: bytes16(0)})
                }),
                previousSnapshotCommit: 0
            });
        }

        // If the validator is a leader and active, increment the active leader validators count.
        if (_validatorIsLeader && _validatorIsActive) {
            ++activeLeaderValidatorsCount;
        }

        emit ValidatorAdded({
            validatorOwner: _validatorOwner,
            validatorIsActive: _validatorIsActive,
            validatorIsLeader: _validatorIsLeader,
            validatorWeight: _validatorWeight,
            validatorPubKey: _validatorPubKey
        });
    }

    function remove(address _validatorOwner) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);

        // Get the validator and delete it if it is pending deletion.
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        // If the validator is already removed, do nothing.
        if (validator.latest.removed) {
            return;
        }

        _ensureValidatorSnapshot(validator);

        validator.latest.removed = true;

        // Add to removed validators array for potential cleanup
        removedValidators.push(_validatorOwner);
        removedValidatorIndices[_validatorOwner] = removedValidators.length; // Store index + 1

        // If the validator was a leader, decrement the active leader validators count.
        if (validator.latest.leader && validator.latest.active) {
            --activeLeaderValidatorsCount;
        }

        emit ValidatorRemoved(_validatorOwner);
    }

    function changeValidatorActive(
        address _validatorOwner,
        bool _isActive
    ) external onlyOwnerOrValidatorOwner(_validatorOwner) {
        _verifyValidatorOwnerExists(_validatorOwner);

        // Get the validator and delete it if it is pending deletion.
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        // If the validator is removed, do nothing.
        if (validator.latest.removed) {
            return;
        }

        // If we are not changing the active status, do nothing.
        if (validator.latest.active == _isActive) {
            return;
        }

        _ensureValidatorSnapshot(validator);

        validator.latest.active = _isActive;

        // If the validator is a leader, update the active leader validators count.
        if (validator.latest.leader) {
            if (_isActive) {
                ++activeLeaderValidatorsCount;
            } else {
                --activeLeaderValidatorsCount;
            }
        }

        emit ValidatorActiveStatusChanged(_validatorOwner, _isActive);
    }

    function changeValidatorLeader(address _validatorOwner, bool _isLeader) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);

        // Get the validator and delete it if it is pending deletion.
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        // If the validator is removed, do nothing.
        if (validator.latest.removed) {
            return;
        }

        // If we are not changing the leader status, do nothing.
        if (validator.latest.leader == _isLeader) {
            return;
        }

        _ensureValidatorSnapshot(validator);

        validator.latest.leader = _isLeader;

        // If the validator is active, update the active leader validators count.
        if (validator.latest.active) {
            if (_isLeader) {
                ++activeLeaderValidatorsCount;
            } else {
                --activeLeaderValidatorsCount;
            }
        }

        emit ValidatorLeaderStatusChanged(_validatorOwner, _isLeader);
    }

    function changeValidatorWeight(address _validatorOwner, uint256 _weight) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);
        _verifyValidatorWeight(_weight);

        // Get the validator and delete it if it is pending deletion.
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        // If the validator is removed, do nothing.
        if (validator.latest.removed) {
            return;
        }

        _ensureValidatorSnapshot(validator);

        validator.latest.weight = _weight;

        emit ValidatorWeightChanged(_validatorOwner, _weight);
    }

    function changeValidatorKey(
        address _validatorOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);

        // Verify input.
        _verifyInputBLS12_381PublicKey(_pubKey);
        _verifyInputBLS12_381Signature(_pop);

        // Get the validator and delete it if it is pending deletion.
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        // If the validator is removed, do nothing.
        if (validator.latest.removed) {
            return;
        }

        // Verify new public key doesn't already exist (unless it's the same key)
        bytes32 oldHash = _hashValidatorPubKey(validator.latest.pubKey);
        bytes32 newHash = _hashValidatorPubKey(_pubKey);
        if (oldHash == newHash) {
            // If the public key is the same, we do nothing.
            return;
        } else {
            // If the public key is different, we need to verify that it doesn't already exist.
            _verifyValidatorPubKeyDoesNotExist(newHash);
            // Remove old public key hash and add new one
            delete validatorPubKeyHashes[oldHash];
            validatorPubKeyHashes[newHash] = true;
        }

        _ensureValidatorSnapshot(validator);

        validator.latest.pubKey = _pubKey;
        validator.latest.proofOfPossession = _pop;

        emit ValidatorKeyChanged(_validatorOwner, _pubKey);
    }

    function commitValidatorCommittee() external onlyOwner {
        // If validatorsCommitBlock is still in the future, revert.
        // Otherwise, we would create a pending committee while another one is still pending.
        if (block.number < validatorsCommitBlock) {
            revert PreviousCommitStillPending();
        }

        // Check if there's at least one active leader validator.
        // Otherwise, we would create a committee with no validator able to produce blocks.
        if (activeLeaderValidatorsCount == 0) {
            revert NoActiveLeader();
        }

        // Increment the commit number.
        ++validatorsCommit;

        // Schedule the new commit to activate after the delay
        validatorsCommitBlock = block.number + committeeActivationDelay;

        emit ValidatorsCommitted(validatorsCommit, validatorsCommitBlock);
    }

    function getValidatorCommittee() public view returns (CommitteeValidator[] memory, LeaderSelectionAttr memory) {
        return (_getCommittee(false), _getLeaderSelectionAttributes(false));
    }

    function getNextValidatorCommittee() public view returns (CommitteeValidator[] memory, LeaderSelectionAttr memory) {
        if (block.number >= validatorsCommitBlock) {
            revert NoPendingCommittee();
        }
        return (_getCommittee(true), _getLeaderSelectionAttributes(true));
    }

    function setCommitteeActivationDelay(uint256 _delay) external onlyOwner {
        committeeActivationDelay = _delay;
        emit CommitteeActivationDelayChanged(_delay);
    }

    /// @notice Updates the leader selection configuration
    /// @dev Only callable by the contract owner
    /// @param _frequency The number of views between leader changes. If it is 0 then the leader never rotates.
    /// @param _weighted Whether leaders are selected proportionally to their weight. If false, then the leader is selected round-robin.
    function updateLeaderSelection(uint64 _frequency, bool _weighted) external onlyOwner {
        // Ensure leader selection is properly snapshotted
        _ensureLeaderSelectionSnapshot();

        // Update with new values
        leaderSelection.latest = LeaderSelectionAttr({frequency: _frequency, weighted: _weighted});

        emit LeaderSelectionChanged(leaderSelection.latest);
    }

    /// @notice Manually triggers cleanup of removed validators
    /// @dev Only callable by the contract owner. Useful for batch cleanup without adding new validators.
    /// @param _maxDeletions Maximum number of validators to attempt deletion for
    function cleanupRemovedValidators(uint256 _maxDeletions) external onlyOwner {
        _tryDeleteRemovedValidators(_maxDeletions);
    }

    /// @notice Internal helper to build committee arrays
    /// @dev Handles the common logic for getting current or pending validator committee
    /// @param _isPendingCommittee Whether to get the pending committee instead of the currently active one
    /// @return committee Array of committee validators
    function _getCommittee(bool _isPendingCommittee) private view returns (CommitteeValidator[] memory) {
        uint256 len = validatorOwners.length;
        CommitteeValidator[] memory committee = new CommitteeValidator[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; ++i) {
            Validator storage validator = validators[validatorOwners[i]];
            ValidatorAttr memory validatorAttr;

            if (_isPendingCommittee) {
                // Get the attributes that are in the pending committee.
                if (validatorsCommit > validator.snapshotCommit) {
                    validatorAttr = validator.latest;
                } else {
                    validatorAttr = validator.snapshot;
                }
                // For pending committee, we don't need to check the previous snapshot.
            } else {
                uint64 currentActiveCommit = _getActiveCommit();
                if (currentActiveCommit > validator.snapshotCommit) {
                    validatorAttr = validator.latest;
                } else if (currentActiveCommit > validator.previousSnapshotCommit) {
                    validatorAttr = validator.snapshot;
                } else {
                    validatorAttr = validator.previousSnapshot;
                }
            }

            if (validatorAttr.active && !validatorAttr.removed) {
                committee[count] = CommitteeValidator({
                    leader: validatorAttr.leader,
                    weight: validatorAttr.weight,
                    pubKey: validatorAttr.pubKey,
                    proofOfPossession: validatorAttr.proofOfPossession
                });
                ++count;
            }
        }

        // Resize the array
        assembly {
            mstore(committee, count)
        }
        return committee;
    }

    function _getLeaderSelectionAttributes(bool _isPendingCommittee) private view returns (LeaderSelectionAttr memory) {
        if (_isPendingCommittee) {
            // Get the leader selection that is in the pending committee.
            if (validatorsCommit > leaderSelection.snapshotCommit) {
                return leaderSelection.latest;
            } else {
                return leaderSelection.snapshot;
            }
            // For pending committee, we don't need to check the previous snapshot.
        } else {
            // Get currently active leader selection
            uint64 currentActiveCommit = _getActiveCommit();
            if (currentActiveCommit > leaderSelection.snapshotCommit) {
                return leaderSelection.latest;
            } else if (currentActiveCommit > leaderSelection.previousSnapshotCommit) {
                return leaderSelection.snapshot;
            } else {
                return leaderSelection.previousSnapshot;
            }
        }
    }

    /// @notice Returns the commit number of the currently active validator committee
    /// @dev Helper function to get the appropriate commit number based on the current block number
    function _getActiveCommit() private view returns (uint64) {
        if (block.number >= validatorsCommitBlock) {
            return validatorsCommit;
        } else {
            return validatorsCommit - 1;
        }
    }

    function numValidators() public view returns (uint256) {
        return validatorOwners.length;
    }

    /// @notice Returns the number of removed validators that may be eligible for deletion
    /// @dev Useful for monitoring the cleanup queue
    /// @return The number of validators in the removedValidators array
    function numRemovedValidators() public view returns (uint256) {
        return removedValidators.length;
    }

    function _getValidatorAndDeleteIfRequired(address _validatorOwner) private returns (Validator storage, bool) {
        Validator storage validator = validators[_validatorOwner];
        bool pendingDeletion = _isValidatorPendingDeletion(validator);
        if (pendingDeletion) {
            _deleteValidator(_validatorOwner, validator);
        }
        return (validator, pendingDeletion);
    }

    function _isValidatorPendingDeletion(Validator storage _validator) private view returns (bool) {
        uint64 currentActiveCommit = _getActiveCommit();

        // Check that any snapshot that is more recent or as recent as the current active commit is marked as removed.
        // Otherwise, the validator might still be used in some committee and can't be deleted.
        if (currentActiveCommit <= _validator.previousSnapshotCommit && !_validator.previousSnapshot.removed) {
            return false;
        }
        if (currentActiveCommit <= _validator.snapshotCommit && !_validator.snapshot.removed) {
            return false;
        }

        // The latest attribute must also be marked as removed in order to be pending deletion.
        return _validator.latest.removed;
    }

    function _deleteValidator(address _validatorOwner, Validator storage _validator) private {
        // Delete from array by swapping the last validator owner (gas-efficient, not preserving order).
        address lastValidatorOwner = validatorOwners[validatorOwners.length - 1];
        validatorOwners[_validator.ownerIdx] = lastValidatorOwner;
        validatorOwners.pop();

        // Update the validator owned by the last validator owner.
        validators[lastValidatorOwner].ownerIdx = _validator.ownerIdx;

        // Delete from the remaining mappings.
        delete validatorPubKeyHashes[_hashValidatorPubKey(_validator.latest.pubKey)];
        delete validators[_validatorOwner];

        emit ValidatorDeleted(_validatorOwner);
    }

    function _ensureValidatorSnapshot(Validator storage _validator) private {
        if (_validator.snapshotCommit < validatorsCommit) {
            // When creating a snapshot, preserve the previous one
            _validator.previousSnapshot = _validator.snapshot;
            _validator.previousSnapshotCommit = _validator.snapshotCommit;
            _validator.snapshot = _validator.latest;
            _validator.snapshotCommit = validatorsCommit;
        }
    }

    function _ensureLeaderSelectionSnapshot() private {
        if (leaderSelection.snapshotCommit < validatorsCommit) {
            // When creating a snapshot, preserve the previous one
            leaderSelection.previousSnapshot = leaderSelection.snapshot;
            leaderSelection.previousSnapshotCommit = leaderSelection.snapshotCommit;
            leaderSelection.snapshot = leaderSelection.latest;
            leaderSelection.snapshotCommit = validatorsCommit;
        }
    }

    function _isValidatorOwnerExists(address _validatorOwner) private view returns (bool) {
        BLS12_381PublicKey storage pubKey = validators[_validatorOwner].latest.pubKey;
        if (pubKey.a == bytes32(0) && pubKey.b == bytes32(0) && pubKey.c == bytes32(0)) {
            return false;
        }
        return true;
    }

    function _verifyValidatorOwnerExists(address _validatorOwner) private view {
        if (!_isValidatorOwnerExists(_validatorOwner)) {
            revert ValidatorOwnerDoesNotExist();
        }
    }

    function _verifyValidatorOwnerDoesNotExist(address _validatorOwner) private view {
        if (_isValidatorOwnerExists(_validatorOwner)) {
            revert ValidatorOwnerExists();
        }
    }

    function _hashValidatorPubKey(BLS12_381PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _verifyInputAddress(address _validatorOwner) private pure {
        if (_validatorOwner == address(0)) {
            revert InvalidInputValidatorOwnerAddress();
        }
    }

    function _verifyValidatorPubKeyDoesNotExist(bytes32 _hash) private view {
        if (validatorPubKeyHashes[_hash]) {
            revert ValidatorPubKeyExists();
        }
    }

    function _verifyInputBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure {
        if (_isEmptyBLS12_381PublicKey(_pubKey)) {
            revert InvalidInputBLS12_381PublicKey();
        }
    }

    function _verifyInputBLS12_381Signature(BLS12_381Signature calldata _pop) private pure {
        if (_isEmptyBLS12_381Signature(_pop)) {
            revert InvalidInputBLS12_381Signature();
        }
    }

    function _verifyValidatorWeight(uint256 _weight) private pure {
        if (_weight == 0) {
            revert ZeroValidatorWeight();
        }
    }

    function _isEmptyBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bool) {
        return _pubKey.a == bytes32(0) && _pubKey.b == bytes32(0) && _pubKey.c == bytes32(0);
    }

    function _isEmptyBLS12_381Signature(BLS12_381Signature calldata _pop) private pure returns (bool) {
        return _pop.a == bytes32(0) && _pop.b == bytes16(0);
    }

    /// @notice Attempts to delete up to a specified number of removed validators that are eligible for deletion
    /// @dev This method helps maintain the removedValidators array by cleaning up validators that can be safely deleted
    /// @param _maxDeletions Maximum number of validators to attempt deletion for
    function _tryDeleteRemovedValidators(uint256 _maxDeletions) private {
        uint256 deletions = 0;
        uint256 i = 0;

        // Iterate through removedValidators array, attempting deletions
        while (i < removedValidators.length && deletions < _maxDeletions) {
            address validatorOwner = removedValidators[i];

            // Check if this validator exists and is pending deletion
            if (_isValidatorOwnerExists(validatorOwner)) {
                Validator storage validator = validators[validatorOwner];

                if (_isValidatorPendingDeletion(validator)) {
                    // Delete the validator
                    _deleteValidator(validatorOwner, validator);
                    // Remove from removedValidators array
                    _removeFromRemovedValidatorsAtIndex(i);
                    deletions++;
                    // Don't increment i since we swapped an element into current position
                } else {
                    // Validator is not yet eligible for deletion, move to next
                    i++;
                }
            } else {
                // Validator no longer exists (already deleted), remove from array
                _removeFromRemovedValidatorsAtIndex(i);
                // Don't increment i since we swapped an element into current position
            }
        }
    }

    /// @notice Removes a validator from the removedValidators array at a specific index
    /// @dev Helper method to efficiently remove an element and maintain the index mapping
    /// @param _index The index of the validator to remove from the array
    function _removeFromRemovedValidatorsAtIndex(uint256 _index) private {
        address validatorOwner = removedValidators[_index];
        uint256 lastIndex = removedValidators.length - 1;

        if (_index != lastIndex) {
            // Move the last element to the position being deleted
            address lastValidator = removedValidators[lastIndex];
            removedValidators[_index] = lastValidator;
            // Update the index mapping for the moved validator
            removedValidatorIndices[lastValidator] = _index + 1;
        }

        // Remove the last element and clear the mapping
        removedValidators.pop();
        delete removedValidatorIndices[validatorOwner];
    }

    /// @notice Removes a validator from the removedValidators array
    /// @dev Helper method to clean up the removedValidators array when a validator is re-added
    /// @param _validatorOwner The validator owner address to remove from the array
    function _removeFromRemovedValidators(address _validatorOwner) private {
        uint256 indexPlusOne = removedValidatorIndices[_validatorOwner];
        if (indexPlusOne == 0) {
            // Validator not in removedValidators array
            return;
        }

        _removeFromRemovedValidatorsAtIndex(indexPlusOne - 1);
    }
}
