// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Adapted from era-contracts PR #2177 (matter-labs/era-contracts).
/// Computes the EVM CREATE2 address for a given deployer, salt and init-code hash.
/// Used by L1InteropHandler to predict and lazy-deploy per-(L2-chain, L2-user) shadow accounts.
library Create2Address {
    function getNewAddressCreate2EVM(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash
    ) internal pure returns (address newAddress) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), _sender, _salt, _bytecodeHash));
        newAddress = address(uint160(uint256(hash)));
    }
}
