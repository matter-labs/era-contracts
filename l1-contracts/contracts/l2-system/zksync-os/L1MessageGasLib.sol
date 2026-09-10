// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library L1MessageGasLib {
    uint256 internal constant SHA3 = 30;
    uint256 internal constant SHA3WORD = 6;
    uint256 internal constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    /// @dev Exact Solidity equivalent of `keccak256_ergs_cost(len) / ERGS_PER_GAS`
    function gasKeccak(uint256 len) internal pure returns (uint256) {
        uint256 words = ceilDiv(len, 32);
        return SHA3 + SHA3WORD * words;
    }

    /// @dev Gas equivalent of the ZKsync OS hashing cost of recording a single L2->L1 log record:
    /// hashing the 88-byte record, reconstructing the `L2ToL1Log`, and one Merkle-node hash. Shared by
    /// every system hook that records an L2->L1 log (the L1 messenger and the interop commitment leaf
    /// hook). It deliberately excludes any EVM `LOG` opcode cost — the EVM charges that on its own for
    /// whatever event the calling contract emits.
    function estimateLogGas() internal pure returns (uint256) {
        return gasKeccak(L2_TO_L1_LOG_SERIALIZE_SIZE) + gasKeccak(64) * 2;
    }

    /// @dev Exact Solidity equivalent of the ZKsync OS `emit_l1_message` native hashing cost: the base
    /// log-record cost ({estimateLogGas}) plus the extra hashing for reconstructing and hashing the
    /// variable-length message payload.
    function estimateL1MessageGas(uint256 messageLen) internal pure returns (uint256) {
        return estimateLogGas() + gasKeccak(64) + gasKeccak(messageLen);
    }
}
