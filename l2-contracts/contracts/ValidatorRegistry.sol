// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract ValidatorRegistry {
    // Owner of the contract (the ConsensusAuthority contract).
    address public owner;
    // A map of node owners => validators (used for validator lookups).
    mapping(address => Validator) public validators;
    // An array to keep track of validator node owners (used for iterating validators).
    address[] public validatorOwners;
    // The current committee list. Weight and public key are stored explicitly
    // since they might change after committee selection.
    CommitteeValidator[] public committee;

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

    error UnauthorizedOnlyOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerNotFound();
    error PubKeyAlreadyExists();
    error ValidatorDoesNotExist();
    error ValidatorIsActive();

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert UnauthorizedOnlyOwner();
        }
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    // Adds a new validator to the registry. Fails if a validator with the
    // same public key already exists. Has to verify the PoP.
    function add(
        address nodeOwner,
        uint256 weight,
        bytes calldata pubKey,
        bytes calldata pop
    ) public onlyOwner {
        // Check if a validator with the same node owner or public key already exists.
        uint256 len = validatorOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (validatorOwners[i] == nodeOwner) {
                revert NodeOwnerAlreadyExists();
            }
            if (compareBytes(validators[validatorOwners[i]].pubKey, pubKey)) {
                revert PubKeyAlreadyExists();
            }
        }

        validators[nodeOwner] = Validator(weight, pubKey, pop, false);
        validatorOwners.push(nodeOwner);
    }

    // Removes a validator. Should fail if the validator is still active or
    // the inactivity delay has not passed.
    function remove(address nodeOwner) public onlyOwner {
        verifyExists(nodeOwner);
        if (!validators[nodeOwner].isInactive) {
            revert ValidatorIsActive();
        }

        // Remove from mapping.
        delete validators[nodeOwner];

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        validatorOwners[validatorOwnerIndex(nodeOwner)] = validatorOwners[validatorOwners.length - 1];
        validatorOwners.pop();
    }

    // Inactivates a validator.
    function inactivate(address nodeOwner) public onlyOwner {
        verifyExists(nodeOwner);
        validators[nodeOwner].isInactive = true;
    }

    // Activates a validator.
    function activate(address nodeOwner) public onlyOwner {
        verifyExists(nodeOwner);
        validators[nodeOwner].isInactive = false;
    }

    // Changes the weight.
    function changeWeight(address nodeOwner, uint256 weight) public onlyOwner {
        verifyExists(nodeOwner);
        validators[nodeOwner].weight = weight;
    }

    // Changes the public key and PoP.
    function changePublicKey(
        address nodeOwner,
        bytes calldata pubKey,
        bytes calldata pop
    ) public onlyOwner {
        verifyExists(nodeOwner);
        validators[nodeOwner].pubKey = pubKey;
        validators[nodeOwner].pop = pop;
    }

    // Creates a new committee list.
    function setCommittee() external onlyOwner {
        // Creates a new committee based on active validators.
        delete committee;
        uint256 len = validatorOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            Validator memory validator = validators[validatorOwners[i]];
            if (!validator.isInactive) {
                committee.push(CommitteeValidator(validatorOwners[i], validator.weight, validator.pubKey));
            }
        }
    }

    // Finds the index of a node owner in the `validatorOwners` array.
    function validatorOwnerIndex(address nodeOwner) private view returns (uint256) {
        uint256 len = validatorOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (validatorOwners[i] == nodeOwner) {
                return i;
            }
        }
        revert NodeOwnerNotFound();
    }

    // Verifies that a validator exists.
    function verifyExists(address nodeOwner) private view {
        if (validators[nodeOwner].pubKey.length == 0) {
            revert ValidatorDoesNotExist();
        }
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    function numValidators() public view returns (uint256) {
        return validatorOwners.length;
    }

    function numCommitteeValidators() public view returns (uint256) {
        return committee.length;
    }
}
