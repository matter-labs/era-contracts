// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

enum PubdataField {
    NumberOfLogs,
    LogsHash,
    MsgHash,
    Bytecode,
    StateDiffCompressionVersion,
    ExtraData
}

error ReconstructionMismatch(PubdataField, bytes32 expected, bytes32 actual);

// 0x7f7b0cf7
// 000000000000000000000000000000000000000000000000000000000000000b
// 00000000000000000000000000000000000000000000000000000000000000a0
// a0b4000000020001000100000000000000000000000000000000000090080101
