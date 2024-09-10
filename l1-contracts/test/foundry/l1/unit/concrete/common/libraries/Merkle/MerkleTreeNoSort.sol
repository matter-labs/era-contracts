// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MurkyBase} from "murky/common/MurkyBase.sol";

contract MerkleTreeNoSort is MurkyBase {
    /**
     *
     * HASHING FUNCTION *
     *
     */

    /// The original Merkle tree contains the ascending sort and concat prior to hashing, so we need to override it
    function hashLeafPairs(bytes32 left, bytes32 right) public pure override returns (bytes32 _hash) {
        assembly {
            mstore(0x0, left)
            mstore(0x20, right)
            _hash := keccak256(0x0, 0x40)
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
