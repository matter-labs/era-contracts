// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract AttesterRegistry {
    // Owner of the contract (the ConsensusAuthority contract).
    address public owner;
    // A map of node owners => attesters (used for attester lookups).
    mapping(address => Attester) public attesters;
    // An array to keep track of attester node owners (used for iterating attesters).
    address[] public attesterOwners;
    // The current committee list. Weight and public key are stored explicitly
    // since they might change after committee selection.
    CommitteeAttester[] public committee;

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

    struct CommitteeAttester {
        uint256 weight;
        address nodeOwner;
        bytes pubKey;
    }

    error UnauthorizedOnlyOwner();
    error NodeOwnerAlreadyExists();
    error NodeOwnerNotFound();
    error PubKeyAlreadyExists();
    error AttesterDoesNotExist();
    error AttesterIsActive();

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert UnauthorizedOnlyOwner();
        }
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    // Adds a new attester to the registry. Fails if an attester with the
    // same public key already exists.
    function add(
        address nodeOwner,
        uint256 weight,
        bytes calldata pubKey
    ) external onlyOwner {
        // Check if an attester with the same node owner or public key already exists.
        uint256 len = attesterOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (attesterOwners[i] == nodeOwner) {
                revert NodeOwnerAlreadyExists();
            }
            if (compareBytes(attesters[attesterOwners[i]].pubKey, pubKey)) {
                revert PubKeyAlreadyExists();
            }
        }

        attesters[nodeOwner] = Attester(weight, pubKey, false);
        attesterOwners.push(nodeOwner);
    }

    // Removes an attester. Should fail if the validator is still active or
    // the inactivity delay has not passed.
    function remove(address nodeOwner) external onlyOwner {
        verifyExists(nodeOwner);
        if (!attesters[nodeOwner].isInactive) {
            revert AttesterIsActive();
        }

        // Remove from mapping.
        delete attesters[nodeOwner];

        // Remove from array by swapping the last element (gas-efficient, not preserving order).
        attesterOwners[nodeOwnerIndex(nodeOwner)] = attesterOwners[attesterOwners.length - 1];
        attesterOwners.pop();
    }

    // Inactivates an attester.
    function inactivate(address nodeOwner) external onlyOwner {
        verifyExists(nodeOwner);
        attesters[nodeOwner].isInactive = true;
    }

    // Activates an attester.
    function activate(address nodeOwner) external onlyOwner {
        verifyExists(nodeOwner);
        attesters[nodeOwner].isInactive = false;
    }

    // Changes the weight.
    function changeWeight(address nodeOwner, uint256 weight) external onlyOwner {
        verifyExists(nodeOwner);
        attesters[nodeOwner].weight = weight;
    }

    // Changes the public key.
    function changePublicKey(address nodeOwner, bytes calldata pubKey) external onlyOwner {
        verifyExists(nodeOwner);
        attesters[nodeOwner].pubKey = pubKey;
    }

    // Creates a new committee list.
    function setCommittee() external onlyOwner {
        // Creates a new committee based on active attesters.
        delete committee;
        uint256 len = attesterOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            Attester memory attester = attesters[attesterOwners[i]];
            if (!attester.isInactive) {
                committee.push(CommitteeAttester(attester.weight, attesterOwners[i], attester.pubKey));
            }
        }
    }

    // Finds the index of a node owner in the `nodeOwners` array.
    function nodeOwnerIndex(address nodeOwner) private view returns (uint256) {
        uint256 len = attesterOwners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (attesterOwners[i] == nodeOwner) {
                return i;
            }
        }
        revert NodeOwnerNotFound();
    }
    // Verifies that an attester exists.
    function verifyExists(address nodeOwner) private view {
        if (attesters[nodeOwner].pubKey.length == 0) {
            revert AttesterDoesNotExist();
        }
    }

    function compareBytes(bytes storage a, bytes calldata b) private pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    function numAttesters() public view returns (uint256) {
        return attesterOwners.length;
    }
}
