// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IEvmHashesStorage {
    function storeEvmCodeHash(bytes32 versionedBytecodeHash, bytes32 evmBytecodeHash) external;

    function getEvmCodeHash(bytes32 versionedBytecodeHash) external view returns (bytes32);
}
