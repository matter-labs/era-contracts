// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {NotEnoughGasSupplied} from "../errors/L2ContractErrors.sol";

contract L1MessengerBurner {
    // These must match Rust constants exactly
    uint256 constant SHA3 = 30;
    uint256 constant SHA3WORD = 6;
    uint256 constant LOG = 375;
    uint256 constant LOGDATA = 8;

    // Same as Rust: L2_TO_L1_LOG_SERIALIZE_SIZE
    uint256 constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88; // set your actual value

    /// @dev ceil(x / y)
    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    /// @dev Exact Solidity equivalent of `keccak256_ergs_cost(len) / ERGS_PER_GAS`
    function gasKeccak(uint256 len) internal pure returns (uint256) {
        uint256 words = ceilDiv(len, 32);
        return SHA3 + SHA3WORD * words;
    }

    /// @dev Exact Solidity equivalent of l1_message_ergs_cost / ERGS_PER_GAS
    function estimateL1MessageGas(uint256 messageLen) internal pure returns (uint256) {
        uint256 hashing =
              gasKeccak(L2_TO_L1_LOG_SERIALIZE_SIZE)
            + gasKeccak(64) * 3
            + gasKeccak(messageLen);

        uint256 logCost = LOG + LOGDATA * messageLen;

        return hashing + logCost;
    }

    function burnGas(bytes calldata _message) external returns (bytes32 dummyHash) {
        (address sender, bytes memory rawMessage) = abi.decode(_message, (address, bytes));
        uint256 gasToBurn = estimateL1MessageGas(rawMessage.length);
        dummyHash = bytes32(0);

        uint256 endGas = gasleft() - gasToBurn;
        require(endGas > 0, "Not enough gas supplied");

        while (gasleft() > endGas) {
            // Empty
        }
    }
}
