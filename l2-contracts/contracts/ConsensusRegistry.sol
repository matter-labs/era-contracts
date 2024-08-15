// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EfficientCall} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/EfficientCall.sol";
import {IConsensusRegistry} from "./interfaces/IConsensusRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry
/// @dev Manages consensus nodes and committees for the L2 consensus protocol,
/// owned by Matter Labs Multisig. Nodes act as both validators and attesters,
/// each playing a distinct role in the consensus process. This contract facilitates
/// the rotation of validator and attester committees, which represent a subset of nodes
/// expected to actively participate in the consensus process during a specific time window.
contract ConsensusRegistry is IConsensusRegistry, Ownable2Step {
    /// @dev An array to keep track of node owners.
    address[] public nodeOwners;
    /// @dev A mapping of node owners => nodes.
    mapping(address => Node) public nodes;
    /// @dev A mapping for enabling efficient lookups when checking whether a given attester public key exists.
    mapping(bytes32 => bool) attesterPubKeyHashes;
    /// @dev A mapping for enabling efficient lookups when checking whether a given validator public key exists.
    mapping(bytes32 => bool) validatorPubKeyHashes;
    /// @dev Counter that increments with each new commit to the attester committee.
    uint256 attestersCommit;
    /// @dev Counter that increments with each new commit to the validator committee.
    uint256 validatorsCommit;

    modifier onlyOwnerOrNodeOwner(address _nodeOwner) {
        if (owner() != msg.sender && _nodeOwner != msg.sender) {
            revert UnauthorizedOnlyOwnerOrNodeOwner();
        }
        _;
    }

    constructor(address _initialOwner) {
        if (_initialOwner == address(0)) {
            revert InvalidInputNodeOwnerAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Adds a new node to the registry.
    /// @dev Fails if node owner already exists.
    /// @dev Fails if a validator with the same public key already exists.
    /// @dev Fails if an attester with the same public key already exists.
    /// @param _nodeOwner The address of the new node's owner.
    /// @param _validatorWeight The voting weight of the validator.
    /// @param _validatorPubKey The BLS12-381 public key of the validator.
    /// @param _validatorPoP The proof-of-possession (PoP) of the validator's public key.
    /// @param _attesterWeight The voting weight of the attester.
    /// @param _attesterPubKey The ECDSA public key of the attester.
    function add(
        address _nodeOwner,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP,
        uint32 _attesterWeight,
        Secp256k1PublicKey calldata _attesterPubKey
    ) external onlyOwner {
        // Verify input.
        _verifyInputAddress(_nodeOwner);
        _verifyInputBLS12_381PublicKey(_validatorPubKey);
        _verifyInputBLS12_381Signature(_validatorPoP);
        _verifyInputSecp256k1PublicKey(_attesterPubKey);

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
            active: true,
            pendingRemoval: false,
            weight: _attesterWeight,
            pubKey: _attesterPubKey
        }),
            attesterSnapshot: AttesterAttr({
            active: false,
            pendingRemoval: false,
            weight: 0,
            pubKey: Secp256k1PublicKey({tag: bytes1(0), x: bytes32(0)})
        }),
            attesterLastUpdateCommit: attestersCommit,
            validatorLatest: ValidatorAttr({
            active: true,
            pendingRemoval: false,
            weight: _validatorWeight,
            pubKey: _validatorPubKey,
            pop: _validatorPoP
        }),
            validatorSnapshot: ValidatorAttr({
            active: false,
            pendingRemoval: false,
            weight: 0,
            pubKey: BLS12_381PublicKey({a: bytes32(0), b: bytes32(0), c: bytes32(0)}),
            pop: BLS12_381Signature({a: bytes32(0), b: bytes16(0)})
        }),
            validatorLastUpdateCommit: validatorsCommit,
            nodeOwnerIdx: nodeOwnerIdx
        });
        attesterPubKeyHashes[attesterPubKeyHash] = true;
        validatorPubKeyHashes[validatorPubKeyHash] = true;

        emit NodeAdded(
            _nodeOwner,
            _validatorWeight,
            _validatorPubKey,
            _validatorPoP,
            _attesterWeight,
            _attesterPubKey
        );
    }

    /// @notice Deactivates a node, preventing it from participating in committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be inactivated.
    function deactivate(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        _ensureAttesterSnapshot(node);
        node.attesterLatest.active = false;
        _ensureValidatorSnapshot(node);
        node.validatorLatest.active = false;

        emit NodeDeactivated(_nodeOwner);
    }

    /// @notice Activates a previously inactive node, allowing it to participate in committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be activated.
    function activate(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        _ensureAttesterSnapshot(node);
        node.attesterLatest.active = true;
        _ensureValidatorSnapshot(node);
        node.validatorLatest.active = true;

        emit NodeActivated(_nodeOwner);
    }

    /// @notice Removes a node from the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be removed.
    function remove(address _nodeOwner) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];

        _ensureAttesterSnapshot(node);
        node.attesterLatest.pendingRemoval = true;
        _ensureValidatorSnapshot(node);
        node.validatorLatest.pendingRemoval = true;

        emit NodeRemoved(_nodeOwner);
    }

    /// @notice Changes the validator weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator weight will be changed.
    /// @param _weight The new validator weight to assign to the node.
    function changeValidatorWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        _ensureValidatorSnapshot(node);
        node.validatorLatest.weight = _weight;

        emit NodeValidatorWeightChanged(_nodeOwner, _weight);
    }

    /// @notice Changes the attester weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester weight will be changed.
    /// @param _weight The new attester weight to assign to the node.
    function changeAttesterWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        _ensureAttesterSnapshot(node);
        node.attesterLatest.weight = _weight;

        emit NodeAttesterWeightChanged(_nodeOwner, _weight);
    }

    /// @notice Changes the validator's public key and proof-of-possession (PoP) in the registry.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator key and PoP will be changed.
    /// @param _pubKey The new BLS12-381 public key to assign to the node's validator.
    /// @param _pop The new proof-of-possession (PoP) to assign to the node's validator.
    function changeValidatorKey(
        address _nodeOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyInputBLS12_381PublicKey(_pubKey);
        _verifyInputBLS12_381Signature(_pop);
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        bytes32 prevHash = _hashValidatorPubKey(node.validatorLatest.pubKey);
        delete validatorPubKeyHashes[prevHash];
        bytes32 newHash = _hashValidatorPubKey(_pubKey);
        validatorPubKeyHashes[newHash] = true;

        _ensureValidatorSnapshot(node);
        node.validatorLatest.pubKey = _pubKey;
        node.validatorLatest.pop = _pop;

        emit NodeValidatorKeyChanged(_nodeOwner, _pubKey, _pop);
    }

    /// @notice Changes the attester's public key of a node in the registry.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester public key will be changed.
    /// @param _pubKey The new ECDSA public key to assign to the node's attester.
    function changeAttesterKey(
        address _nodeOwner,
        Secp256k1PublicKey calldata _pubKey
    ) external onlyOwnerOrNodeOwner(_nodeOwner) {
        _verifyInputSecp256k1PublicKey(_pubKey);
        _verifyNodeOwnerExists(_nodeOwner);
        Node storage node = nodes[_nodeOwner];
        if (_finalizeNodeRemoval(_nodeOwner, node)) {
            return;
        }

        bytes32 prevHash = _hashAttesterPubKey(node.attesterLatest.pubKey);
        delete attesterPubKeyHashes[prevHash];
        bytes32 newHash = _hashAttesterPubKey(_pubKey);
        attesterPubKeyHashes[newHash] = true;

        _ensureAttesterSnapshot(node);
        node.attesterLatest.pubKey = _pubKey;

        emit NodeAttesterKeyChanged(_nodeOwner, _pubKey);
    }

    /// @notice Adds a new commit to the validator committee.
    /// @dev Implicitly updates the validator committee by affecting off-chain readers based on the current state of a node's validator attributes:
    /// - If "validatorsCommit" > "node.validatorLastUpdateCommit", read "node.validatorLatest".
    /// - If "validatorsCommit" == "node.validatorLastUpdateCommit", read "node.validatorSnapshot".
    /// @dev Only callable by the contract owner.
    function commitValidators() external onlyOwner {
        validatorsCommit++;

        emit ValidatorsCommitted();
    }

    /// @notice Adds a new commit to the attester committee.
    /// @dev Implicitly updates the attester committee by affecting off-chain readers based on the current state of a node's attester attributes:
    /// - If "attestersCommit" > "node.attesterLastUpdateCommit", read "node.attesterLatest".
    /// - If "attestersCommit" == "node.attesterLastUpdateCommit", read "node.attesterSnapshot".
    /// @dev Only callable by the contract owner.
    function commitAttesters() external onlyOwner {
        attestersCommit++;

        emit AttestersCommitted();
    }

    function numNodes() public view returns (uint256) {
        return nodeOwners.length;
    }

    function _finalizeNodeRemoval(address _nodeOwner, Node storage _node) private returns (bool) {
        if (
            _node.attesterSnapshot.pendingRemoval &&
            _node.validatorSnapshot.pendingRemoval
        ) {
            // Remove from array by swapping the last node owner (gas-efficient, not preserving order).
            address lastNodeOwner = nodeOwners[nodeOwners.length - 1];
            nodeOwners[_node.nodeOwnerIdx] = lastNodeOwner;
            nodeOwners.pop();
            // Update the node owned by the last node owner.
            nodes[lastNodeOwner].nodeOwnerIdx = _node.nodeOwnerIdx;

            // Delete from the remaining mapping.
            delete nodes[_nodeOwner];
            delete attesterPubKeyHashes[_hashAttesterPubKey(_node.attesterLatest.pubKey)];
            delete validatorPubKeyHashes[_hashValidatorPubKey(_node.validatorLatest.pubKey)];

            return true;
        }
        return false;
    }

    function _ensureAttesterSnapshot(Node storage _node) private {
        if (_node.attesterLastUpdateCommit < attestersCommit) {
            _node.attesterSnapshot = _node.attesterLatest;
            _node.attesterLastUpdateCommit = attestersCommit;
        }
    }

    function _ensureValidatorSnapshot(Node storage _node) private {
        if (_node.validatorLastUpdateCommit < validatorsCommit) {
            _node.validatorSnapshot = _node.validatorLatest;
            _node.validatorLastUpdateCommit = validatorsCommit;
        }
    }

    function _isNodeOwnerExists(address _nodeOwner) private view returns (bool) {
        BLS12_381PublicKey storage pubKey = nodes[_nodeOwner].validatorLatest.pubKey;
        if (
            pubKey.a == bytes32(0) &&
            pubKey.b == bytes32(0) &&
            pubKey.c == bytes32(0)
        ) {
            return false;
        }
        return true;
    }

    function _verifyNodeOwnerExists(address _nodeOwner) private view {
        if (!_isNodeOwnerExists(_nodeOwner)) {
            revert NodeOwnerDoesNotExist();
        }
    }

    function _verifyNodeOwnerDoesNotExist(address _nodeOwner) private view {
        if (_isNodeOwnerExists(_nodeOwner)) {
            revert NodeOwnerExists();
        }
    }

    function _hashAttesterPubKey(Secp256k1PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(
            _pubKey.tag,
            _pubKey.x
        ));
    }

    function _hashAttesterPubKey(Secp256k1PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(
            _pubKey.tag,
            _pubKey.x
        ));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(
            _pubKey.a,
            _pubKey.b,
            _pubKey.c
        ));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(
            _pubKey.a,
            _pubKey.b,
            _pubKey.c
        ));
    }

    function _verifyInputAddress(address _nodeOwner) private pure {
        if (_nodeOwner == address(0)) {
            revert InvalidInputNodeOwnerAddress();
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
        return
            _pubKey.a == bytes32(0) &&
            _pubKey.b == bytes32(0) &&
            _pubKey.c == bytes32(0);
    }

    function _isEmptyBLS12_381Signature(BLS12_381Signature calldata _pop) private pure returns (bool) {
        return
            _pop.a == bytes32(0) &&
            _pop.b == bytes16(0);
    }

    function _isEmptySecp256k1PublicKey(Secp256k1PublicKey calldata _pubKey) private pure returns (bool) {
        return
            _pubKey.tag == bytes1(0) &&
            _pubKey.x == bytes32(0);
    }
}
