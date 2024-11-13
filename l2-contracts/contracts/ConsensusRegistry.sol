// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {IConsensusRegistry} from "./interfaces/IConsensusRegistry.sol";
import {ZeroAddress} from "./errors/L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry
/// @dev Manages consensus nodes and committees for the L2 consensus protocol,
/// owned by Matter Labs Multisig. Nodes act as both validators and attesters,
/// each playing a distinct role in the consensus process. This contract facilitates
/// the rotation of validator and attester committees, which represent a subset of nodes
/// expected to actively participate in the consensus process during a specific time window.
/// @dev Designed for use with a proxy for upgradability.
contract ConsensusRegistry is IConsensusRegistry, Initializable, Ownable2StepUpgradeable {
    /// @dev An array to keep track of node owners.
    address[] public nodeOwners;
    /// @dev A mapping of node owners => nodes.
    mapping(address => Node) public nodes;
    /// @dev A mapping for enabling efficient lookups when checking whether a given attester public key exists.
    /// @dev Initially, the mappings mark the public keys used by the attesters in the current committee. However,
    /// @dev after calling the changeAttesterKey functions, the mappings might also contain public keys of attesters
    /// @dev that will only be part of the committee once the contract owner updates the attestersCommit state variable.
    mapping(bytes32 => bool) public attesterPubKeyHashes;
    /// @dev A mapping for enabling efficient lookups when checking whether a given validator public key exists.
    /// @dev Initially, the mappings mark the public keys used by the validators in the current committee. However,
    /// @dev after calling the changeValidatorKey functions, the mappings might also contain public keys of validators
    /// @dev that will only be part of the committee once the contract owner updates the validatorsCommit state variable.
    mapping(bytes32 => bool) public validatorPubKeyHashes;
    /// @dev Counter that increments with each new commit to the attester committee.
    uint32 public attestersCommit;
    /// @dev Counter that increments with each new commit to the validator committee.
    uint32 public validatorsCommit;

    modifier onlyOwnerOrNodeOwner(address _nodeOwner) {
        if (owner() != msg.sender && _nodeOwner != msg.sender) {
            revert UnauthorizedOnlyOwnerOrNodeOwner();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _initialOwner) external initializer {
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Adds a new node to the registry.
    /// @dev Fails if node owner already exists.
    /// @dev Fails if a validator/attester with the same public key already exists.
    /// @param _nodeOwner The address of the new node's owner.
    /// @param _isValidatorActive A flag stating if the validator starts activated.
    /// @param _validatorWeight The voting weight of the validator.
    /// @param _validatorPubKey The BLS12-381 public key of the validator.
    /// @param _validatorPoP The proof-of-possession (PoP) of the validator's public key.
    /// @param _isAttesterActive A flag stating if the attester starts activated.
    /// @param _attesterWeight The voting weight of the attester.
    /// @param _attesterPubKey The ECDSA public key of the attester.
    function add(
        address _nodeOwner,
        bool _isValidatorActive,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP,
        bool _isAttesterActive,
        uint32 _attesterWeight,
        Secp256k1PublicKey calldata _attesterPubKey
    ) external onlyOwner {
        // Verify input.
        _verifyInputAddress(_nodeOwner);
        _verifyInputBLS12_381PublicKey(_validatorPubKey);
        _verifyInputBLS12_381Signature(_validatorPoP);
        _verifyInputSecp256k1PublicKey(_attesterPubKey);
        if (_attesterWeight == 0) {
            revert ZeroAttesterWeight();
        }
        if (_validatorWeight == 0) {
            revert ZeroValidatorWeight();
        }

        // Verify storage.
        _verifyNodeOwnerDoesNotExist(_nodeOwner);
        bytes32 attesterPubKeyHash = _hashAttesterPubKey(_attesterPubKey);
        _verifyAttesterPubKeyDoesNotExist(attesterPubKeyHash);
        bytes32 validatorPubKeyHash = _hashValidatorPubKey(_validatorPubKey);
        _verifyValidatorPubKeyDoesNotExist(validatorPubKeyHash);

        uint32 nodeOwnerIdx = uint32(nodeOwners.length);
        nodeOwners.push(_nodeOwner);
        nodes[_nodeOwner] = Node({
            attesterLatest: AttesterAttr({
                removed: false,
                active: _isAttesterActive,
                weight: _attesterWeight,
                pubKey: _attesterPubKey
            }),
            attesterSnapshot: AttesterAttr({
                active: false,
                removed: false,
                weight: 0,
                pubKey: Secp256k1PublicKey({tag: bytes1(0), x: bytes32(0)})
            }),
            attesterLastUpdateCommit: attestersCommit,
            validatorLatest: ValidatorAttr({
                removed: false,
                active: _isValidatorActive,
                weight: _validatorWeight,
                pubKey: _validatorPubKey,
                proofOfPossession: _validatorPoP
            }),
            validatorSnapshot: ValidatorAttr({
                active: false,
                removed: false,
                weight: 0,
                pubKey: BLS12_381PublicKey({a: bytes32(0), b: bytes32(0), c: bytes32(0)}),
                proofOfPossession: BLS12_381Signature({a: bytes32(0), b: bytes16(0)})
            }),
            validatorLastUpdateCommit: validatorsCommit,
            nodeOwnerIdx: nodeOwnerIdx
        });
        attesterPubKeyHashes[attesterPubKeyHash] = true;
        validatorPubKeyHashes[validatorPubKeyHash] = true;

        emit NodeAdded({
            nodeOwner: _nodeOwner,
            isValidatorActive: _isValidatorActive,
            validatorWeight: _validatorWeight,
            validatorPubKey: _validatorPubKey,
            validatorPoP: _validatorPoP,
            isAttesterActive: _isAttesterActive,
            attesterWeight: _attesterWeight,
            attesterPubKey: _attesterPubKey
        });
    }

    /// @notice Deactivates an attester, preventing it from participating in attester committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be inactivated.
    function deactivateAttester(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotAttesterIfOutdated(node);
        node.attesterLatest.active = false;

        emit AttesterDeactivated(_nodeOwner);
    }

    /// @notice Deactivates a validator, preventing it from participating in validator committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be inactivated.
    function deactivateValidator(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotValidatorIfOutdated(node);
        node.validatorLatest.active = false;

        emit ValidatorDeactivated(_nodeOwner);
    }

    /// @notice Activates a previously inactive attester, allowing it to participate in attester committees.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be activated.
    function activateAttester(address _nodeOwner) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotAttesterIfOutdated(node);
        node.attesterLatest.active = true;

        emit AttesterActivated(_nodeOwner);
    }

    /// @notice Activates a previously inactive validator, allowing it to participate in validator committees.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be activated.
    function activateValidator(address _nodeOwner) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotValidatorIfOutdated(node);
        node.validatorLatest.active = true;

        emit ValidatorActivated(_nodeOwner);
    }

    /// @notice Removes a node from the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be removed.
    function remove(address _nodeOwner) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotAttesterIfOutdated(node);
        node.attesterLatest.removed = true;
        _snapshotValidatorIfOutdated(node);
        node.validatorLatest.removed = true;

        emit NodeRemoved(_nodeOwner);
    }

    /// @notice Changes the validator weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator weight will be changed.
    /// @param _weight The new validator weight to assign to the node, must be greater than 0.
    function changeValidatorWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        if (_weight == 0) {
            revert ZeroValidatorWeight();
        }
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotValidatorIfOutdated(node);
        node.validatorLatest.weight = _weight;

        emit NodeValidatorWeightChanged(_nodeOwner, _weight);
    }

    /// @notice Changes the attester weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester weight will be changed.
    /// @param _weight The new attester weight to assign to the node, must be greater than 0.
    function changeAttesterWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        if (_weight == 0) {
            revert ZeroAttesterWeight();
        }
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        _snapshotAttesterIfOutdated(node);
        node.attesterLatest.weight = _weight;

        emit NodeAttesterWeightChanged(_nodeOwner, _weight);
    }

    /// @notice Changes the validator's public key and proof-of-possession in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator key and PoP will be changed.
    /// @param _pubKey The new BLS12-381 public key to assign to the node's validator.
    /// @param _pop The new proof-of-possession (PoP) to assign to the node's validator.
    function changeValidatorKey(
        address _nodeOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external onlyOwner {
        _verifyInputBLS12_381PublicKey(_pubKey);
        _verifyInputBLS12_381Signature(_pop);
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        bytes32 prevHash = _hashValidatorPubKey(node.validatorLatest.pubKey);
        delete validatorPubKeyHashes[prevHash];
        bytes32 newHash = _hashValidatorPubKey(_pubKey);
        _verifyValidatorPubKeyDoesNotExist(newHash);
        validatorPubKeyHashes[newHash] = true;
        _snapshotValidatorIfOutdated(node);
        node.validatorLatest.pubKey = _pubKey;
        node.validatorLatest.proofOfPossession = _pop;

        emit NodeValidatorKeyChanged(_nodeOwner, _pubKey, _pop);
    }

    /// @notice Changes the attester's public key of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester public key will be changed.
    /// @param _pubKey The new ECDSA public key to assign to the node's attester.
    function changeAttesterKey(address _nodeOwner, Secp256k1PublicKey calldata _pubKey) external onlyOwner {
        _verifyInputSecp256k1PublicKey(_pubKey);
        _verifyNodeOwnerExists(_nodeOwner);
        (Node storage node, bool deleted) = _getNodeAndDeleteIfRequired(_nodeOwner);
        if (deleted) {
            return;
        }

        bytes32 prevHash = _hashAttesterPubKey(node.attesterLatest.pubKey);
        delete attesterPubKeyHashes[prevHash];
        bytes32 newHash = _hashAttesterPubKey(_pubKey);
        _verifyAttesterPubKeyDoesNotExist(newHash);
        attesterPubKeyHashes[newHash] = true;

        _snapshotAttesterIfOutdated(node);
        node.attesterLatest.pubKey = _pubKey;

        emit NodeAttesterKeyChanged(_nodeOwner, _pubKey);
    }

    /// @notice Adds a new commit to the attester committee.
    /// @dev Implicitly updates the attester committee by affecting readers based on the current state of a node's attester attributes:
    /// - If "attestersCommit" > "node.attesterLastUpdateCommit", read "node.attesterLatest".
    /// - If "attestersCommit" == "node.attesterLastUpdateCommit", read "node.attesterSnapshot".
    /// @dev Only callable by the contract owner.
    function commitAttesterCommittee() external onlyOwner {
        ++attestersCommit;

        emit AttestersCommitted(attestersCommit);
    }

    /// @notice Adds a new commit to the validator committee.
    /// @dev Implicitly updates the validator committee by affecting readers based on the current state of a node's validator attributes:
    /// - If "validatorsCommit" > "node.validatorLastUpdateCommit", read "node.validatorLatest".
    /// - If "validatorsCommit" == "node.validatorLastUpdateCommit", read "node.validatorSnapshot".
    /// @dev Only callable by the contract owner.
    function commitValidatorCommittee() external onlyOwner {
        ++validatorsCommit;

        emit ValidatorsCommitted(validatorsCommit);
    }

    /// @notice Returns an array of `CommitteeAttester` structs representing the current attester committee.
    /// @dev Collects active and non-removed attesters based on the latest commit to the committee.
    function getAttesterCommittee() external view returns (CommitteeAttester[] memory) {
        uint256 len = nodeOwners.length;
        CommitteeAttester[] memory committee = new CommitteeAttester[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; ++i) {
            Node storage node = nodes[nodeOwners[i]];
            AttesterAttr memory attester = attestersCommit > node.attesterLastUpdateCommit
                ? node.attesterLatest
                : node.attesterSnapshot;
            if (attester.active && !attester.removed) {
                committee[count] = CommitteeAttester({weight: attester.weight, pubKey: attester.pubKey});
                ++count;
            }
        }

        // Resize the array.
        assembly {
            mstore(committee, count)
        }
        return committee;
    }

    /// @notice Returns an array of `CommitteeValidator` structs representing the current attester committee.
    /// @dev Collects active and non-removed validators based on the latest commit to the committee.
    function getValidatorCommittee() external view returns (CommitteeValidator[] memory) {
        uint256 len = nodeOwners.length;
        CommitteeValidator[] memory committee = new CommitteeValidator[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; ++i) {
            Node storage node = nodes[nodeOwners[i]];
            ValidatorAttr memory validator = validatorsCommit > node.validatorLastUpdateCommit
                ? node.validatorLatest
                : node.validatorSnapshot;
            if (validator.active && !validator.removed) {
                committee[count] = CommitteeValidator({
                    weight: validator.weight,
                    pubKey: validator.pubKey,
                    proofOfPossession: validator.proofOfPossession
                });
                ++count;
            }
        }

        // Resize the array.
        assembly {
            mstore(committee, count)
        }
        return committee;
    }

    function numNodes() external view returns (uint256) {
        return nodeOwners.length;
    }

    function _getNodeAndDeleteIfRequired(address _nodeOwner) private returns (Node storage, bool) {
        Node storage node = nodes[_nodeOwner];
        bool pendingDeletion = _isNodePendingDeletion(node);
        if (pendingDeletion) {
            _deleteNode(_nodeOwner, node);
        }
        return (node, pendingDeletion);
    }

    function _isNodePendingDeletion(Node storage _node) private returns (bool) {
        bool attesterRemoved = (attestersCommit > _node.attesterLastUpdateCommit)
            ? _node.attesterLatest.removed
            : _node.attesterSnapshot.removed;
        bool validatorRemoved = (validatorsCommit > _node.validatorLastUpdateCommit)
            ? _node.validatorLatest.removed
            : _node.validatorSnapshot.removed;
        return attesterRemoved && validatorRemoved;
    }

    function _deleteNode(address _nodeOwner, Node storage _node) private {
        // Delete from array by swapping the last node owner (gas-efficient, not preserving order).
        address lastNodeOwner = nodeOwners[nodeOwners.length - 1];
        nodeOwners[_node.nodeOwnerIdx] = lastNodeOwner;
        nodeOwners.pop();
        // Update the node owned by the last node owner.
        nodes[lastNodeOwner].nodeOwnerIdx = _node.nodeOwnerIdx;

        // Delete from the remaining mapping.
        delete attesterPubKeyHashes[_hashAttesterPubKey(_node.attesterLatest.pubKey)];
        delete validatorPubKeyHashes[_hashValidatorPubKey(_node.validatorLatest.pubKey)];
        delete nodes[_nodeOwner];

        emit NodeDeleted(_nodeOwner);
    }

    function _snapshotAttesterIfOutdated(Node storage _node) private {
        if (_node.attesterLastUpdateCommit < attestersCommit) {
            _node.attesterSnapshot = _node.attesterLatest;
            _node.attesterLastUpdateCommit = attestersCommit;
        }
    }

    function _snapshotValidatorIfOutdated(Node storage _node) private {
        if (_node.validatorLastUpdateCommit < validatorsCommit) {
            _node.validatorSnapshot = _node.validatorLatest;
            _node.validatorLastUpdateCommit = validatorsCommit;
        }
    }

    function _doesNodeOwnerExist(address _nodeOwner) private view returns (bool) {
        BLS12_381PublicKey storage pubKey = nodes[_nodeOwner].validatorLatest.pubKey;
        if (pubKey.a == bytes32(0) && pubKey.b == bytes32(0) && pubKey.c == bytes32(0)) {
            return false;
        }
        return true;
    }

    function _verifyNodeOwnerExists(address _nodeOwner) private view {
        if (!_doesNodeOwnerExist(_nodeOwner)) {
            revert NodeOwnerDoesNotExist();
        }
    }

    function _verifyNodeOwnerDoesNotExist(address _nodeOwner) private view {
        if (_doesNodeOwnerExist(_nodeOwner)) {
            revert NodeOwnerExists();
        }
    }

    function _hashAttesterPubKey(Secp256k1PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(_pubKey.tag, _pubKey.x));
    }

    function _hashAttesterPubKey(Secp256k1PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(_pubKey.tag, _pubKey.x));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _verifyInputAddress(address _nodeOwner) private pure {
        if (_nodeOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    function _verifyAttesterPubKeyDoesNotExist(bytes32 _hash) private view {
        if (attesterPubKeyHashes[_hash]) {
            revert AttesterPubKeyExists();
        }
    }

    function _verifyValidatorPubKeyDoesNotExist(bytes32 _hash) private {
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

    function _verifyInputSecp256k1PublicKey(Secp256k1PublicKey calldata _pubKey) private pure {
        if (_isEmptySecp256k1PublicKey(_pubKey)) {
            revert InvalidInputSecp256k1PublicKey();
        }
    }

    function _isEmptyBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bool) {
        return _pubKey.a == bytes32(0) && _pubKey.b == bytes32(0) && _pubKey.c == bytes32(0);
    }

    function _isEmptyBLS12_381Signature(BLS12_381Signature calldata _pop) private pure returns (bool) {
        return _pop.a == bytes32(0) && _pop.b == bytes16(0);
    }

    function _isEmptySecp256k1PublicKey(Secp256k1PublicKey calldata _pubKey) private pure returns (bool) {
        return _pubKey.tag == bytes1(0) && _pubKey.x == bytes32(0);
    }
}
