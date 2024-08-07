// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EfficientCall} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/EfficientCall.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry
/// @dev Manages consensus nodes and committees for the L2 consensus protocol,
/// owned by a governance protocol. Nodes act as both validators and attesters,
/// each playing a distinct role in the consensus process. This contract facilitates
/// the rotation of validator and attester committees, which represent a subset of nodes
/// expected to actively participate in the consensus process during a specific time window.
contract ConsensusRegistry is Ownable2Step {
    // An array to keep track of node owners.
    address[] public nodeOwners;
    // A map of node owners => nodes.
    mapping(address => Node) public nodes;
    // The current validator committee list.
    CommitteeValidator[] public validatorCommittee;
    // The current attester committee list.
    CommitteeAttester[] public attesterCommittee;

    /// @dev Represents a consensus node.
    struct Node {
        // A flag stating if the node is active.
        // Inactive nodes are not considered when selecting committees.
        bool active;
        // Validator's voting weight.
        uint32 validatorWeight;
        // Validator's BLS12-381 public key.
        BLS12_381PublicKey validatorPubKey;
        // Validator's Proof-of-possession (a signature over the public key).
        BLS12_381Signature validatorPoP;
        // Attester's Voting weight.
        uint32 attesterWeight;
        // Attester's Secp256k1 public key.
        Secp256k1PublicKey attesterPubKey;
    }

    /// @dev Represents BLS12_381 public key.
    struct BLS12_381PublicKey {
        bytes32 a;
        bytes32 b;
        bytes32 c;
    }

    /// @dev Represents BLS12_381 signature.
    struct BLS12_381Signature {
        bytes32 a;
        bytes16 b;
    }

    /// @dev Represents Secp256k1 public key.
    struct Secp256k1PublicKey {
        bytes1 a;
        bytes32 b;
    }

    /// @dev Represents a validator committee member.
    struct CommitteeValidator {
        address nodeOwner;
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature pop;
    }

    /// @dev Represents an attester committee member.
    struct CommitteeAttester {
        uint32 weight;
        address nodeOwner;
        Secp256k1PublicKey pubKey;
    }

    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyAlreadyExists();
    error AttesterPubKeyAlreadyExists();
    error InvalidInputNodeOwnerAddress();
    error InvalidInputBLS12_381PublicKey();
    error InvalidInputBLS12_381Signature();
    error InvalidInputSecp256k1PublicKey();

    event NodeAdded(address indexed nodeOwner, uint32 validatorWeight, BLS12_381PublicKey validatorPubKey, BLS12_381Signature validatorPoP, uint32 attesterWeight, Secp256k1PublicKey attesterPubKey);
    event NodeDeactivated(address indexed nodeOwner);
    event NodeActivated(address indexed nodeOwner);
    event NodeRemoved(address indexed nodeOwner);
    event NodeValidatorWeightChanged(address indexed nodeOwner, uint32 newWeight);
    event NodeAttesterWeightChanged(address indexed nodeOwner, uint32 newWeight);
    event NodeValidatorPubKeyChanged(address indexed nodeOwner, BLS12_381PublicKey newPubKey);
    event NodeValidatorPoPChanged(address indexed nodeOwner, BLS12_381Signature newPoP);
    event NodeAttesterPubKeyChanged(address indexed nodeOwner, Secp256k1PublicKey newPubKey);
    event ValidatorCommitteeSet();
    event AttesterCommitteeSet();

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
        verifyInputAddress(_nodeOwner);
        verifyInputBLS12_381PublicKey(_validatorPubKey);
        verifyInputBLS12_381Signature(_validatorPoP);
        verifyInputSecp256k1PublicKey(_attesterPubKey);

        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (nodeOwners[i] == _nodeOwner) {
                revert NodeOwnerAlreadyExists();
            }
            if (compareBLS12_381PublicKey(nodes[nodeOwners[i]].validatorPubKey, _validatorPubKey)) {
                revert ValidatorPubKeyAlreadyExists();
            }
            if (compareSecp256k1PublicKey(nodes[nodeOwners[i]].attesterPubKey, _attesterPubKey)) {
                revert AttesterPubKeyAlreadyExists();
            }
        }

        nodeOwners.push(_nodeOwner);
        nodes[_nodeOwner] = Node({
            active: true,
            validatorWeight: _validatorWeight,
            validatorPubKey: _validatorPubKey,
            validatorPoP: _validatorPoP,
            attesterWeight: _attesterWeight,
            attesterPubKey: _attesterPubKey
        });

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
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].active = false;

        emit NodeDeactivated(_nodeOwner);
    }

    /// @notice Activates a previously inactive node, allowing it to participate in committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be activated.
    function activate(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].active = true;

        emit NodeActivated(_nodeOwner);
    }

    /// @notice Removes a node from the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be removed.
    function remove(address _nodeOwner) external onlyOwner {
        verifyNodeOwnerExists(_nodeOwner);

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        nodeOwners[nodeOwnerIdx(_nodeOwner)] = nodeOwners[nodeOwners.length - 1];
        nodeOwners.pop();
        // Remove from mapping.
        delete nodes[_nodeOwner];

        emit NodeRemoved(_nodeOwner);
    }

    /// @notice Changes the validator weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator weight will be changed.
    /// @param _weight The new validator weight to assign to the node.
    function changeValidatorWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].validatorWeight = _weight;

        emit NodeValidatorWeightChanged(_nodeOwner, _weight);
    }

    /// @notice Changes the attester weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester weight will be changed.
    /// @param _weight The new attester weight to assign to the node.
    function changeAttesterWeight(address _nodeOwner, uint32 _weight) external onlyOwner {
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].attesterWeight = _weight;

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
        verifyInputBLS12_381PublicKey(_pubKey);
        verifyInputBLS12_381Signature(_pop);
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].validatorPubKey = _pubKey;
        nodes[_nodeOwner].validatorPoP = _pop;

        emit NodeValidatorPubKeyChanged(_nodeOwner, _pubKey);
        emit NodeValidatorPoPChanged(_nodeOwner, _pop);
    }

    /// @notice Changes the attester's public key of a node in the registry.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester public key will be changed.
    /// @param _pubKey The new ECDSA public key to assign to the node's attester.
    function changeAttesterPubKey(
        address _nodeOwner,
        Secp256k1PublicKey calldata _pubKey
    ) external onlyOwnerOrNodeOwner(_nodeOwner) {
        verifyInputSecp256k1PublicKey(_pubKey);
        verifyNodeOwnerExists(_nodeOwner);

        nodes[_nodeOwner].attesterPubKey = _pubKey;

        emit NodeAttesterPubKeyChanged(_nodeOwner, _pubKey);
    }

    /// @notice Rotates the validator committee list based on active nodes in the registry.
    /// @dev Only callable by the contract owner.
    function setValidatorCommittee() external onlyOwner {
        // Creates a new committee based on active validators.
        delete validatorCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Node memory node = nodes[nodeOwner];
            if (node.active) {
                validatorCommittee.push(
                    CommitteeValidator(nodeOwner, node.validatorWeight, node.validatorPubKey, node.validatorPoP)
                );
            }
        }

        emit ValidatorCommitteeSet();
    }

    /// @notice Rotates the attester committee list based on active nodes in the registry.
    /// @dev Only callable by the contract owner.
    function setAttesterCommittee() external onlyOwner {
        // Creates a new committee based on active attesters.
        delete attesterCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Node memory node = nodes[nodeOwner];
            if (node.active) {
                attesterCommittee.push(CommitteeAttester(node.attesterWeight, nodeOwner, node.attesterPubKey));
            }
        }

        emit AttesterCommitteeSet();
    }

    /// @notice Finds the index of a node owner in the `nodeOwners` array.
    /// @dev Throws an error if the node owner is not found in the array.
    /// @param _nodeOwner The address of the node's owner to find in the `nodeOwners` array.
    /// @return The index of the node owner in the `nodeOwners` array.
    function nodeOwnerIdx(address _nodeOwner) private view returns (uint256) {
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (nodeOwners[i] == _nodeOwner) {
                return i;
            }
        }
        revert NodeOwnerNotFound();
    }

    /// @notice Verifies that a node owner exists in the registry.
    /// @dev Throws an error if the node owner does not exist.
    /// @param _nodeOwner The address of the node's owner to verify.
    function verifyNodeOwnerExists(address _nodeOwner) private view {
        BLS12_381PublicKey storage pubKey = nodes[_nodeOwner].validatorPubKey;
        if (
            pubKey.a == bytes32(0) &&
            pubKey.b == bytes32(0) &&
            pubKey.c == bytes32(0)
        ) {
            revert NodeOwnerDoesNotExist();
        }
    }

    function verifyInputAddress(address _nodeOwner) private pure {
        if (_nodeOwner == address(0)) {
            revert InvalidInputNodeOwnerAddress();
        }
    }

    function verifyInputBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure {
        if (isEmptyBLS12_381PublicKey(_pubKey)) {
            revert InvalidInputBLS12_381PublicKey();
        }
    }

    function verifyInputBLS12_381Signature(BLS12_381Signature calldata _pop) private pure {
        if (isEmptyBLS12_381Signature(_pop)) {
            revert InvalidInputBLS12_381Signature();
        }
    }

    function verifyInputSecp256k1PublicKey(Secp256k1PublicKey calldata _pubKey) private pure {
        if (isEmptySecp256k1PublicKey(_pubKey)) {
            revert InvalidInputSecp256k1PublicKey();
        }
    }

    function compareSecp256k1PublicKey(Secp256k1PublicKey storage x, Secp256k1PublicKey calldata y) private view returns (bool) {
        return
            x.a == y.a &&
            x.b == y.b;
    }

    function compareBLS12_381PublicKey(BLS12_381PublicKey storage x, BLS12_381PublicKey calldata y) private view returns (bool) {
        return
            x.a == y.a &&
            x.b == y.b &&
            x.c == y.c;
    }

    function isEmptyBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bool) {
        return
            _pubKey.a == bytes32(0) &&
            _pubKey.b == bytes32(0) &&
            _pubKey.c == bytes32(0);
    }

    function isEmptyBLS12_381Signature(BLS12_381Signature calldata _pop) private pure returns (bool) {
        return
            _pop.a == bytes32(0) &&
            _pop.b == bytes16(0);
    }

    function isEmptySecp256k1PublicKey(Secp256k1PublicKey calldata _pubKey) private pure returns (bool) {
        return
            _pubKey.a == bytes1(0) &&
            _pubKey.b == bytes32(0);
    }

    function numNodes() public view returns (uint256) {
        return nodeOwners.length;
    }

    function validatorCommitteeSize() public view returns (uint256) {
        return validatorCommittee.length;
    }

    function attesterCommitteeSize() public view returns (uint256) {
        return attesterCommittee.length;
    }
}
