// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ValidatorRegistry} from "./ValidatorRegistry.sol";
import {AttesterRegistry} from "./AttesterRegistry.sol";

contract ConsensusAuthority {
    // Owner of the contract (i.e., the governance contract).
    address public owner;
    // The validator registry instance.
    ValidatorRegistry public validatorRegistry;
    // The attester registry instance.
    AttesterRegistry public attesterRegistry;

    error UnauthorizedOnlyOwner();
    error UnauthorizedOnlyOwnerOrNodeOwner();

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
        validatorRegistry = new ValidatorRegistry(address(this));
        attesterRegistry = new AttesterRegistry(address(this));
    }

    // Adds a new node to the registries.
    function add(
        address nodeOwner,
        uint256 validatorWeight,
        bytes calldata validatorPubKey,
        bytes calldata validatorPoP,
        uint256 attesterWeight,
        bytes calldata attesterPubKey
    ) external onlyOwner {
        validatorRegistry.add(nodeOwner, validatorWeight, validatorPubKey, validatorPoP);
        attesterRegistry.add(nodeOwner, attesterWeight, attesterPubKey);
    }

    // Inactivates a node.
    function inactivate(address nodeOwner) external onlyOwnerOrNodeOwner(nodeOwner) {
        validatorRegistry.inactivate(nodeOwner);
        attesterRegistry.inactivate(nodeOwner);
    }

    // Activates a node.
    function activate(address nodeOwner) external onlyOwner {
        validatorRegistry.activate(nodeOwner);
        attesterRegistry.activate(nodeOwner);
    }

    // Removes a node.
    function remove(address nodeOwner) external onlyOwner {
        validatorRegistry.remove(nodeOwner);
        attesterRegistry.remove(nodeOwner);
    }

    // Changes node's validator weight.
    function changeValidatorWeight(address nodeOwner, uint256 weight) external onlyOwner {
        validatorRegistry.changeWeight(nodeOwner, weight);
    }

    // Changes node's attester weight.
    function changeAttesterWeight(address nodeOwner, uint256 weight) external onlyOwner {
        attesterRegistry.changeWeight(nodeOwner, weight);
    }

    // Changes node's validator public key and PoP.
    function changeValidatorPubKey(address nodeOwner, bytes calldata pubKey, bytes calldata pop) external onlyOwnerOrNodeOwner(nodeOwner) {
        validatorRegistry.changePublicKey(nodeOwner, pubKey, pop);
    }

    // Changes node's attester public key.
    function changeAttesterPubKey(address nodeOwner, bytes calldata pubKey) external onlyOwnerOrNodeOwner(nodeOwner) {
        attesterRegistry.changePublicKey(nodeOwner, pubKey);
    }
}
