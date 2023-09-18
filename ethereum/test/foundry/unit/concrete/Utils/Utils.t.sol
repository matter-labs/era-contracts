// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils.sol";

contract UtilsTest is Test {
    function test_PackBatchTimestampAndBlockTimestamp() public {
        uint64 batchTimestamp = 0x12345678;
        uint64 blockTimestamp = 0x87654321;
        bytes32 packedBytes = Utils.packBatchTimestampAndBlockTimestamp(batchTimestamp, blockTimestamp);

        assertEq(
            packedBytes,
            0x0000000000000000000000001234567800000000000000000000000087654321,
            "packed bytes should be correct"
        );
    }
}
