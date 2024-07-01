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
    // The committee list for the next epoch.
    CommitteeValidator[] public nextCommittee;

    // The current epoch number.
    uint256 public epoch;
    // The number of epochs that a validator must be inactive before being
    // possible to remove it. Needs to be at least 2, in order to guarantee
    // that any validator in the current or next committee lists is still
    // available in the registry.
    uint256 public constant INACTIVITY_DELAY = 2;

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
        // The epoch in which the validator became inactive. We need to store this since
        // we may want to impose a delay between a validator becoming inactive and
        // being able to be removed.
        uint256 inactiveSince;
    }

    struct CommitteeValidator {
        address nodeOwner;
        uint256 weight;
        bytes pubKey;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized: onlyOwner");
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
        for (uint256 i = 0; i < validatorOwners.length; i++) {
            require(validatorOwners[i] != nodeOwner, "nodeOwner already exists");
            require(!compareBytes(validators[validatorOwners[i]].pubKey, pubKey), "pubKey already exists");
        }

        verifyPoP(pubKey, pop);

        validators[nodeOwner] = Validator(weight, pubKey, pop, false, 0);
        validatorOwners.push(nodeOwner);
    }

    // Removes a validator. Should fail if the validator is still active or
    // the inactivity delay has not passed.
    function remove(address nodeOwner) public onlyOwner {
        verifyExists(nodeOwner);
        require(validators[nodeOwner].isInactive, "Validator is still active");
        require(epoch >= validators[nodeOwner].inactiveSince + INACTIVITY_DELAY,
            "Validator's inactivity delay has not passed"
        );

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
        validators[nodeOwner].inactiveSince = epoch;
    }

    // Activates a validator.
    function activate(address nodeOwner) public onlyOwner {
        verifyExists(nodeOwner);
        validators[nodeOwner].isInactive = false;
        validators[nodeOwner].inactiveSince = 0;
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
        verifyPoP(pubKey, pop);
        validators[nodeOwner].pubKey = pubKey;
        validators[nodeOwner].pop = pop;
    }

    // Creates a new committee list which will become the next committee list.
    function setNextCommittee() external onlyOwner {
        epoch += 1;

        // Replace current committee with next committee
        delete committee;
        for (uint256 i = 0; i < nextCommittee.length; i++) {
            committee.push(nextCommittee[i]);
        }

        // Populate `nextCommittee` based on active validators
        delete nextCommittee;
        for (uint256 i = 0; i < validatorOwners.length; i++) {
            Validator memory validator = validators[validatorOwners[i]];
            if (!validator.isInactive) {
                nextCommittee.push(CommitteeValidator(validatorOwners[i], validator.weight, validator.pubKey));
            }
        }
    }

    // Finds the index of a node owner in the `validatorOwners` array.
    function validatorOwnerIndex(address nodeOwner) private view returns (uint256) {
        for (uint256 i = 0; i < validatorOwners.length; i++) {
            if (validatorOwners[i] == nodeOwner) {
                return i;
            }
        }
        revert("nodeOwner not found");
    }

    // Verifies that a validator exists.
    function verifyExists(address nodeOwner) private view {
        require(validators[nodeOwner].pubKey.length != 0, "Validator doesn't exist");
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    // Verifies the proof-of-possession.
    function verifyPoP(bytes calldata pubKey, bytes calldata pop) internal pure {
        // TODO: implement or remove
    }

    function numValidators() public view returns (uint256) {
        return validatorOwners.length;
    }
}
