// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

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
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct ValidatorAttr {
        bool active;
        bool removed;
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents a validator within a committee.
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct CommitteeValidator {
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents BLS12_381 public key.
    /// @param a First component of the BLS12-381 public key.
    /// @param b Second component of the BLS12-381 public key.
    /// @param c Third component of the BLS12-381 public key.
    struct BLS12_381PublicKey {
        bytes32 a;
        bytes32 b;
        bytes32 c;
    }

    /// @dev Represents BLS12_381 signature.
    /// @param a First component of the BLS12-381 signature.
    /// @param b Second component of the BLS12-381 signature.
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

    event ValidatorAdded(
        address indexed validatorOwner,
        uint32 validatorWeight,
        BLS12_381PublicKey validatorPubKey,
        BLS12_381Signature validatorPoP
    );
    event ValidatorDeactivated(address indexed validatorOwner);
    event ValidatorActivated(address indexed validatorOwner);
    event ValidatorRemoved(address indexed validatorOwner);
    event ValidatorDeleted(address indexed validatorOwner);
    event ValidatorWeightChanged(address indexed validatorOwner, uint32 newWeight);
    event ValidatorKeyChanged(address indexed validatorOwner, BLS12_381PublicKey newPubKey, BLS12_381Signature newPoP);
    event ValidatorsCommitted(uint32 validatorsCommit, uint256 validatorsCommitBlock);
    event CommitteeActivationDelayChanged(uint256 newDelay);

    function add(
        address _validatorOwner,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP
    ) external;

    function remove(address _validatorOwner) external;

    function activate(address _validatorOwner) external;

    function deactivate(address _validatorOwner) external;

    function changeValidatorWeight(address _validatorOwner, uint32 _weight) external;

    function changeValidatorKey(
        address _validatorOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external;

    function commitValidatorCommittee() external;

    function getValidatorCommittee() external view returns (CommitteeValidator[] memory);

    function getNextValidatorCommittee() external view returns (CommitteeValidator[] memory);

    function setCommitteeActivationDelay(uint256 _delay) external;
}
