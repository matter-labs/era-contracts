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
        uint256 validatorWeight;
        // Validator's BLS12-381 public key.
        bytes validatorPubKey;
        // Validator's Proof-of-possession (a signature over the public key).
        bytes validatorPoP;
        // Attester's Voting weight.
        uint256 attesterWeight;
        // Attester's ECDSA public key.
        bytes attesterPubKey;
    }

    /// @dev Represents a validator committee member.
    struct CommitteeValidator {
        address nodeOwner;
        uint256 weight;
        bytes pubKey;
        bytes pop;
    }

    /// @dev Represents an attester committee member.
    struct CommitteeAttester {
        uint256 weight;
        address nodeOwner;
        bytes pubKey;
    }

    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyAlreadyExists();
    error AttesterPubKeyAlreadyExists();

    modifier onlyOwnerOrNodeOwner(address _nodeOwner) {
        if (owner() != msg.sender && _nodeOwner != msg.sender) {
            revert UnauthorizedOnlyOwnerOrNodeOwner();
        }
        _;
    }

    constructor(address _initialOwner) {
        require(_initialOwner != address(0), "_initialOwner should be non zero address");
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
        uint256 _validatorWeight,
        bytes calldata _validatorPubKey,
        bytes calldata _validatorPoP,
        uint256 _attesterWeight,
        bytes calldata _attesterPubKey
    ) external onlyOwner {
        require(_nodeOwner != address(0), "_nodeOwner address cannot be empty");
        require(_validatorPubKey.length > 0, "_validatorPubKey cannot be empty");
        require(_validatorPoP.length > 0, "_validatorPoP cannot be empty");
        require(_attesterPubKey.length > 0, "_attesterPubKey cannot be empty");

        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (nodeOwners[i] == _nodeOwner) {
                revert NodeOwnerAlreadyExists();
            }
            if (compareBytes(nodes[nodeOwners[i]].validatorPubKey, _validatorPubKey)) {
                revert ValidatorPubKeyAlreadyExists();
            }
            if (compareBytes(nodes[nodeOwners[i]].attesterPubKey, _attesterPubKey)) {
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
    }

    /// @notice Deactivates a node, preventing it from participating in committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be inactivated.
    function deactivate(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].active = false;
    }

    /// @notice Activates a previously inactive node, allowing it to participate in committees.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner to be activated.
    function activate(address _nodeOwner) external onlyOwnerOrNodeOwner(_nodeOwner) {
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].active = true;
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
    }

    /// @notice Changes the validator weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator weight will be changed.
    /// @param _weight The new validator weight to assign to the node.
    function changeValidatorWeight(address _nodeOwner, uint256 _weight) external onlyOwner {
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].validatorWeight = _weight;
    }

    /// @notice Changes the attester weight of a node in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester weight will be changed.
    /// @param _weight The new attester weight to assign to the node.
    function changeAttesterWeight(address _nodeOwner, uint256 _weight) external onlyOwner {
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].attesterWeight = _weight;
    }

    /// @notice Changes the validator's public key and proof-of-possession (PoP) in the registry.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose validator key and PoP will be changed.
    /// @param _pubKey The new BLS12-381 public key to assign to the node's validator.
    /// @param _pop The new proof-of-possession (PoP) to assign to the node's validator.
    function changeValidatorKey(
        address _nodeOwner,
        bytes calldata _pubKey,
        bytes calldata _pop
    ) external onlyOwnerOrNodeOwner(_nodeOwner) {
        require(_pubKey.length > 0, "_pubKey cannot be empty");
        require(_pop.length > 0, "_pop cannot be empty");
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].validatorPubKey = _pubKey;
        nodes[_nodeOwner].validatorPoP = _pop;
    }

    /// @notice Changes the attester's public key of a node in the registry.
    /// @dev Only callable by the contract owner or the node owner.
    /// @dev Verifies that the node owner exists in the registry.
    /// @param _nodeOwner The address of the node's owner whose attester public key will be changed.
    /// @param _pubKey The new ECDSA public key to assign to the node's attester.
    function changeAttesterPubKey(
        address _nodeOwner,
        bytes calldata _pubKey
    ) external onlyOwnerOrNodeOwner(_nodeOwner) {
        require(_pubKey.length > 0, "_pubKey cannot be empty");
        verifyNodeOwnerExists(_nodeOwner);
        nodes[_nodeOwner].attesterPubKey = _pubKey;
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
    }

    /// @notice Verifies that a node owner exists in the registry.
    /// @dev Throws an error if the node owner does not exist.
    /// @param _nodeOwner The address of the node's owner to verify.
    function verifyNodeOwnerExists(address _nodeOwner) private view {
        if (nodes[_nodeOwner].validatorPubKey.length == 0) {
            revert NodeOwnerDoesNotExist();
        }
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

    function numNodes() public view returns (uint256) {
        return nodeOwners.length;
    }

    function validatorCommitteeSize() public view returns (uint256) {
        return validatorCommittee.length;
    }

    function attesterCommitteeSize() public view returns (uint256) {
        return attesterCommittee.length;
    }

    function compareBytes(bytes storage a, bytes calldata b) private view returns (bool) {
        return keccak256(a) == EfficientCall.keccak(b);
    }
}
