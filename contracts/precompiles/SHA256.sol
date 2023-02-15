// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "../libraries/SystemContractHelper.sol";

/**
 * @author Matter Labs
 * @notice The contract used to emulate EVM's sha256 precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
contract SHA256 {
    uint256 constant SHA256_ROUND_COST_GAS = 7;
    uint256 constant BLOCK_SIZE = 64;
    uint32 constant INPUT_OFFSET_IN_WORDS = 4;
    uint32 constant OUTPUT_OFFSET_IN_WORDS = 0;
    uint32 constant OUTPUT_LENGTH_IN_WORDS = 1;

    fallback() external {
        address codeAddress = SystemContractHelper.getCodeAddress();
        // Check that we are NOT in delegatecall
        require(codeAddress == address(this));

        unchecked {
            uint256 bytesSize = msg.data.length;
            uint256 msgBitlenWord = (bytesSize * 8) << (256 - 64); // for padding
            uint256 lastBlockSize = bytesSize % BLOCK_SIZE;
            uint256 roughPadLen = BLOCK_SIZE - lastBlockSize;
            uint256 roughPaddedByteSize = bytesSize + roughPadLen;

            uint256 numRounds = roughPaddedByteSize / BLOCK_SIZE;
            if (lastBlockSize > (64 - 8 - 1)) {
                // We need another round all together
                numRounds += 1;
                roughPaddedByteSize += 64;
            }
            uint256 offsetForBitlenWord = roughPaddedByteSize - 8;

            // Manual memory copy and management, as we do not care about Solidity allocations
            uint32 inputLengthInWords = uint32(roughPaddedByteSize / 32); // Overflow is unrealistic, safe to cast

            uint256 offset;
            assembly {
                offset := mload(0x40)
                calldatacopy(offset, 0x00, bytesSize)
                // Write 0x80000... as padding according the sha256 specification
                mstore(add(offset, bytesSize), 0x8000000000000000000000000000000000000000000000000000000000000000)
                // then will be some zeroes, and BE encoded bit length
                mstore(add(offset, offsetForBitlenWord), msgBitlenWord)
                // Note: Do not update the free memory pointer on purpose
                // Precompile call below doesn't allocate memory, so the written values wouldn't be changed
            }

            // Check the invariant of the expected offset value
            assert(offset == INPUT_OFFSET_IN_WORDS * 32);

            uint256 precompileParams = SystemContractHelper.packPrecompileParams(
                INPUT_OFFSET_IN_WORDS,
                inputLengthInWords,
                OUTPUT_OFFSET_IN_WORDS,
                OUTPUT_LENGTH_IN_WORDS,
                uint64(numRounds) // Overflow is unrealistic, safe to cast
            );

            uint256 gasToPay = SHA256_ROUND_COST_GAS * numRounds;
            bool success = SystemContractHelper.precompileCall(precompileParams, Utils.safeCastToU32(gasToPay));
            require(success);

            assembly {
                return(0, 32)
            }
        }
    }
}
