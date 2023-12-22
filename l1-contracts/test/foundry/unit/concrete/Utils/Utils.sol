// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {GettersFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";
import {MailboxFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Mailbox.sol";

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

    function getGettersSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = GettersFacet.getVerifier.selector;
        selectors[1] = GettersFacet.getGovernor.selector;
        selectors[2] = GettersFacet.getPendingGovernor.selector;
        selectors[3] = GettersFacet.getTotalBlocksCommitted.selector;
        selectors[4] = GettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = GettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = GettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = GettersFacet.getPriorityQueueSize.selector;
        selectors[9] = GettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = GettersFacet.isValidator.selector;
        selectors[11] = GettersFacet.l2LogsRootHash.selector;
        selectors[12] = GettersFacet.storedBatchHash.selector;
        selectors[13] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = GettersFacet.getVerifierParams.selector;
        selectors[16] = GettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.isFunctionFreezable.selector;
        selectors[24] = GettersFacet.isFacetFreezable.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        return selectors;
    }

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = MailboxFacet.proveL2MessageInclusion.selector;
        selectors[1] = MailboxFacet.proveL2LogInclusion.selector;
        selectors[2] = MailboxFacet.proveL1ToL2TransactionStatus.selector;
        selectors[3] = MailboxFacet.finalizeEthWithdrawal.selector;
        selectors[4] = MailboxFacet.requestL2Transaction.selector;
        selectors[5] = MailboxFacet.l2TransactionBaseCost.selector;
        return selectors;
    }
}
