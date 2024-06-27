// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./ValidatorRegistry.sol";
import "./AttesterRegistry.sol";

contract ConsensusAuthority {
    // Owner of the contract (i.e., the governance contract).
    address public owner;
    // The validator registry instance.
    ValidatorRegistry public validatorRegistry;
    // The attester registry instance.
    AttesterRegistry public attesterRegistry;

    // A map of owningPubKey (a cold key L2 address) => indexes on registries.
    mapping(address => RegistryIndexes) public nodes;

    struct RegistryIndexes {
        // Index in the validator registry.
        uint256 validatorIdx;
        // Index in the attester registry.
        uint256 attesterIdx;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized: onlyOwner");
        _;
    }

    modifier onlyOwnerOrNodeOwner(address owningPubKey) {
        require(msg.sender == owner || msg.sender == owningPubKey, "Unauthorized: onlyOwnerOrNodeOwner");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        validatorRegistry = new ValidatorRegistry(address(this));
        attesterRegistry = new AttesterRegistry(address(this));
    }

    // Adds a new node to the registries.
    function add(
        address owningPubKey,
        uint256 weight,
        bytes calldata validatorPubKey,
        bytes calldata validatorPoP,
        bytes calldata attesterPubKey
    ) external onlyOwner {
        uint256 validatorIdx = validatorRegistry.add(weight, validatorPubKey, validatorPoP);
        uint256 attesterIdx = attesterRegistry.add(weight, attesterPubKey);
        nodes[owningPubKey] = RegistryIndexes(validatorIdx, attesterIdx);
    }

    // Inactivates a node.
    function inactivate(address owningPubKey) external onlyOwnerOrNodeOwner(owningPubKey) {
        RegistryIndexes memory node = nodes[owningPubKey];
        validatorRegistry.inactivate(node.validatorIdx);
        attesterRegistry.inactivate(node.attesterIdx);
    }

    // Activates a node.
    function activate(address owningPubKey) external onlyOwner {
        RegistryIndexes memory node = nodes[owningPubKey];
        validatorRegistry.activate(node.validatorIdx);
        attesterRegistry.activate(node.attesterIdx);
    }

    // Changes node's validator weight.
    function changeValidatorWeight(address owningPubKey, uint256 weight) external onlyOwner {
        uint256 idx = nodes[owningPubKey].validatorIdx;
        validatorRegistry.changeWeight(idx, weight);
    }

    // Changes node's ayyester weight.
    function changeAttesterWeight(address owningPubKey, uint256 weight) external onlyOwner {
        uint256 idx = nodes[owningPubKey].attesterIdx;
        attesterRegistry.changeWeight(idx, weight);
    }

    // Changes node's validator public key and PoP.
    function changeValidatorPubKey(address owningPubKey, bytes calldata pubKey, bytes calldata pop) external onlyOwnerOrNodeOwner(owningPubKey) {
        uint256 idx = nodes[owningPubKey].validatorIdx;
        validatorRegistry.changePublicKey(idx, pubKey, pop);
    }

    // Changes node's attester public key.
    function changeAttesterPubKey(address owningPubKey, bytes calldata pubKey) external onlyOwnerOrNodeOwner(owningPubKey) {
        uint256 idx = nodes[owningPubKey].attesterIdx;
        attesterRegistry.changePublicKey(idx, pubKey);
    }
}
