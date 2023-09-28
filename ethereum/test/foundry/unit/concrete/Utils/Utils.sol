// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = 0x0000000000000000000000000000000000000000000000000000000000000000;
address constant L2_SYSTEM_CONTEXT_ADDRESS = 0x000000000000000000000000000000000000800B;
address constant L2_BOOTLOADER_ADDRESS = 0x0000000000000000000000000000000000008001;
address constant L2_KNOWN_CODE_STORAGE_ADDRESS = 0x0000000000000000000000000000000000008004;
address constant L2_TO_L1_MESSENGER = 0x0000000000000000000000000000000000008008;

library Utils {
    enum SystemLogKeys {
        L2_TO_L1_LOGS_TREE_ROOT_KEY,
        TOTAL_L2_TO_L1_PUBDATA_KEY,
        STATE_DIFF_HASH_KEY,
        PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
        PREV_BATCH_HASH_KEY,
        CHAINED_PRIORITY_TXN_HASH_KEY,
        NUMBER_OF_LAYER_1_TXS_KEY,
        EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH
    }

    function packBatchTimestampAndBlockTimestamp(
        uint256 batchTimestamp,
        uint256 blockTimestamp
    ) public pure returns (bytes32) {
        uint256 packedNum = (batchTimestamp << 128) | blockTimestamp;
        return bytes32(packedNum);
    }

    function randomBytes32(bytes memory seed) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, seed));
    }

    function constructL2Log(
        bool isService,
        address sender,
        uint256 key,
        bytes32 value
    ) public pure returns (bytes memory) {
        bytes2 servicePrefix = 0x0001;
        if (!isService) {
            servicePrefix = 0x0000;
        }

        return abi.encodePacked(servicePrefix, bytes2(0x0000), sender, key, value);
    }

    function createSystemLogs() public pure returns (bytes[] memory) {
        bytes[] memory logs = new bytes[](7);
        logs[0] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKeys.L2_TO_L1_LOGS_TREE_ROOT_KEY),
            bytes32("")
        );
        logs[1] = constructL2Log(
            true,
            L2_TO_L1_MESSENGER,
            uint256(SystemLogKeys.TOTAL_L2_TO_L1_PUBDATA_KEY),
            0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563
        );
        logs[2] = constructL2Log(true, L2_TO_L1_MESSENGER, uint256(SystemLogKeys.STATE_DIFF_HASH_KEY), bytes32(""));
        logs[3] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            bytes32("")
        );
        logs[4] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKeys.PREV_BATCH_HASH_KEY),
            bytes32("")
        );
        logs[5] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKeys.CHAINED_PRIORITY_TXN_HASH_KEY),
            keccak256("")
        );
        logs[6] = constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKeys.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32("")
        );
        return logs;
    }

    function encodePacked(bytes[] memory data) public pure returns (bytes memory) {
        bytes memory result;
        for (uint256 i = 0; i < data.length; i++) {
            result = abi.encodePacked(result, data[i]);
        }
        return result;
    }
}
