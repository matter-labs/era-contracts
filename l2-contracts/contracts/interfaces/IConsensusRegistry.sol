// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry contract interface
interface IConsensusRegistry {
    /// @dev Represents a consensus node.
    /// @param attesterLastUpdateCommit The latest `attestersCommit` where the node's attester attributes were updated.
    /// @param attesterLatest Attester attributes to read if `node.attesterLastUpdateCommit` < `attestersCommit`.
    /// @param attesterSnapshot Attester attributes to read if `node.attesterLastUpdateCommit` == `attestersCommit`.
    /// @param validatorLastUpdateCommit The latest `validatorsCommit` where the node's validator attributes were updated.
    /// @param validatorLatest Validator attributes to read if `node.validatorLastUpdateCommit` < `validatorsCommit`.
    /// @param validatorSnapshot Validator attributes to read if `node.validatorLastUpdateCommit` == `validatorsCommit`.
    /// @param nodeOwnerIdx Index of the node owner within the array of node owners.
    struct Node {
        uint32 attesterLastUpdateCommit;
        uint32 validatorLastUpdateCommit;
        uint32 nodeOwnerIdx;
        AttesterAttr attesterLatest;
        AttesterAttr attesterSnapshot;
        ValidatorAttr validatorLatest;
        ValidatorAttr validatorSnapshot;
    }

    /// @dev Represents the attester attributes of a consensus node.
    /// @param active A flag stating if the attester is active.
    /// @param removed A flag stating if the attester has been removed (and is pending a deletion).
    /// @param weight Attester's voting weight.
    /// @param pubKey Attester's Secp256k1 public key.
    struct AttesterAttr {
        bool active;
        bool removed;
        uint32 weight;
        Secp256k1PublicKey pubKey;
    }

    /// @dev Represents an attester within a committee.
    /// @param weight Attester's voting weight.
    /// @param pubKey Attester's Secp256k1 public key.
    struct CommitteeAttester {
        uint32 weight;
        Secp256k1PublicKey pubKey;
    }

    /// @dev Represents the validator attributes of a consensus node.
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

    /// @dev Represents Secp256k1 public key.
    /// @param tag Y-coordinate's even/odd indicator of the Secp256k1 public key.
    /// @param x X-coordinate component of the Secp256k1 public key.
    struct Secp256k1PublicKey {
        bytes1 tag;
        bytes32 x;
    }

    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyExists();
    error AttesterPubKeyExists();
    error InvalidInputNodeOwnerAddress();
    error InvalidInputBLS12_381PublicKey();
    error InvalidInputBLS12_381Signature();
    error InvalidInputSecp256k1PublicKey();

    event NodeAdded(
        address indexed nodeOwner,
        uint32 validatorWeight,
        BLS12_381PublicKey validatorPubKey,
        BLS12_381Signature validatorPoP,
        uint32 attesterWeight,
        Secp256k1PublicKey attesterPubKey
    );
    event NodeDeactivated(address indexed nodeOwner);
    event NodeActivated(address indexed nodeOwner);
    event NodeRemoved(address indexed nodeOwner);
    event NodeDeleted(address indexed nodeOwner);
    event NodeValidatorWeightChanged(address indexed nodeOwner, uint32 newWeight);
    event NodeAttesterWeightChanged(address indexed nodeOwner, uint32 newWeight);
    event NodeValidatorKeyChanged(address indexed nodeOwner, BLS12_381PublicKey newPubKey, BLS12_381Signature newPoP);
    event NodeAttesterKeyChanged(address indexed nodeOwner, Secp256k1PublicKey newPubKey);
    event ValidatorsCommitted(uint32 commit);
    event AttestersCommitted(uint32 commit);

    function add(
        address _nodeOwner,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP,
        uint32 _attesterWeight,
        Secp256k1PublicKey calldata _attesterPubKey
    ) external;

    function deactivate(address _nodeOwner) external;

    function activate(address _nodeOwner) external;

    function remove(address _nodeOwner) external;

    function changeValidatorWeight(address _nodeOwner, uint32 _weight) external;

    function changeAttesterWeight(address _nodeOwner, uint32 _weight) external;

    function changeValidatorKey(
        address _nodeOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external;

    function changeAttesterKey(address _nodeOwner, Secp256k1PublicKey calldata _pubKey) external;

    function commitAttesterCommittee() external;

    function commitValidatorCommittee() external;

    function getAttesterCommittee() external view returns (CommitteeAttester[] memory);

    function getValidatorCommittee() external view returns (CommitteeValidator[] memory);
}
