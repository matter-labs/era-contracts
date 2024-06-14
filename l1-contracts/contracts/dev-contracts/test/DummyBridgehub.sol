// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyBridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function baseTokenAssetId(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}
