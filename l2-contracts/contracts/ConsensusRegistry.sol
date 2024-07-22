// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title ConsensusRegistry
/// @dev A contract to manage consensus nodes and committees.
contract ConsensusRegistry {
    // Owner of the contract (i.e., the governance contract).
    address public owner;
    // An array to keep track of node owners.
    address[] public nodeOwners;
    // A map of node owners => nodes
    mapping(address => Node) public nodes;
    // The current validator committee list.
    CommitteeValidator[] public validatorCommittee;
    // The current attester committee list.
    CommitteeAttester[] public attesterCommittee;

    /// @dev Represents a consensus node.
    struct Node {
        // A flag stating if the node is inactive.
        // Inactive nodes are not considered when selecting committees.
        bool isInactive;
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

    error UnauthorizedOnlyOwner();
    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyAlreadyExists();
    error AttesterPubKeyAlreadyExists();

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert UnauthorizedOnlyOwner();
        }
        _;
    }

    modifier onlyOwnerOrNodeOwner(address nodeOwner) {
        if (msg.sender != owner && msg.sender != nodeOwner) {
            revert UnauthorizedOnlyOwnerOrNodeOwner();
        }
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

/// @notice Adds a new node to the registry.
/// @dev Fails if node owner already exists.
/// @dev Fails if a validator with the same public key already exists.
/// @dev Fails if an attester with the same public key already exists.

/// @param nodeOwner The address of the new node's owner.
/// @param validatorWeight The voting weight of the validator.
/// @param validatorPubKey The BLS12-381 public key of the validator.
/// @param validatorPoP The proof-of-possession (PoP) of the validator's public key.
/// @param attesterWeight The voting weight of the attester.
/// @param attesterPubKey The ECDSA public key of the attester.
    function add(
        address nodeOwner,
        uint256 validatorWeight,
        bytes calldata validatorPubKey,
        bytes calldata validatorPoP,
        uint256 attesterWeight,
        bytes calldata attesterPubKey
    ) external onlyOwner {
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (nodeOwners[i] == nodeOwner) {
                revert NodeOwnerAlreadyExists();
            }
            if (compareBytes(nodes[nodeOwners[i]].validatorPubKey, validatorPubKey)) {
                revert ValidatorPubKeyAlreadyExists();
            }
            if (compareBytes(nodes[nodeOwners[i]].attesterPubKey, attesterPubKey)) {
                revert AttesterPubKeyAlreadyExists();
            }
        }

        nodeOwners.push(nodeOwner);
        nodes[nodeOwner] = Node({
            isInactive: false,
            validatorWeight: validatorWeight,
            validatorPubKey: validatorPubKey,
            validatorPoP: validatorPoP,
            attesterWeight: attesterWeight,
            attesterPubKey: attesterPubKey
        });
    }

/// @notice Deactivates a node, preventing it from participating in committees.
/// @dev Only callable by the contract owner or the node owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner to be inactivated.
    function deactivate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].isInactive = true;
    }

/// @notice Activates a previously inactive node, allowing it to participate in committees.
/// @dev Only callable by the contract owner or the node owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner to be activated.
    function activate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].isInactive = false;
    }

/// @notice Removes a node from the registry.
/// @dev Only callable by the contract owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner to be removed.
    function remove(address nodeOwner) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        nodeOwners[nodeOwnerIdx(nodeOwner)] = nodeOwners[nodeOwners.length - 1];
        nodeOwners.pop();
        // Remove from mapping.
        delete nodes[nodeOwner];
    }

/// @notice Changes the validator weight of a node in the registry.
/// @dev Only callable by the contract owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner whose validator weight will be changed.
/// @param weight The new validator weight to assign to the node.
    function changeValidatorWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].validatorWeight = weight;
    }

/// @notice Changes the attester weight of a node in the registry.
/// @dev Only callable by the contract owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner whose attester weight will be changed.
/// @param weight The new attester weight to assign to the node.
    function changeAttesterWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].attesterWeight = weight;
    }

/// @notice Changes the validator's public key and proof-of-possession (PoP) in the registry.
/// @dev Only callable by the contract owner or the node owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner whose validator key and PoP will be changed.
/// @param pubKey The new BLS12-381 public key to assign to the node's validator.
/// @param pop The new proof-of-possession (PoP) to assign to the node's validator.
    function changeValidatorKey(address nodeOwner, bytes calldata pubKey, bytes calldata pop) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].validatorPubKey = pubKey;
        nodes[nodeOwner].validatorPoP = pop;
    }

/// @notice Changes the attester's public key of a node in the registry.
/// @dev Only callable by the contract owner or the node owner.
/// @dev Verifies that the node owner exists in the registry.
///
/// @param nodeOwner The address of the node's owner whose attester public key will be changed.
/// @param pubKey The new ECDSA public key to assign to the node's attester.
    function changeAttesterPubKey(address nodeOwner, bytes calldata pubKey) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].attesterPubKey = pubKey;
    }

/// @notice Rotates the validator committee list based on active validators in the registry.
/// @dev Only callable by the contract owner.
    function setValidatorCommittee() external onlyOwner {
        // Creates a new committee based on active validators.
        delete validatorCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Node memory node = nodes[nodeOwner];
            if (!node.isInactive) {
                validatorCommittee.push(CommitteeValidator(
                    nodeOwner,
                    node.validatorWeight,
                    node.validatorPubKey,
                    node.validatorPoP
                ));
            }
        }
    }

/// @notice Rotates the attester committee list based on active attesters in the registry.
/// @dev Only callable by the contract owner.
    function setAttesterCommittee() external onlyOwner {
        // Creates a new committee based on active attesters.
        delete attesterCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Node memory node = nodes[nodeOwner];
            if (!node.isInactive) {
                attesterCommittee.push(CommitteeAttester(
                    node.attesterWeight,
                    nodeOwner,
                    node.attesterPubKey
                ));
            }
        }
    }

/// @notice Verifies that a node owner exists in the registry.
/// @dev Throws an error if the node owner does not exist.
///
/// @param nodeOwner The address of the node's owner to verify.
    function verifyNodeOwnerExists(address nodeOwner) private view {
        if (nodes[nodeOwner].validatorPubKey.length == 0) {
            revert NodeOwnerDoesNotExist();
        }
    }

/// @notice Finds the index of a node owner in the `nodeOwners` array.
/// @dev Throws an error if the node owner is not found in the array.
///
/// @param nodeOwner The address of the node's owner to find in the `nodeOwners` array.
/// @return The index of the node owner in the `nodeOwners` array.
    function nodeOwnerIdx(address nodeOwner) private view returns (uint256) {
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (nodeOwners[i] == nodeOwner) {
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

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }
}
