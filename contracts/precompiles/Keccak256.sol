// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "../libraries/SystemContractHelper.sol";
import "../libraries/Utils.sol";

/**
 * @author Matter Labs
 * @notice The contract used to emulate EVM's keccak256 opcode.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
contract Keccak256 is ISystemContract {
    uint256 constant KECCAK_ROUND_COST_GAS = 40;
    uint256 constant BLOCK_SIZE = 136;
    uint32 constant INPUT_OFFSET_IN_WORDS = 4;
    uint32 constant OUTPUT_OFFSET_IN_WORDS = 0;
    uint32 constant OUTPUT_LENGTH_IN_WORDS = 1;

    fallback() external {
        address codeAddress = SystemContractHelper.getCodeAddress();
        // Check that we are NOT in delegatecall
        require(codeAddress == address(this));

        unchecked {
            uint256 bytesSize = msg.data.length;
            uint256 padLen = BLOCK_SIZE - (bytesSize % BLOCK_SIZE);
            uint256 paddedByteSize = bytesSize + padLen;
            uint256 numRounds = paddedByteSize / BLOCK_SIZE;

            // Manual memory copy and management, as we do not care about Solidity allocations
            uint32 inputLengthInWords = uint32((paddedByteSize + 31) / 32); // Overflow is unrealistic, safe to cast

            uint256 offset;
            // Get the offset from the free memory pointer and store precompile input there and
            assembly {
                offset := mload(0x40)
                calldatacopy(offset, 0x00, bytesSize)
                // Note: Do not update the free memory pointer on purpose
                // Precompile call below doesn't allocate memory, so the written values wouldn't be changed
            }

            // Check the invariant of the expected offset value
            assert(offset == INPUT_OFFSET_IN_WORDS * 32);

            if (padLen == 1) {
                // Write 0x81 after the payload bytes
                assembly {
                    mstore(add(offset, bytesSize), 0x8100000000000000000000000000000000000000000000000000000000000000)
                }
            } else {
                // Write the 0x01 after the payload bytes and 0x80 at last byte of padded bytes
                assembly {
                    mstore(add(offset, bytesSize), 0x0100000000000000000000000000000000000000000000000000000000000000)
                    mstore(
                        sub(add(offset, paddedByteSize), 1),
                        0x8000000000000000000000000000000000000000000000000000000000000000
                    )
                }
            }

            uint256 precompileParams = SystemContractHelper.packPrecompileParams(
                INPUT_OFFSET_IN_WORDS,
                inputLengthInWords,
                OUTPUT_OFFSET_IN_WORDS,
                OUTPUT_LENGTH_IN_WORDS,
                uint64(numRounds) // Overflow is unrealistic, safe to cast
            );

            uint256 gasToPay = KECCAK_ROUND_COST_GAS * numRounds;
            bool success = SystemContractHelper.precompileCall(precompileParams, Utils.safeCastToU32(gasToPay));
            require(success);

            assembly {
                return(0, 32)
            }
        }
    }
}
