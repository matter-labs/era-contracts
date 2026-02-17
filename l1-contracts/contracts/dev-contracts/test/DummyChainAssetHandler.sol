// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title DummyChainAssetHandler
/// @notice A mock chain asset handler for testing.
contract DummyChainAssetHandler {
    mapping(uint256 => uint256) public migrationNumber;

    function setMigrationNumber(uint256 _chainId, uint256 _number) external {
        migrationNumber[_chainId] = _number;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
