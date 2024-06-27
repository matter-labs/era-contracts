// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract AttesterRegistry {
    // Owner of the contract (the Authority contract).
    address public owner;

    // A map of indexes => attesters (used for efficient lookups).
    mapping(uint256 => Attester) public attesters;
    // Array to keep track of attester indexes (used for iterations).
    uint256[] public attesterIndexes;
    // The last unique value used as an attester index (used for supporting arbitrary removals).
    uint256 public attesterSequence;

    // The current committee list. Weight and public key are stored explicitly
    // since they might change after committee selection.
    CommitteeAttester[] public committee;
    // The committee list for the next epoch.
    CommitteeAttester[] public nextCommittee;

    // The current epoch number.
    uint256 public epoch;
    // The number of epochs that an attester must be inactive before being
    // possible to remove it. Needs to be at least 2, in order to guarantee
    // that any attester in the current or next committee lists is still
    // available in the registry.
    uint256 public constant INACTIVITY_DELAY = 2;

    struct Attester {
        // Voting weight.
        uint256 weight;
        // ECDSA public key.
        bytes pubKey;
        // A flag stating if the attester is inactive. Inactive attesters are not
        // considered when selecting committees. Only inactive attesters can
        // be removed from the registry.
        bool isInactive;
        // The epoch in which the attester became inactive. We need to store this since
        // we may want to impose a delay between an attester becoming inactive and
        // being able to be removed.
        uint256 inactiveSince;
    }

    struct CommitteeAttester {
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

    // Adds a new attester to the registry. Fails if an attester with the
    // same public key already exists.
    function add(
        uint256 weight,
        bytes calldata pubKey
    ) external onlyOwner returns (uint256) {
        // Check if validator with the same public key already exists.
        for (uint256 i = 0; i < attesterIndexes.length; i++) {
            uint256 idx = attesterIndexes[i];
            require(!compareBytes(attesters[idx].pubKey, pubKey), "pubKey already exists");
        }

        attesterSequence++;
        uint256 idx = attesterSequence;
        attesters[idx] = Attester(weight, pubKey, false, 0);
        attesterIndexes.push(idx);
        return idx;
    }

    // Removes an attester. Should fail if the validator is still active or
    // the inactivity delay has not passed.
    function remove(uint256 idx) external onlyOwner {
        verifyExists(idx);
        require(attesters[idx].isInactive, "Attester is still active");
        require(epoch >= attesters[idx].inactiveSince + INACTIVITY_DELAY,
            "Attester's inactivity delay has not passed"
        );

        // Remove from mapping.
        delete attesters[idx];

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        uint256 offset = idxOffset(idx);
        attesterIndexes[offset] = attesterIndexes[attesterIndexes.length - 1];
        attesterIndexes.pop();
    }

    // Inactivates an attester.
    function inactivate(uint256 idx) external onlyOwner {
        verifyExists(idx);
        attesters[idx].isInactive = true;
        attesters[idx].inactiveSince = epoch;
    }

    // Activates an attester.
    function activate(uint256 idx) external onlyOwner {
        verifyExists(idx);
        attesters[idx].isInactive = false;
    }

    // Changes the weight.
    function changeWeight(uint256 idx, uint256 weight) external onlyOwner {
        verifyExists(idx);
        attesters[idx].weight = weight;
    }

    // Changes the public key.
    function changePublicKey(
        uint256 idx,
        bytes calldata pubKey
    ) external onlyOwner {
        verifyExists(idx);
        attesters[idx].pubKey = pubKey;
    }

    // Creates a new committee list which will become the next committee list.
    function setNextCommittee() external onlyOwner {
        epoch += 1;

        // Replace current committee with next committee.
        delete committee;
        for (uint256 i = 0; i < nextCommittee.length; i++) {
            committee.push(nextCommittee[i]);
        }

        // Populate `nextCommittee` based on active attesters.
        delete nextCommittee;
        for (uint256 i = 0; i < attesterIndexes.length; i++) {
            uint256 idx = attesterIndexes[i];
            Attester memory attester = attesters[idx];
            if (!attester.isInactive) {
                nextCommittee.push(CommitteeAttester(idx, attester.weight, attester.pubKey));
            }
        }
    }

    // Finds the index offset of an attester in the `attesterIndexes` array.
    function idxOffset(uint256 idx) internal view returns (uint256) {
        for (uint256 i = 0; i < attesterIndexes.length; i++) {
            if (attesterIndexes[i] == idx) {
                return i;
            }
        }
        revert("Attester index not found");
    }

    // Verifies that an attester exists.
    function verifyExists(uint256 idx) internal view {
        require(attesters[idx].pubKey.length != 0, "Attester doesn't exist");
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }
}
