// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IVectorx} from "./IVectorx.sol";

contract DummyVectorX is IVectorx {
    function rangeStartBlocks(bytes32) external view returns (uint32 startBlock) {
        return 1;
    }
}
