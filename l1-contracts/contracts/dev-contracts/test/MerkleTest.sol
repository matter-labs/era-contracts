// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/libraries/Merkle.sol";
import "murky/common/MurkyBase.sol";

contract MerkleTreeNoSort is MurkyBase {

    /********************
    * HASHING FUNCTION *
    ********************/

    /// ascending sort and concat prior to hashing
    function hashLeafPairs(bytes32 left, bytes32 right) public pure override returns (bytes32 _hash) {
       assembly {
            mstore(0x0, left)
            mstore(0x20, right)
           _hash := keccak256(0x0, 0x40)
       }
    }
}

contract MerkleTest {
    function calculateRoot(
        bytes32[] calldata _path,
        uint256 _index,
        bytes32 _itemHash
    ) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _itemHash);
    }
}
