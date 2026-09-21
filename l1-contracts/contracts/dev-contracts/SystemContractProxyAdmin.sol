// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SystemContractProxyAdmin
/// @notice Minimal stub for Anvil testing. In production, this manages proxy upgrades
/// for system contracts. For EVM testing, it's a placeholder.
contract SystemContractProxyAdmin {
    address public owner;

    constructor() {
        owner = msg.sender;
    }
}
