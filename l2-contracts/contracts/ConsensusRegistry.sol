// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

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

    struct CommitteeValidator {
        address nodeOwner;
        uint256 weight;
        bytes pubKey;
        bytes pop;
    }

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

    // Adds a new node to the registry.
    // Fails if node owner already exists.
    // Fails if a validator with the same public key already exists.
    // Fails if an attester with the same public key already exists.
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
        nodes[nodeOwner] = Node(
            false,
            validatorWeight,
            validatorPubKey,
            validatorPoP,
            attesterWeight,
            attesterPubKey
        );
    }

    // Inactivates a node.
    function inactivate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].isInactive = true;
    }

    // Activates a node.
    function activate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].isInactive = false;
    }

    // Removes a node.
    function remove(address nodeOwner) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        nodeOwners[nodeOwnerIdx(nodeOwner)] = nodeOwners[nodeOwners.length - 1];
        nodeOwners.pop();
        // Remove from mapping.
        delete nodes[nodeOwner];
    }

    // Changes node's validator weight.
    function changeValidatorWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].validatorWeight = weight;
    }

    // Changes node's attester weight.
    function changeAttesterWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].attesterWeight = weight;
    }

    // Changes node's validator public key and PoP.
    function changeValidatorKey(address nodeOwner, bytes calldata pubKey, bytes calldata pop) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].validatorPubKey = pubKey;
        nodes[nodeOwner].validatorPoP = pop;
    }

    // Changes node's attester public key.
    function changeAttesterPubKey(address nodeOwner, bytes calldata pubKey) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        nodes[nodeOwner].attesterPubKey = pubKey;
    }

    // Rotates the validators committee list.
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

    // Rotates the attesters committee list.
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

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    // Verifies that a node owner exists.
    function verifyNodeOwnerExists(address nodeOwner) private view {
        if (nodes[nodeOwner].validatorPubKey.length == 0) {
            revert NodeOwnerDoesNotExist();
        }
    }

    // Finds the index of a node owner in the `nodeOwners` array.
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
}
