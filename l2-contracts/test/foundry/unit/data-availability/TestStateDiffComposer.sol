// SPDX-License-Identifier: MIT

import {L2_TO_L1_LOG_SERIALIZE_SIZE} from "contracts/data-availability/StateDiffL2DAValidator.sol";

import {L2ContractHelper} from "contracts/L2ContractHelper.sol";

/// @notice The contract that is used in testing to compose the pubdata needed for the
/// state diff DA validator.
contract TestStateDiffComposer {
    // The following two are always correct
    // as these qre expected to be already checked by the L1Messenger
    uint256 internal logsNumber;
    bytes internal logs;

    uint256 internal messagesNumber;
    bytes internal messages;
    bytes32 public currentRollingMessagesHash;
    bytes32 public correctRollingMessagesHash;

    uint256 internal bytecodesNumber;
    bytes internal bytecodes;
    bytes32 public currentRollingBytecodesHash;
    bytes32 public correctRollingBytecodesHash;

    bytes internal uncomressedStateDiffsPart;
    bytes internal compressedStateDiffsPart;

    function appendALog() public {
        // This function is not fully implemented, i.e. we do not insert the correct
        // content of the log. The reason for that is that it is not needed for the
        // testing

        ++logsNumber;
        logs = bytes.concat(logs, new bytes(L2_TO_L1_LOG_SERIALIZE_SIZE));
    }

    function appendAMessage(bytes memory message, bool includeToArray, bool includeToCorrectHash) public {
        if (includeToArray) {
            ++messagesNumber;
            messages = bytes.concat(messages, bytes4(uint32(message.length)), message);
            currentRollingMessagesHash = keccak256(abi.encode(currentRollingMessagesHash, keccak256(message)));
        }

        if (includeToCorrectHash) {
            correctRollingMessagesHash = keccak256(abi.encode(correctRollingMessagesHash, keccak256(message)));
        }
    }

    function appendBytecode(bytes memory bytecode, bool includeToArray, bool includeToCorrectHash) public {
        if (includeToArray) {
            ++bytecodesNumber;
            bytecodes = bytes.concat(bytecodes, bytes4(uint32(bytecode.length)), bytecode);
            currentRollingBytecodesHash = keccak256(
                abi.encode(currentRollingBytecodesHash, L2ContractHelper.hashL2Bytecode(bytecode))
            );
        }
        if (includeToCorrectHash) {
            correctRollingBytecodesHash = keccak256(
                abi.encode(correctRollingBytecodesHash, L2ContractHelper.hashL2Bytecode(bytecode))
            );
        }
    }

    function setDummyStateDiffs(
        uint8 _version,
        uint24 _compressedStateDiffSize,
        uint8 _enumIndexSize,
        bytes memory _compressedStateDiffs,
        uint32 _numberOfStateDiffs,
        bytes memory _stateDiffs
    ) public {
        compressedStateDiffsPart = abi.encodePacked(
            _version,
            _compressedStateDiffSize,
            _enumIndexSize,
            _compressedStateDiffs
        );

        uncomressedStateDiffsPart = abi.encodePacked(_numberOfStateDiffs, _stateDiffs);
    }

    function getTotalPubdata() public returns (bytes memory _totalPubdata) {
        _totalPubdata = abi.encodePacked(
            uint32(logsNumber),
            logs,
            uint32(messagesNumber),
            messages,
            uint32(bytecodesNumber),
            bytecodes,
            compressedStateDiffsPart
        );
    }

    function generateTotalStateDiffsAndPubdata() public returns (bytes memory _totalL2ToL1PubdataAndStateDiffs) {
        _totalL2ToL1PubdataAndStateDiffs = abi.encodePacked(getTotalPubdata(), uncomressedStateDiffsPart);
    }
}
