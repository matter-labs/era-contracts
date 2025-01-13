// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1Messenger, L2ToL1Log, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOG_SERIALIZE_SIZE} from "./interfaces/IL1Messenger.sol";

import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {Utils} from "./libraries/Utils.sol";
import {SystemLogKey, SYSTEM_CONTEXT_CONTRACT, KNOWN_CODE_STORAGE_CONTRACT, L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, COMPUTATIONAL_PRICE_FOR_PUBDATA, L2_MESSAGE_ROOT} from "./Constants.sol";
import {ReconstructionMismatch, PubdataField} from "./SystemContractErrors.sol";
import {IL2DAValidator} from "./interfaces/IL2DAValidator.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed length messages on L1.
 * A fixed length message has 4 parameters `senderAddress` `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable length message we use this trick:
 * - This system contract accepts a arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `marker == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
contract L1Messenger is IL1Messenger, SystemContractBase {
    /// @notice Sequential hash of logs sent in the current block.
    /// @dev Will be reset at the end of the block to zero value.
    bytes32 internal chainedLogsHash;

    /// @notice Number of logs sent in the current block.
    /// @dev Will be reset at the end of the block to zero value.
    uint256 internal numberOfLogsToProcess;

    /// @notice Sequential hash of hashes of the messages sent in the current block.
    /// @dev Will be reset at the end of the block to zero value.
    bytes32 internal chainedMessagesHash;

    /// @notice Sequential hash of bytecode hashes that needs to published
    /// according to the current block execution invariant.
    /// @dev Will be reset at the end of the block to zero value.
    bytes32 internal chainedL1BytecodesRevealDataHash;

    /// The gas cost of processing one keccak256 round.
    uint256 internal constant KECCAK_ROUND_GAS_COST = 40;

    /// The number of bytes processed in one keccak256 round.
    uint256 internal constant KECCAK_ROUND_NUMBER_OF_BYTES = 136;

    /// The gas cost of calculation of keccak256 of bytes array of such length.
    function keccakGasCost(uint256 _length) internal pure returns (uint256) {
        return KECCAK_ROUND_GAS_COST * (_length / KECCAK_ROUND_NUMBER_OF_BYTES + 1);
    }

    /// The gas cost of processing one sha256 round.
    uint256 internal constant SHA256_ROUND_GAS_COST = 7;

    /// The number of bytes processed in one sha256 round.
    uint256 internal constant SHA256_ROUND_NUMBER_OF_BYTES = 64;

    /// The gas cost of calculation of sha256 of bytes array of such length.
    function sha256GasCost(uint256 _length) internal pure returns (uint256) {
        return SHA256_ROUND_GAS_COST * ((_length + 8) / SHA256_ROUND_NUMBER_OF_BYTES + 1);
    }

    /// @notice Sends L2ToL1Log.
    /// @param _isService The `isService` flag.
    /// @param _key The `key` part of the L2Log.
    /// @param _value The `value` part of the L2Log.
    /// @dev Can be called only by a system contract.
    function sendL2ToL1Log(
        bool _isService,
        bytes32 _key,
        bytes32 _value
    ) external onlyCallFromSystemContract returns (uint256 logIdInMerkleTree) {
        L2ToL1Log memory l2ToL1Log = L2ToL1Log({
            l2ShardId: 0,
            isService: _isService,
            txNumberInBlock: SYSTEM_CONTEXT_CONTRACT.txNumberInBlock(),
            sender: msg.sender,
            key: _key,
            value: _value
        });
        logIdInMerkleTree = _processL2ToL1Log(l2ToL1Log);

        // We need to charge cost of hashing, as it will be used in `publishPubdataAndClearState`:
        // - keccakGasCost(L2_TO_L1_LOG_SERIALIZE_SIZE) and keccakGasCost(64) when reconstructing L2ToL1Log
        // - at most 1 time keccakGasCost(64) when building the Merkle tree (as merkle tree can contain
        // ~2*N nodes, where the first N nodes are leaves the hash of which is calculated on the previous step).
        uint256 gasToPay = keccakGasCost(L2_TO_L1_LOG_SERIALIZE_SIZE) + 2 * keccakGasCost(64);
        SystemContractHelper.burnGas(Utils.safeCastToU32(gasToPay), uint32(L2_TO_L1_LOG_SERIALIZE_SIZE));
    }

    /// @notice Internal function to send L2ToL1Log.
    function _processL2ToL1Log(L2ToL1Log memory _l2ToL1Log) internal returns (uint256 logIdInMerkleTree) {
        bytes32 hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(
                _l2ToL1Log.l2ShardId,
                _l2ToL1Log.isService,
                _l2ToL1Log.txNumberInBlock,
                _l2ToL1Log.sender,
                _l2ToL1Log.key,
                _l2ToL1Log.value
            )
        );

        chainedLogsHash = keccak256(abi.encode(chainedLogsHash, hashedLog));

        logIdInMerkleTree = numberOfLogsToProcess;
        ++numberOfLogsToProcess;

        emit L2ToL1LogSent(_l2ToL1Log);
    }

    /// @notice Public functionality to send messages to L1.
    /// @param _message The message intended to be sent to L1.
    function sendToL1(bytes calldata _message) external override returns (bytes32 hash) {
        uint256 gasBeforeMessageHashing = gasleft();
        hash = EfficientCall.keccak(_message);
        uint256 gasSpentOnMessageHashing = gasBeforeMessageHashing - gasleft();

        /// Store message record
        chainedMessagesHash = keccak256(abi.encode(chainedMessagesHash, hash));

        /// Store log record
        L2ToL1Log memory l2ToL1Log = L2ToL1Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBlock: SYSTEM_CONTEXT_CONTRACT.txNumberInBlock(),
            sender: address(this),
            key: bytes32(uint256(uint160(msg.sender))),
            value: hash
        });
        _processL2ToL1Log(l2ToL1Log);

        uint256 pubdataLen;
        unchecked {
            // 4 bytes used to encode the length of the message (see `publishPubdataAndClearState`)
            // L2_TO_L1_LOG_SERIALIZE_SIZE bytes used to encode L2ToL1Log
            pubdataLen = 4 + _message.length + L2_TO_L1_LOG_SERIALIZE_SIZE;
        }

        // We need to charge cost of hashing, as it will be used in `publishPubdataAndClearState`:
        // - keccakGasCost(L2_TO_L1_LOG_SERIALIZE_SIZE) and keccakGasCost(64) when reconstructing L2ToL1Log
        // - keccakGasCost(64) and gasSpentOnMessageHashing when reconstructing Messages
        // - at most 1 time keccakGasCost(64) when building the Merkle tree (as merkle tree can contain
        // ~2*N nodes, where the first N nodes are leaves the hash of which is calculated on the previous step).
        uint256 gasToPay = keccakGasCost(L2_TO_L1_LOG_SERIALIZE_SIZE) +
            3 *
            keccakGasCost(64) +
            gasSpentOnMessageHashing +
            COMPUTATIONAL_PRICE_FOR_PUBDATA *
            pubdataLen;
        SystemContractHelper.burnGas(Utils.safeCastToU32(gasToPay), uint32(pubdataLen));

        emit L1MessageSent(msg.sender, hash, _message);
    }

    /// @dev Can be called only by KnownCodesStorage system contract.
    /// @param _bytecodeHash Hash of bytecode being published to L1.
    function requestBytecodeL1Publication(
        bytes32 _bytecodeHash
    ) external override onlyCallFrom(address(KNOWN_CODE_STORAGE_CONTRACT)) {
        chainedL1BytecodesRevealDataHash = keccak256(abi.encode(chainedL1BytecodesRevealDataHash, _bytecodeHash));

        uint256 bytecodeLen = Utils.bytecodeLenInBytes(_bytecodeHash);

        uint256 pubdataLen;
        unchecked {
            // 4 bytes used to encode the length of the bytecode (see `publishPubdataAndClearState`)
            pubdataLen = 4 + bytecodeLen;
        }

        // We need to charge cost of hashing, as it will be used in `publishPubdataAndClearState`
        uint256 gasToPay = sha256GasCost(bytecodeLen) +
            keccakGasCost(64) +
            COMPUTATIONAL_PRICE_FOR_PUBDATA *
            pubdataLen;
        SystemContractHelper.burnGas(Utils.safeCastToU32(gasToPay), uint32(pubdataLen));

        emit BytecodeL1PublicationRequested(_bytecodeHash);
    }

    /// @notice Verifies that the {_operatorInput} reflects what occurred within the L1Batch and that
    ///         the compressed statediffs are equivalent to the full state diffs.
    /// @param _l2DAValidator the address of the l2 da validator
    /// @param _operatorInput The total pubdata and uncompressed state diffs of transactions that were
    ///        processed in the current L1 Batch. Pubdata consists of L2 to L1 Logs, messages, deployed bytecode, and state diffs.
    /// @dev Function that should be called exactly once per L1 Batch by the bootloader.
    /// @dev Checks that totalL2ToL1Pubdata is strictly packed data that should to be published to L1.
    /// @dev The data passed in also contains the encoded state diffs to be checked again, however this is aux data that is not
    ///      part of the committed pubdata.
    /// @dev Performs calculation of L2ToL1Logs merkle tree root, "sends" such root and keccak256(totalL2ToL1Pubdata)
    /// to L1 using low-level (VM) L2Log.
    function publishPubdataAndClearState(
        address _l2DAValidator,
        bytes calldata _operatorInput
    ) external onlyCallFromBootloader {
        uint256 calldataPtr = 0;

        // Check function sig and data in the other hashes
        // 4 + 32 + 32 + 32 + 32 + 32 + 32
        // 4 bytes for L2 DA Validator `validatePubdata` function selector
        // 32 bytes for rolling hash of user L2 -> L1 logs
        // 32 bytes for root hash of user L2 -> L1 logs
        // 32 bytes for hash of messages
        // 32 bytes for hash of uncompressed bytecodes sent to L1
        // Operator data: 32 bytes for offset
        //                32 bytes for length

        bytes4 inputL2DAValidatePubdataFunctionSig = bytes4(_operatorInput[calldataPtr:calldataPtr + 4]);
        if (inputL2DAValidatePubdataFunctionSig != IL2DAValidator.validatePubdata.selector) {
            revert ReconstructionMismatch(
                PubdataField.InputDAFunctionSig,
                bytes32(IL2DAValidator.validatePubdata.selector),
                bytes32(inputL2DAValidatePubdataFunctionSig)
            );
        }
        calldataPtr += 4;

        bytes32 inputChainedLogsHash = bytes32(_operatorInput[calldataPtr:calldataPtr + 32]);
        if (inputChainedLogsHash != chainedLogsHash) {
            revert ReconstructionMismatch(PubdataField.InputLogsHash, chainedLogsHash, inputChainedLogsHash);
        }
        calldataPtr += 32;

        // Check happens below after we reconstruct the logs root hash
        bytes32 inputChainedLogsRootHash = bytes32(_operatorInput[calldataPtr:calldataPtr + 32]);
        calldataPtr += 32;

        bytes32 inputChainedMsgsHash = bytes32(_operatorInput[calldataPtr:calldataPtr + 32]);
        if (inputChainedMsgsHash != chainedMessagesHash) {
            revert ReconstructionMismatch(PubdataField.InputMsgsHash, chainedMessagesHash, inputChainedMsgsHash);
        }
        calldataPtr += 32;

        bytes32 inputChainedBytecodesHash = bytes32(_operatorInput[calldataPtr:calldataPtr + 32]);
        if (inputChainedBytecodesHash != chainedL1BytecodesRevealDataHash) {
            revert ReconstructionMismatch(
                PubdataField.InputBytecodeHash,
                chainedL1BytecodesRevealDataHash,
                inputChainedBytecodesHash
            );
        }
        calldataPtr += 32;

        uint256 offset = uint256(bytes32(_operatorInput[calldataPtr:calldataPtr + 32]));
        // The length of the pubdata input should be stored right next to the calldata.
        // We need to change offset by 32 - 4 = 28 bytes, since 32 bytes is the length of the offset
        // itself and the 4 bytes are the selector which is not included inside the offset.
        if (offset != calldataPtr + 28) {
            revert ReconstructionMismatch(PubdataField.Offset, bytes32(calldataPtr + 28), bytes32(offset));
        }
        uint256 length = uint256(bytes32(_operatorInput[calldataPtr + 32:calldataPtr + 64]));

        // Shift calldata ptr past the pubdata offset and len
        calldataPtr += 64;

        /// Check logs
        uint32 numberOfL2ToL1Logs = uint32(bytes4(_operatorInput[calldataPtr:calldataPtr + 4]));
        if (numberOfL2ToL1Logs > L2_TO_L1_LOGS_MERKLE_TREE_LEAVES) {
            revert ReconstructionMismatch(
                PubdataField.NumberOfLogs,
                bytes32(L2_TO_L1_LOGS_MERKLE_TREE_LEAVES),
                bytes32(uint256(numberOfL2ToL1Logs))
            );
        }
        calldataPtr += 4;

        // We need to ensure that length is enough to read all logs
        if (length < 4 + numberOfL2ToL1Logs * L2_TO_L1_LOG_SERIALIZE_SIZE) {
            revert ReconstructionMismatch(
                PubdataField.Length,
                bytes32(4 + numberOfL2ToL1Logs * L2_TO_L1_LOG_SERIALIZE_SIZE),
                bytes32(length)
            );
        }

        bytes32[] memory l2ToL1LogsTreeArray = new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_LEAVES);
        bytes32 reconstructedChainedLogsHash = bytes32(0);
        for (uint256 i = 0; i < numberOfL2ToL1Logs; ++i) {
            bytes32 hashedLog = EfficientCall.keccak(
                _operatorInput[calldataPtr:calldataPtr + L2_TO_L1_LOG_SERIALIZE_SIZE]
            );
            calldataPtr += L2_TO_L1_LOG_SERIALIZE_SIZE;
            l2ToL1LogsTreeArray[i] = hashedLog;
            reconstructedChainedLogsHash = keccak256(abi.encode(reconstructedChainedLogsHash, hashedLog));
        }
        if (reconstructedChainedLogsHash != chainedLogsHash) {
            revert ReconstructionMismatch(PubdataField.LogsHash, chainedLogsHash, reconstructedChainedLogsHash);
        }
        for (uint256 i = numberOfL2ToL1Logs; i < L2_TO_L1_LOGS_MERKLE_TREE_LEAVES; ++i) {
            l2ToL1LogsTreeArray[i] = L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH;
        }
        uint256 nodesOnCurrentLevel = L2_TO_L1_LOGS_MERKLE_TREE_LEAVES;
        while (nodesOnCurrentLevel > 1) {
            nodesOnCurrentLevel /= 2;
            for (uint256 i = 0; i < nodesOnCurrentLevel; ++i) {
                l2ToL1LogsTreeArray[i] = keccak256(
                    abi.encode(l2ToL1LogsTreeArray[2 * i], l2ToL1LogsTreeArray[2 * i + 1])
                );
            }
        }
        bytes32 localLogsRootHash = l2ToL1LogsTreeArray[0];

        bytes32 aggregatedRootHash = L2_MESSAGE_ROOT.getAggregatedRoot();
        bytes32 fullRootHash = keccak256(bytes.concat(localLogsRootHash, aggregatedRootHash));

        if (inputChainedLogsRootHash != localLogsRootHash) {
            revert ReconstructionMismatch(PubdataField.InputLogsRootHash, localLogsRootHash, inputChainedLogsRootHash);
        }

        bytes32 l2DAValidatorOutputhash = bytes32(0);
        if (_l2DAValidator != address(0)) {
            bytes memory returnData = EfficientCall.call({
                _gas: gasleft(),
                _address: _l2DAValidator,
                _value: 0,
                _data: _operatorInput,
                _isSystem: false
            });

            l2DAValidatorOutputhash = abi.decode(returnData, (bytes32));
        }

        /// Native (VM) L2 to L1 log
        SystemContractHelper.toL1(true, bytes32(uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY)), fullRootHash);
        SystemContractHelper.toL1(
            true,
            bytes32(uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY)),
            bytes32(uint256(uint160(_l2DAValidator)))
        );
        SystemContractHelper.toL1(
            true,
            bytes32(uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY)),
            l2DAValidatorOutputhash
        );

        /// Clear logs state
        chainedLogsHash = bytes32(0);
        numberOfLogsToProcess = 0;
        chainedMessagesHash = bytes32(0);
        chainedL1BytecodesRevealDataHash = bytes32(0);
    }
}
