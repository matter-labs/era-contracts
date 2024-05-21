// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IBatchAggregator} from "./interfaces/IBatchAggregator.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOG_SERIALIZE_SIZE, STATE_DIFF_COMPRESSION_VERSION_NUMBER} from "./interfaces/IL1Messenger.sol";
import {SystemLogKey, SYSTEM_CONTEXT_CONTRACT, KNOWN_CODE_STORAGE_CONTRACT, COMPRESSOR_CONTRACT, BATCH_AGGREGATOR, STATE_DIFF_ENTRY_SIZE, L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, PUBDATA_CHUNK_PUBLISHER, COMPUTATIONAL_PRICE_FOR_PUBDATA} from "./Constants.sol";

contract BatchAggregator is IBatchAggregator, ISystemContract {
    bytes[] batchStorage;
    bytes[] chainData;
    mapping(uint256 => bytes[]) messageStorage;
    mapping(uint256 => bytes[]) logStorage;
    mapping(uint256 => bytes[]) stateDiffStorage;
    mapping(uint256 => bytes[]) bytecodeStorage;
    mapping(uint256 => bool) chainSet;
    uint256[] chainList;
    function addChain(uint256 chainId) internal {
        if (chainSet[chainId] == false) {
            chainList.push(chainId);
            chainSet[chainId] = true;
        }
    }
    function commitBatch(
        bytes calldata _totalL2ToL1PubdataAndStateDiffs,
        uint256 chainId,
        uint256 batchNumber
    ) external {
        addChain(chainId);

        uint256 calldataPtr = 0;

        /// Check logs
        uint32 numberOfL2ToL1Logs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        require(numberOfL2ToL1Logs <= L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, "Too many L2->L1 logs");
        logStorage[chainId].push(
            _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
                4 +
                numberOfL2ToL1Logs *
                L2_TO_L1_LOG_SERIALIZE_SIZE]
        );
        calldataPtr += 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * numberOfL2ToL1Logs;

        /// Check messages
        uint32 numberOfMessages = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        messageStorage[chainId].push(
            _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4 + numberOfMessages * 4]
        );
        calldataPtr += 4 + numberOfMessages * 4;

        /// Check bytecodes
        uint32 numberOfBytecodes = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        uint256 bytecodeSliceStart = calldataPtr;
        calldataPtr += 4;
        bytes32 reconstructedChainedL1BytecodesRevealDataHash;
        for (uint256 i = 0; i < numberOfBytecodes; ++i) {
            uint32 currentBytecodeLength = uint32(
                bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4])
            );
            calldataPtr += 4 + currentBytecodeLength;
        }

        bytecodeStorage[chainId].push(_totalL2ToL1PubdataAndStateDiffs[bytecodeSliceStart:calldataPtr]);
        /// Check State Diffs
        /// encoding is as follows:
        /// header (1 byte version, 3 bytes total len of compressed, 1 byte enumeration index size)
        /// body (`compressedStateDiffSize` bytes, 4 bytes number of state diffs, `numberOfStateDiffs` * `STATE_DIFF_ENTRY_SIZE` bytes for the uncompressed state diffs)
        /// encoded state diffs: [20bytes address][32bytes key][32bytes derived key][8bytes enum index][32bytes initial value][32bytes final value]
        require(
            uint256(uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]))) ==
                STATE_DIFF_COMPRESSION_VERSION_NUMBER,
            "state diff compression version mismatch"
        );
        uint256 stateDiffSliceStart = calldataPtr;
        calldataPtr++;

        uint24 compressedStateDiffSize = uint24(bytes3(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 3]));
        calldataPtr += 3;

        uint8 enumerationIndexSize = uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]));
        calldataPtr++;

        bytes calldata compressedStateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            compressedStateDiffSize];
        calldataPtr += compressedStateDiffSize;

        bytes calldata totalL2ToL1Pubdata = _totalL2ToL1PubdataAndStateDiffs[:calldataPtr];

        uint32 numberOfStateDiffs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        calldataPtr += 4;

        bytes calldata stateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            (numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE)];
        calldataPtr += numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE;

        stateDiffStorage[chainId].push(_totalL2ToL1PubdataAndStateDiffs[stateDiffSliceStart:calldataPtr]);
    }
    function returnBatchesAndClearState() external returns (bytes memory batchInfo) {
        for (uint256 i = 0; i < chainList.length; i += 1) {
            uint256 chainId = chainList[i];

            chainData.push(
                abi.encode(
                    chainId,
                    logStorage[chainId],
                    messageStorage[chainId],
                    bytecodeStorage[chainId],
                    stateDiffStorage[chainId]
                )
            );

            delete chainSet[chainId];
            delete logStorage[chainId];
            delete messageStorage[chainId];
            delete bytecodeStorage[chainId];
            delete stateDiffStorage[chainId];
        }
        delete chainList;
        batchInfo = abi.encode(chainData);
        delete chainData;
        /*delete messageStorage;
        delete logStorage;
        delete stateDiffStorage;
        delete bytecodeStorage;*/
    }
}
