// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IAccountCodeStorage {
    function storeAccountConstructingCodeHash(address _address, bytes32 _hash) external;

    function storeAccountConstructedCodeHash(address _address, bytes32 _hash) external;

    function markAccountCodeHashAsConstructed(address _address) external;

    function getRawCodeHash(address _address) external view returns (bytes32 codeHash);

    function getCodeHash(uint256 _input) external view returns (bytes32 codeHash);

    function getCodeSize(uint256 _input) external view returns (uint256 codeSize);
}
