// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IBatchAggregator} from "./interfaces/IBatchAggregator.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOG_SERIALIZE_SIZE, STATE_DIFF_COMPRESSION_VERSION_NUMBER} from "./interfaces/IL1Messenger.sol";
import {SystemLogKey, SYSTEM_CONTEXT_CONTRACT, KNOWN_CODE_STORAGE_CONTRACT, COMPRESSOR_CONTRACT, BATCH_AGGREGATOR, STATE_DIFF_ENTRY_SIZE, STATE_DIFF_AGGREGATION_INFO_SIZE, L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, PUBDATA_CHUNK_PUBLISHER, COMPUTATIONAL_PRICE_FOR_PUBDATA} from "./Constants.sol";
import {UnsafeBytesCalldata} from "./libraries/UnsafeBytesCalldata.sol";
import {ICompressor, OPERATION_BITMASK, LENGTH_BITS_OFFSET, MAX_ENUMERATION_INDEX_SIZE} from "./interfaces/ICompressor.sol";

uint256 constant DERIVED_KEY_SIZE = 32;
uint256 constant LOOSE_COMPRESION = 33;
contract BatchAggregator is IBatchAggregator, ISystemContract {
    using UnsafeBytesCalldata for bytes;
    bytes[] batchStorage;
    bytes[] chainData;
    // log data
    mapping(uint256 => bytes[]) messageStorage;
    mapping(uint256 => bytes[]) logStorage;
    mapping(uint256 => bytes[]) bytecodeStorage;
    // state diff data
    mapping(uint256 => mapping(bytes32 => bytes)) initialWrites;
    mapping(uint256 => mapping(bytes32 => bool)) isInitialWrite;
    mapping(uint256 => bytes32[]) initialWritesSlots; 
    /// @dev state diff:   [32bytes derived key][8bytes enum index][32bytes initial value][32bytes final value]
    mapping(uint256 => mapping(uint64 => bytes)) uncompressedWrites;
    mapping(uint256 => mapping(uint64 => bool)) isKeyTouched;
    mapping(uint256 => uint64[]) touchedSlots;
    
    // chain data
    mapping(uint256 => bool) chainSet;
    uint256[] chainList;
    function addChain(uint256 chainId) internal {
        if (chainSet[chainId] == false) {
            chainList.push(chainId);
            chainSet[chainId] = true;
        }
    }
  
    function _sliceToUint256(bytes calldata _calldataSlice) internal pure returns (uint256 number) {
        number = uint256(bytes32(_calldataSlice));
        number >>= (256 - (_calldataSlice.length * 8));
        
    }

    function addInitialWrite(uint256 chainId, bytes32 derivedKey, uint64 enumIndex, uint256 initialValue, uint256 finalValue) internal{
        bytes memory slotData = new bytes(STATE_DIFF_AGGREGATION_INFO_SIZE);
        assembly{
            mstore(add(slotData,0),derivedKey)
            mstore(add(slotData,32),enumIndex)
            mstore(add(slotData,40),initialValue)
            mstore(add(slotData,72),finalValue)
        }
        initialWrites[chainId][derivedKey] = slotData;
        isInitialWrite[chainId][derivedKey] = true;
        initialWritesSlots[chainId].push(derivedKey);
    }
    function addRepeatedWrite(uint256 chainId, bytes32 derivedKey, uint64 enumIndex, uint256 initialValue, uint256 finalValue) internal{
        if (isInitialWrite[chainId][derivedKey]==true){
            bytes memory slotData = initialWrites[chainId][derivedKey];
            assembly {
                mstore(add(slotData,72),finalValue)
            }
            initialWrites[chainId][derivedKey] = slotData;
        }
        else if (isKeyTouched[chainId][enumIndex]==false){
            bytes memory slotData = new bytes(STATE_DIFF_AGGREGATION_INFO_SIZE);
            assembly{
                mstore(add(slotData,0),derivedKey)
                mstore(add(slotData,32),enumIndex)
                mstore(add(slotData,40),initialValue)
                mstore(add(slotData,72),finalValue)
            }
            uncompressedWrites[chainId][enumIndex] = slotData;
            isKeyTouched[chainId][enumIndex] = true;
            touchedSlots[chainId].push(enumIndex);
        }
        else{
            bytes memory slotData = uncompressedWrites[chainId][enumIndex];
            assembly {
                mstore(add(slotData,72),finalValue)
            }
            uncompressedWrites[chainId][enumIndex] = slotData;
        }
    }
    function repackStateDiffs(uint256 chainId,
        uint256 _numberOfStateDiffs,
        uint256 _enumerationIndexSize,
        bytes calldata _stateDiffs,
        bytes calldata _compressedStateDiffs
    ) internal{
        // We do not enforce the operator to use the optimal, i.e. the minimally possible _enumerationIndexSize.
        // We do enforce however, that the _enumerationIndexSize is not larger than 8 bytes long, which is the
        // maximal ever possible size for enumeration index.
        require(_enumerationIndexSize <= MAX_ENUMERATION_INDEX_SIZE, "enumeration index size is too large");

        uint256 numberOfInitialWrites = uint256(_compressedStateDiffs.readUint16(0));

        uint256 stateDiffPtr = 2;
        uint256 numInitialWritesProcessed = 0;

        // Process initial writes
        for (uint256 i = 0; i < _numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE; i += STATE_DIFF_ENTRY_SIZE) {
            bytes calldata stateDiff = _stateDiffs[i:i + STATE_DIFF_ENTRY_SIZE];
            uint64 enumIndex = stateDiff.readUint64(84);
            if (enumIndex != 0) {
                // It is a repeated write, so we skip it.
                continue;
            }
            

            numInitialWritesProcessed++;

            bytes32 derivedKey = stateDiff.readBytes32(52);
            uint256 initialValue = stateDiff.readUint256(92);
            uint256 finalValue = stateDiff.readUint256(124);

            require(derivedKey == _compressedStateDiffs.readBytes32(stateDiffPtr), "iw: initial key mismatch");
            stateDiffPtr += 32;
            uint8 metadata = uint8(bytes1(_compressedStateDiffs[stateDiffPtr]));
            stateDiffPtr++;
            uint8 operation = metadata & OPERATION_BITMASK;
            uint8 len = operation == 0 ? 32 : metadata >> LENGTH_BITS_OFFSET;
        
            stateDiffPtr += len;
            addInitialWrite(chainId, derivedKey, enumIndex, initialValue, finalValue);
        }

        require(numInitialWritesProcessed == numberOfInitialWrites, "Incorrect number of initial storage diffs");

        // Process repeated writes
        for (uint256 i = 0; i < _numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE; i += STATE_DIFF_ENTRY_SIZE) {
            bytes calldata stateDiff = _stateDiffs[i:i + STATE_DIFF_ENTRY_SIZE];
            uint64 enumIndex = stateDiff.readUint64(84);
            if (enumIndex == 0) {
                continue;
            }

            bytes32 derivedKey = stateDiff.readBytes32(52);
            uint256 initialValue = stateDiff.readUint256(92);
            uint256 finalValue = stateDiff.readUint256(124);
            uint256 compressedEnumIndex = _sliceToUint256(
                _compressedStateDiffs[stateDiffPtr:stateDiffPtr + _enumerationIndexSize]
            );
            require(enumIndex == compressedEnumIndex, "rw: enum key mismatch");
            stateDiffPtr += _enumerationIndexSize;

            uint8 metadata = uint8(bytes1(_compressedStateDiffs[stateDiffPtr]));
            stateDiffPtr += 1;
            uint8 operation = metadata & OPERATION_BITMASK;
            uint8 len = operation == 0 ? 32 : metadata >> LENGTH_BITS_OFFSET;
            stateDiffPtr += len;

            addRepeatedWrite(chainId, derivedKey, enumIndex, initialValue, finalValue);
            
        }

        require(stateDiffPtr == _compressedStateDiffs.length, "Extra data in _compressedStateDiffs");

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
        uint256 messageSliceStart = calldataPtr;
        uint32 numberOfMessages = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        calldataPtr += 4;
        for (uint256 i = 0; i < numberOfMessages; ++i) {
            uint32 currentMessageLength = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
            calldataPtr += 4 + currentMessageLength;
        }
        messageStorage[chainId].push(_totalL2ToL1PubdataAndStateDiffs[messageSliceStart:calldataPtr]);

        /// Check bytecodes
        uint32 numberOfBytecodes = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        uint256 bytecodeSliceStart = calldataPtr;
        calldataPtr += 4;
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
        calldataPtr++;

        uint24 compressedStateDiffSize = uint24(bytes3(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 3]));
        calldataPtr += 3;

        uint8 enumerationIndexSize = uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]));
        calldataPtr++;

        bytes calldata compressedStateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            compressedStateDiffSize];
        calldataPtr += compressedStateDiffSize;

        uint32 numberOfStateDiffs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        calldataPtr += 4;

        bytes calldata stateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            (numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE)];

        calldataPtr += numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE;

        repackStateDiffs(chainId, numberOfStateDiffs, enumerationIndexSize, stateDiffs, compressedStateDiffs);
    }
    function bytesLength(uint256 value) pure internal returns (uint8 length){
        while(value>0){
            length += 1;
            value = value>>8;
        }
    }
    function subUnchecked(uint256 a, uint256 b) pure internal returns(uint256) {
        unchecked { return a - b ;}
    }
    function compressValue(uint256 initialValue, uint256 finalValue) pure internal returns (bytes memory compressedDiff){
        uint8 transform = bytesLength(finalValue);
        uint8 add = bytesLength(subUnchecked(finalValue,initialValue));
        uint8 sub = bytesLength(subUnchecked(initialValue,finalValue));
        uint8 optimal = (transform<add?transform:add);
        optimal = (optimal<sub?optimal:sub);
        compressedDiff = new bytes(optimal+1);
        uint8 mask = (optimal<<LENGTH_BITS_OFFSET);
        uint256 value;
        if (optimal==32){
            mask |= 0;
            value = finalValue;
        }
        else if (transform==optimal){
            mask |= 3;
            value = finalValue;
        }
        else if (add==optimal){
            mask |= 1;
            value = finalValue-initialValue;
        }
        else if (sub==optimal){
            mask |= 2;
            value = initialValue-finalValue;
        }
        else{
            require(false, "optimalimal operation is not transform, add or sub");
        }
        uint8 diffPtr = optimal;
        for(uint8 i = 0;i<optimal;i+=1){
            compressedDiff[diffPtr] = bytes1(uint8(value & type(uint8).max));
            diffPtr -= 1;
        }
    }
    function returnBatchesAndClearState() external returns (bytes memory batchInfo) {
        for (uint256 i = 0; i < chainList.length; i += 1) {
            uint256 chainId = chainList[i];
            uint256 numberOfInitialWrites = initialWritesSlots[chainId].length;
            uint256 numberOfRepeatedWrites = touchedSlots[chainId].length;
            bytes memory stateDiffs = new bytes((numberOfRepeatedWrites+numberOfInitialWrites)*STATE_DIFF_AGGREGATION_INFO_SIZE);
            
            uint256 maxEnumIndex = 0;
            uint256 stateDiffPtr = 0;
            // append initial writes
            for(uint256 i = 0;i<numberOfInitialWrites;i+=1){
                bytes memory stateDiff = initialWrites[chainId][initialWritesSlots[chainId][i]];
                assembly{
                    mstore(add(stateDiffs, stateDiffPtr), stateDiff)
                }
                stateDiffPtr += STATE_DIFF_AGGREGATION_INFO_SIZE;
            }
            // append repeated writes
            for (uint256 i = 0;i<numberOfRepeatedWrites;i+=1){
                uint64 enumIndex = touchedSlots[chainId][i];
                bytes memory stateDiff = uncompressedWrites[chainId][enumIndex];
                assembly{
                    mstore(add(numberOfInitialWrites, stateDiffPtr), stateDiff)
                }
                maxEnumIndex = (maxEnumIndex > enumIndex?maxEnumIndex:enumIndex);
                stateDiffPtr += STATE_DIFF_AGGREGATION_INFO_SIZE;
            }
            uint256 enumIndexSize = bytesLength(maxEnumIndex);
            
            bytes memory compressedStateDiffs = new bytes(
                (numberOfRepeatedWrites+numberOfInitialWrites)*LOOSE_COMPRESION // maximal size of metadata + compressed value
                +numberOfRepeatedWrites*enumIndexSize                           // enumIndexSize for repeated writes
                +numberOfInitialWrites*DERIVED_KEY_SIZE);                       // derived key for initial writes
            // compress initial writes
            uint256 compressedStateDiffSize = 0;
            for(uint256 i = 0;i<numberOfInitialWrites;i+=1){
                bytes memory stateDiff = initialWrites[chainId][initialWritesSlots[chainId][i]];
                uint256 derivedKey;
                uint256 initialValue;
                uint256 finalValue;
                assembly{
                    derivedKey := mload(add(stateDiff,52))
                    initialValue := mload(add(stateDiff,92))
                    finalValue := mload(add(stateDiff,124))
                }
                bytes memory compressedStateDiff = compressValue(initialValue, finalValue);
                assembly{
                    mstore(add(compressedStateDiffs, compressedStateDiffSize), derivedKey)
                }
                compressedStateDiffSize += DERIVED_KEY_SIZE;
                assembly{
                    mstore(add(compressedStateDiffs, compressedStateDiffSize),compressedStateDiff)
                }
                compressedStateDiffSize += compressedStateDiff.length;
            }
            // compress repeated writes
            for (uint256 i = 0;i<numberOfRepeatedWrites;i+=1){
                uint64 enumIndex = touchedSlots[chainId][i];
                bytes memory stateDiff = uncompressedWrites[chainId][enumIndex];
                uint256 initialValue;
                uint256 finalValue;
                assembly{
                    initialValue := mload(add(stateDiff,92))
                    finalValue := mload(add(stateDiff,124))
                }
                bytes memory compressedStateDiff = compressValue(initialValue, finalValue);
                assembly{
                    mstore(add(compressedStateDiffs, compressedStateDiffSize), enumIndex)
                }
                compressedStateDiffSize += enumIndexSize;
                assembly{
                    mstore(add(compressedStateDiffs, compressedStateDiffSize),compressedStateDiff)
                }
                compressedStateDiffSize += compressedStateDiff.length;
            }
            chainData.push(
                abi.encode(
                    chainId,
                    logStorage[chainId],
                    messageStorage[chainId],
                    bytecodeStorage[chainId],
                    numberOfInitialWrites,
                    numberOfRepeatedWrites,
                    enumIndexSize,
                    stateDiffs,
                    compressedStateDiffs
                )
            );

            delete chainSet[chainId];
            delete logStorage[chainId];
            delete messageStorage[chainId];
            delete bytecodeStorage[chainId];
        }
        delete chainList;
        batchInfo = abi.encode(chainData);
        delete chainData;
    }
}
