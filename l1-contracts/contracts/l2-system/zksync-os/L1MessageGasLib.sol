// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library L1MessageGasLib {
    uint256 internal constant SHA3 = 30;
    uint256 internal constant SHA3WORD = 6;
    uint256 internal constant LOG = 375;
    uint256 internal constant LOGDATA = 8;
    uint256 internal constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    /// @dev Exact Solidity equivalent of `keccak256_ergs_cost(len) / ERGS_PER_GAS`
    function gasKeccak(uint256 len) internal pure returns (uint256) {
        uint256 words = ceilDiv(len, 32);
        return SHA3 + SHA3WORD * words;
    }

    /// @dev Exact Solidity equivalent of `l1_message_ergs_cost / ERGS_PER_GAS`
    function estimateL1MessageGas(uint256 messageLen) internal pure returns (uint256) {
        uint256 hashing = gasKeccak(L2_TO_L1_LOG_SERIALIZE_SIZE) + gasKeccak(64) * 3 + gasKeccak(messageLen);
        uint256 logCost = LOG + LOGDATA * messageLen;
        return hashing + logCost;
    }
}
