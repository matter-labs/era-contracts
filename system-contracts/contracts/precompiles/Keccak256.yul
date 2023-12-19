/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's keccak256 opcode.
 * @dev It accepts the data to be hashed, pad it by the specification 
 * and uses `precompileCall` to call the zkEVM built-in precompiles.
 * @dev Thus keccak256 precompile circuit operates over padded data to perform efficient sponge round computation.
 */
object "Keccak256" {
    code {
        return(0, 0)
    }
    object "Keccak256_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The size of the processing keccak256 block in bytes.
            function BLOCK_SIZE() -> ret {
                ret := 136
            }

            /// @dev The gas cost of processing one keccak256 round.
            function KECCAK_ROUND_GAS_COST() -> ret {
                ret := 40
            }

            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////
            
            // @dev Packs precompile parameters into one word.
            // Note: functions expect to work with 32/64 bits unsigned integers.
            // Caller should ensure the type matching before!
            function unsafePackPrecompileParams(
                uint32_inputOffsetInWords,
                uint32_inputLengthInWords,
                uint32_outputOffsetInWords,
                uint32_outputLengthInWords,
                uint64_perPrecompileInterpreted
            ) -> rawParams {
                rawParams := uint32_inputOffsetInWords
                rawParams := or(rawParams, shl(32, uint32_inputLengthInWords))
                rawParams := or(rawParams, shl(64, uint32_outputOffsetInWords))
                rawParams := or(rawParams, shl(96, uint32_outputLengthInWords))
                rawParams := or(rawParams, shl(192, uint64_perPrecompileInterpreted))
            }

            /// @dev Executes the `precompileCall` opcode.
            function precompileCall(precompileParams, gasToBurn) -> ret {
                // Compiler simulation for calling `precompileCall` opcode
                ret := verbatim_2i_1o("precompile", precompileParams, gasToBurn)
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // Copy calldata to memory for pad it
            let bytesSize := calldatasize()
            calldatacopy(0, 0, bytesSize)

            let precompileParams
            let gasToPay

            // Most often keccak256 is called with "short" input, so optimize it as a special case.
            // NOTE: we consider the special case for sizes less than `BLOCK_SIZE() - 1`, so
            // there is only one round and it is and padding can be done branchless
            switch lt(bytesSize, sub(BLOCK_SIZE(), 1))
            case true {
                // Write the 0x01 after the payload bytes and 0x80 at last byte of padded bytes
                mstore(bytesSize, 0x0100000000000000000000000000000000000000000000000000000000000000)
                mstore(
                    sub(BLOCK_SIZE(), 1),
                    0x8000000000000000000000000000000000000000000000000000000000000000
                )
                
                precompileParams := unsafePackPrecompileParams(
                    0, // input offset in words
                    5, // input length in words (Math.ceil(136/32) = 5)
                    0, // output offset in words
                    1, // output length in words
                    1  // number of rounds
                )
                gasToPay := KECCAK_ROUND_GAS_COST()
            }
            default {
                let padLen := sub(BLOCK_SIZE(), mod(bytesSize, BLOCK_SIZE()))
                let paddedByteSize := add(bytesSize, padLen)

                switch eq(padLen, 1)
                case true {
                    // Write 0x81 after the payload bytes
                    mstore(bytesSize, 0x8100000000000000000000000000000000000000000000000000000000000000)
                } 
                default {
                    // Write the 0x01 after the payload bytes and 0x80 at last byte of padded bytes
                    mstore(bytesSize, 0x0100000000000000000000000000000000000000000000000000000000000000)
                    mstore(
                        sub(paddedByteSize, 1),
                        0x8000000000000000000000000000000000000000000000000000000000000000
                    )
                }
                
                let numRounds := div(paddedByteSize, BLOCK_SIZE())
                precompileParams := unsafePackPrecompileParams(
                    0,                                // input offset in words
                    div(add(paddedByteSize, 31), 32), // input length in words (safe to pass, never exceed `type(uint32).max`)
                    0,                                // output offset in words
                    1,                                // output length in words
                    numRounds                         // number of rounds (safe to pass, never exceed `type(uint64).max`)
                )
                gasToPay := mul(KECCAK_ROUND_GAS_COST(), numRounds)
            }

            let success := precompileCall(precompileParams, gasToPay)

            switch success
            case 0 {
                revert(0, 0)
            }
            default {
                return(0, 32)
            }
        }
    }
}
