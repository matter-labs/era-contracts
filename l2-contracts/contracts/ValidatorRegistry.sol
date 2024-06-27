// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract ValidatorRegistry {
    // Owner of the contract (the Authority contract).
    address public owner;

    // A map of indexes => validators (used for efficient lookups).
    mapping(uint256 => Validator) public validators;
    // Array to keep track of validator indexes (used for iterations).
    uint256[] public validatorIndexes;
    // The last unique value used as a validator index (used for supporting arbitrary removals).
    uint256 public validatorSequence;

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
        uint256 idx;
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
        uint256 weight,
        bytes calldata pubKey,
        bytes calldata pop
    ) public onlyOwner returns (uint256) {
        // Check if validator with the same public key already exists.
        for (uint256 i = 0; i < validatorIndexes.length; i++) {
            uint256 idx = validatorIndexes[i];
            require(!compareBytes(validators[idx].pubKey, pubKey), "pubKey already exists");
        }

        verifyPoP(pubKey, pop);

        validatorSequence++;
        uint256 idx = validatorSequence;
        validators[idx] = Validator(weight, pubKey, pop, false, 0);
        validatorIndexes.push(idx);
        return idx;
    }

    // Removes a validator. Should fail if the validator is still active or
    // the inactivity delay has not passed.
    function remove(uint256 idx) public onlyOwner {
        verifyExists(idx);
        require(validators[idx].isInactive, "Validator is still active");
        require(epoch >= validators[idx].inactiveSince + INACTIVITY_DELAY,
            "Validator's inactivity delay has not passed"
        );

        // Remove from mapping.
        delete validators[idx];

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        uint256 offset = idxOffset(idx);
        validatorIndexes[offset] = validatorIndexes[validatorIndexes.length - 1];
        validatorIndexes.pop();
    }

    // Inactivates a validator.
    function inactivate(uint256 idx) public onlyOwner {
        verifyExists(idx);
        validators[idx].isInactive = true;
        validators[idx].inactiveSince = epoch;
    }

    // Activates a validator.
    function activate(uint256 idx) public onlyOwner {
        verifyExists(idx);
        validators[idx].isInactive = false;
    }

    // Changes the weight.
    function changeWeight(uint256 idx, uint256 weight) public onlyOwner {
        verifyExists(idx);
        validators[idx].weight = weight;
    }

    // Changes the public key and PoP.
    function changePublicKey(
        uint256 idx,
        bytes calldata pubKey,
        bytes calldata pop
    ) public onlyOwner {
        verifyExists(idx);
        verifyPoP(pubKey, pop);
        validators[idx].pubKey = pubKey;
        validators[idx].pop = pop;
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
        for (uint256 i = 0; i < validatorIndexes.length; i++) {
            uint256 idx = validatorIndexes[i];
            Validator memory validator = validators[idx];
            if (!validator.isInactive) {
                nextCommittee.push(CommitteeValidator(idx, validator.weight, validator.pubKey));
            }
        }
    }

    // Finds the index offset of a validator in the `validatorIndexes` array.
    function idxOffset(uint256 idx) private view returns (uint256) {
        for (uint256 i = 0; i < validatorIndexes.length; i++) {
            if (validatorIndexes[i] == idx) {
                return i;
            }
        }
        revert("Validator idx not found");
    }

    // Verifies that a validator exists.
    function verifyExists(uint256 idx) private view {
        require(validators[idx].pubKey.length != 0, "Validator doesn't exist");
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    // Verifies the proof-of-possession.
    function verifyPoP(bytes calldata pubKey, bytes calldata pop) internal pure {
        // TODO: implement or remove
    }
}
