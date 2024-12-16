// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

enum PubdataField {
    MsgHash,
    Bytecode,
    StateDiffCompressionVersion,
    ExtraData
}

error ReconstructionMismatch(PubdataField, bytes32 expected, bytes32 actual);
