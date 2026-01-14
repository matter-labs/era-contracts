// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry contract interface
interface IConsensusRegistry {
    /// @dev Represents a validator in the consensus protocol.
    /// @param ownerIdx Index of the validator owner within the array of validator owners.
    /// @param lastSnapshotCommit The `validatorsCommit` value when the last snapshot of this validator was made.
    /// @param previousSnapshotCommit The `validatorsCommit` value when the previous snapshot of this validator was made.
    /// @param latest Validator attributes to read if `validatorsCommit` > `validator.lastSnapshotCommit`.
    /// @param snapshot Validator attributes to read if `validatorsCommit` > `validator.previousSnapshot`.
    /// @param previousSnapshot Validator attributes to read for older commits.
    struct Validator {
        uint32 ownerIdx;
        uint32 lastSnapshotCommit;
        uint32 previousSnapshotCommit;
        ValidatorAttr latest;
        ValidatorAttr snapshot;
        ValidatorAttr previousSnapshot;
    }

    /// @dev Represents the attributes of a validator.
    /// @param active A flag stating if the validator is active.
    /// @param removed A flag stating if the validator has been removed (and is pending a deletion).
    /// @param leader A flag stating if the validator is eligible to be a leader.
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct ValidatorAttr {
        bool active;
        bool removed;
        bool leader;
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents the leader selection process in the consensus protocol.
    /// @param lastSnapshotCommit The `validatorsCommit` value when the last snapshot was made.
    /// @param previousSnapshotCommit The `validatorsCommit` value when the previous snapshot was made.
    /// @param latest LeaderSelectionAttr to read if `validatorsCommit` > `lastSnapshotCommit`.
    /// @param snapshot LeaderSelectionAttr to read if `validatorsCommit` > `previousSnapshot`.
    /// @param previousSnapshot LeaderSelectionAttr to read for older commits.
    struct LeaderSelection {
        uint32 lastSnapshotCommit;
        uint32 previousSnapshotCommit;
        LeaderSelectionAttr latest;
        LeaderSelectionAttr snapshot;
        LeaderSelectionAttr previousSnapshot;
    }

    /// @dev Attributes for the validator leader selection process.
    /// @param frequency The number of views between leader changes. If it is 0 then the leader never rotates.
    /// @param weighted Whether leaders are selectedproportionally to their weight. If false, then the leader is selected round-robin.
    struct LeaderSelectionAttr {
        uint64 frequency;
        bool weighted;
    }

    /// @dev Represents a validator within a committee.
    /// @param leader A flag stating if the validator is eligible to be a leader.
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct CommitteeValidator {
        bool leader;
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents BLS12_381 public key.
    /// @param a First component of the BLS12-381 public key.
    /// @param b Second component of the BLS12-381 public key.
    /// @param c Third component of the BLS12-381 public key.
    // solhint-disable-next-line
    struct BLS12_381PublicKey {
        bytes32 a;
        bytes32 b;
        bytes32 c;
    }

    /// @dev Represents BLS12_381 signature.
    /// @param a First component of the BLS12-381 signature.
    /// @param b Second component of the BLS12-381 signature.
    // solhint-disable-next-line
    struct BLS12_381Signature {
        bytes32 a;
        bytes16 b;
    }

    error UnauthorizedOnlyOwnerOrValidatorOwner();
    error ValidatorOwnerExists();
    error ValidatorOwnerDoesNotExist();
    error ValidatorOwnerNotFound();
    error ValidatorPubKeyExists();
    error InvalidInputValidatorOwnerAddress();
    error InvalidInputBLS12_381PublicKey();
    error InvalidInputBLS12_381Signature();
    error NoPendingCommittee();
    error PreviousCommitStillPending();
    error NoActiveLeader();

    event ValidatorAdded(
        address indexed validatorOwner,
        uint32 validatorWeight,
        BLS12_381PublicKey validatorPubKey,
        BLS12_381Signature validatorPoP
    );
    event ValidatorRemoved(address indexed validatorOwner);
    event ValidatorDeleted(address indexed validatorOwner);
    event ValidatorActiveStatusChanged(address indexed validatorOwner, bool isActive);
    event ValidatorLeaderStatusChanged(address indexed validatorOwner, bool isLeader);
    event ValidatorWeightChanged(address indexed validatorOwner, uint32 newWeight);
    event ValidatorKeyChanged(address indexed validatorOwner, BLS12_381PublicKey newPubKey, BLS12_381Signature newPoP);
    event ValidatorsCommitted(uint32 validatorsCommit, uint256 validatorsCommitBlock);
    event CommitteeActivationDelayChanged(uint256 newDelay);
    event LeaderSelectionChanged(LeaderSelectionAttr newLeaderSelection);

    /// @notice Adds a new validator to the registry.
    /// @dev Fails if validator owner already exists.
    /// @dev Fails if a validator with the same public key already exists.
    /// @param _validatorOwner The address of the validator's owner.
    /// @param _validatorIsLeader Flag indicating if the validator is a leader.
    /// @param _validatorWeight The voting weight of the validator.
    /// @param _validatorPubKey The BLS12-381 public key of the validator.
    /// @param _validatorPoP The proof-of-possession (PoP) of the validator's public key.
    function add(
        address _validatorOwner,
        bool _validatorIsLeader,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP
    ) external;

    /// @notice Removes a validator from the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator to be removed.
    function remove(address _validatorOwner) external;

    /// @notice Changes the active status of a validator, determining whether it can participate in committees.
    /// @dev Only callable by the contract owner or the validator owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose active status will be changed.
    /// @param _isActive The new active status to assign to the validator.
    function changeValidatorActive(address _validatorOwner, bool _isActive) external;

    /// @notice Changes the validator's leader status in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose leader status will be changed.
    /// @param _isLeader The new leader status to assign to the validator.
    function changeValidatorLeader(address _validatorOwner, bool _isLeader) external;

    /// @notice Changes the validator weight of a validator in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose weight will be changed.
    /// @param _weight The new validator weight to assign to the validator.
    function changeValidatorWeight(address _validatorOwner, uint32 _weight) external;

    /// @notice Changes the validator's public key and proof-of-possession in the registry.
    /// @dev Only callable by the contract owner or the validator owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose key and PoP will be changed.
    /// @param _pubKey The new BLS12-381 public key to assign to the validator.
    /// @param _pop The new proof-of-possession (PoP) to assign to the validator.
    function changeValidatorKey(
        address _validatorOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external;

    /// @notice Adds a new commit to the validator committee using the current block number plus delay.
    /// @dev The committee will become active after committeeActivationDelay blocks.
    /// @dev Only callable by the contract owner.
    /// @dev Reverts if validatorsCommitBlock is still in the future.
    function commitValidatorCommittee() external;

    /// @notice Returns an array of `ValidatorAttr` structs representing the current validator committee and the current leader selection configuration.
    /// @dev Collects active and non-removed validators based on the latest commit to the committee.
    function getValidatorCommittee() external view returns (CommitteeValidator[] memory, LeaderSelectionAttr memory);

    /// @notice Returns an array of `ValidatorAttr` structs representing the pending validator committee and the pending leader selection configuration.
    /// @dev Collects active and non-removed validators that will form the next committee after the current commit becomes active.
    /// @dev Reverts if there is no pending committee (when block.number >= validatorsCommitBlock).
    function getNextValidatorCommittee()
        external
        view
        returns (CommitteeValidator[] memory, LeaderSelectionAttr memory);

    /// @notice Updates the delay for committee activation
    /// @dev Only callable by the contract owner
    /// @param _delay The new delay in blocks
    function setCommitteeActivationDelay(uint256 _delay) external;

    /// @notice Updates the leader selection configuration
    /// @dev Only callable by the contract owner
    /// @param _frequency The number of views between leader changes. If it is 0 then the leader never rotates.
    /// @param _weighted Whether leaders are selected proportionally to their weight. If false, then the leader is selected round-robin.
    function updateLeaderSelection(uint64 _frequency, bool _weighted) external;
}
