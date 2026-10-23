// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMTLeaf} from "era/common/libraries/IndexedMerkleTree.sol";

/// @notice Private insertion witness serialized for the debit circuit.
library ImtInsertion {
    struct Proof {
        IMTLeaf low;
        uint256 lowIndex;
        bytes32[] lowPath;
        bytes32[] newPath;
    }
}
