// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS, L2_TO_L1_MESSENGER, SystemLogKey, Utils, L2_DA_COMMITMENT_SCHEME} from "./Utils.sol";

import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";

// solhint-enable max-line-length

contract UtilsTest is UtilsCallMockerTest {
    function test_PackBatchTimestampAndBlockTimestamp() public virtual {
        uint64 batchTimestamp = 0x12345678;
        uint64 blockTimestamp = 0x87654321;
        bytes32 packedBytes = Utils.packBatchTimestampAndBlockTimestamp(batchTimestamp, blockTimestamp);

        assertEq(
            packedBytes,
            0x0000000000000000000000001234567800000000000000000000000087654321,
            "packed bytes should be correct"
        );
    }

    function test_ConstructL2Log() public virtual {
        bytes memory l2Log = Utils.constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            bytes32(uint256(0x2222))
        );

        assertEq(
            l2Log,
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(
                bytes2(0x0001), // servicePrefix
                bytes2(0x0000), // 0x0000
                L2_TO_L1_MESSENGER, // sender
                uint256(SystemLogKey.PREV_BATCH_HASH_KEY), // key
                bytes32(uint256(0x2222)) // value
            )
        );
    }

    function test_CreateSystemLogs() public virtual {
        bytes[] memory logs = Utils.createSystemLogs(bytes32(0));

        assertEq(logs.length, 10, "logs length should be correct");

        assertEq(
            logs[0],
            Utils.constructL2Log(
                true,
                L2_TO_L1_MESSENGER,
                uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY),
                bytes32("")
            ),
            "log[0] should be correct"
        );

        assertEq(
            logs[1],
            Utils.constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                bytes32("")
            ),
            "log[1] should be correct"
        );

        assertEq(
            logs[2],
            Utils.constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
                keccak256("")
            ),
            "log[2] should be correct"
        );

        assertEq(
            logs[3],
            Utils.constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
                bytes32("")
            ),
            "log[3] should be correct"
        );

        assertEq(
            logs[4],
            Utils.constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
                bytes32("")
            ),
            "log[4] should be correct"
        );

        assertEq(
            logs[5],
            Utils.constructL2Log(
                true,
                L2_TO_L1_MESSENGER,
                uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY),
                bytes32(0)
            ),
            "log[5] should be correct"
        );

        assertEq(
            logs[6],
            Utils.constructL2Log(
                true,
                L2_TO_L1_MESSENGER,
                uint256(SystemLogKey.USED_L2_DA_VALIDATION_COMMITMENT_SCHEME_KEY),
                bytes32(uint256(L2_DA_COMMITMENT_SCHEME))
            ),
            "log[6] should be correct"
        );

        assertEq(
            logs[7],
            Utils.constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                uint256(SystemLogKey.MESSAGE_ROOT_ROLLING_HASH_KEY),
                bytes32(uint256(uint160(0)))
            ),
            "log[7] should be correct"
        );

        assertEq(
            logs[8],
            Utils.constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                uint256(SystemLogKey.L2_TXS_STATUS_ROLLING_HASH_KEY),
                bytes32("")
            ),
            "log[8] should be correct"
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
