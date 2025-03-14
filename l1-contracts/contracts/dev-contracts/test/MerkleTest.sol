// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Merkle} from "../../common/libraries/Merkle.sol";

contract MerkleTest {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function calculateRoot(
        bytes32[] calldata _path,
        uint256 _index,
        bytes32 _itemHash
    ) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _itemHash);
    }

    function calculateRoot(
        bytes32[] calldata _startPath,
        bytes32[] calldata _endPath,
        uint256 _startIndex,
        bytes32[] calldata _itemHashes
    ) external pure returns (bytes32) {
        return Merkle.calculateRootPaths(_startPath, _endPath, _startIndex, _itemHashes);
    }
}
