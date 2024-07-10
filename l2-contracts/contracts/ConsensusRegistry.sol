// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract ConsensusRegistry {
    // Owner of the contract (i.e., the governance contract).
    address public owner;
    // An array to keep track of validator node owners (used for iterating validators).
    address[] public nodeOwners;
    // A map of node owners => validators (used for validator lookups).
    mapping(address => Validator) public validators;
    // A map of node owners => attesters (used for attester lookups).
    mapping(address => Attester) public attesters;
    // The current committee list. Weight and public key are stored explicitly
    // since they might change after committee selection.
    CommitteeValidator[] public validatorsCommittee;
    // The current committee list. Weight and public key are stored explicitly
    // since they might change after committee selection.
    CommitteeAttester[] public attestersCommittee;

    struct Validator {
        // Voting weight.
        uint256 weight;
        // BLS12-381 public key.
        bytes pubKey;
        // Proof-of-possession (a signature over the public key).
        bytes pop;
        // A flag stating if the validator is inactive. Inactive validators are not
        // considered when selecting committees. Only inactive validators can
        // be removed from the registry.
        bool isInactive;
    }

    struct CommitteeValidator {
        address nodeOwner;
        uint256 weight;
        bytes pubKey;
    }

    struct CommitteeAttester {
        uint256 weight;
        address nodeOwner;
        bytes pubKey;
    }

    struct Attester {
        // Voting weight.
        uint256 weight;
        // ECDSA public key.
        bytes pubKey;
        // A flag stating if the attester is inactive. Inactive attesters are not
        // considered when selecting committees. Only inactive attesters can
        // be removed from the registry.
        bool isInactive;
    }

    error UnauthorizedOnlyOwner();
    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyAlreadyExists();
    error ValidatorIsActive();
    error AttesterPubKeyAlreadyExists();
    error AttesterIsActive();

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
            if (compareBytes(validators[nodeOwners[i]].pubKey, validatorPubKey)) {
                revert ValidatorPubKeyAlreadyExists();
            }
            if (compareBytes(attesters[nodeOwners[i]].pubKey, attesterPubKey)) {
                revert AttesterPubKeyAlreadyExists();
            }
        }

        nodeOwners.push(nodeOwner);
        validators[nodeOwner] = Validator(validatorWeight, validatorPubKey, validatorPoP, false);
        attesters[nodeOwner] = Attester(attesterWeight, attesterPubKey, false);
    }

    // Inactivates a node.
    function inactivate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        validators[nodeOwner].isInactive = true;
        attesters[nodeOwner].isInactive = true;
    }

    // Activates a node.
    function activate(address nodeOwner) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        validators[nodeOwner].isInactive = false;
        attesters[nodeOwner].isInactive = false;
    }

    // Removes a node.
    function remove(address nodeOwner) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        if (!attesters[nodeOwner].isInactive) {
            revert AttesterIsActive();
        }
        if (!validators[nodeOwner].isInactive) {
            revert ValidatorIsActive();
        }

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        nodeOwners[nodeOwnerIdx(nodeOwner)] = nodeOwners[nodeOwners.length - 1];
        nodeOwners.pop();
        // Remove from mapping.
        delete validators[nodeOwner];
        delete attesters[nodeOwner];
    }

    // Changes node's validator weight.
    function changeValidatorWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        validators[nodeOwner].weight = weight;
    }

    // Changes node's attester weight.
    function changeAttesterWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyNodeOwnerExists(nodeOwner);
        attesters[nodeOwner].weight = weight;
    }

    // Changes node's validator public key and PoP.
    function changeValidatorPubKey(address nodeOwner, bytes calldata pubKey, bytes calldata pop) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        validators[nodeOwner].pubKey = pubKey;
        validators[nodeOwner].pop = pop;
    }

    // Changes node's attester public key.
    function changeAttesterPubKey(address nodeOwner, bytes calldata pubKey) external onlyOwnerOrNodeOwner(nodeOwner) {
        verifyNodeOwnerExists(nodeOwner);
        attesters[nodeOwner].pubKey = pubKey;}

    // Rotates the validators committee list.
    function setValidatorCommittee() external onlyOwner {
        // Creates a new committee based on active validators.
        delete validatorsCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Validator memory validator = validators[nodeOwner];
            if (!validator.isInactive) {
                validatorsCommittee.push(CommitteeValidator(nodeOwner, validator.weight, validator.pubKey));
            }
        }
    }

    // Rotates the attesters committee list.
    function setAttesterCommittee() external onlyOwner {
        // Creates a new committee based on active attesters.
        delete attestersCommittee;
        uint256 len = nodeOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            address nodeOwner = nodeOwners[i];
            Attester memory attester = attesters[nodeOwner];
            if (!attester.isInactive) {
                attestersCommittee.push(CommitteeAttester(attester.weight, nodeOwner, attester.pubKey));
            }
        }
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    // Verifies that a node owner exists.
    function verifyNodeOwnerExists(address nodeOwner) private view {
        if (validators[nodeOwner].pubKey.length == 0) {
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

    function numCommitteeValidators() public view returns (uint256) {
        return validatorsCommittee.length;
    }

    function numCommitteeAttesters() public view returns (uint256) {
        return attestersCommittee.length;
    }
}
