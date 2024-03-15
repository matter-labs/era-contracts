/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's sha256 precompile.
 * @dev It accepts the data to be hashed, pad it by the specification
 * and uses `precompileCall` to call the zkEVM built-in precompiles.
 * @dev Thus sha256 precompile circuit operates over padded data to perform efficient sponge round computation.
 */
object "SHA256" {
    code {
        return(0, 0)
    }
    object "SHA256_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The size of the processing sha256 block in bytes.
            function BLOCK_SIZE() -> ret {
                ret := 64
            }

            /// @dev The gas cost of processing one sha256 round.
            function SHA256_ROUND_GAS_COST() -> ret {
                ret := 7
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

            // The sha256 padding includes additional 8 bytes of the total message's length in bits,
            // so calculate the "full" message length with it.
            let extendBytesLen := add(bytesSize, 8)

            let padLen := sub(BLOCK_SIZE(), mod(extendBytesLen, BLOCK_SIZE()))
            let paddedBytesSize := add(extendBytesLen, padLen)

            // The original message size in bits
            let binSize := mul(bytesSize, 8)
            // Same bin size, but shifted to the left, needed for the padding
            let leftShiftedBinSize := shl(sub(256, 64), binSize)

            // Write 0x80000... as padding according the sha256 specification
            mstore(bytesSize, 0x8000000000000000000000000000000000000000000000000000000000000000)
            // then will be some zeroes and BE encoded bit length
            mstore(sub(paddedBytesSize, 8), leftShiftedBinSize)

            let numRounds := div(paddedBytesSize, BLOCK_SIZE())
            let precompileParams := unsafePackPrecompileParams(
                0,                        // input offset in words
                // Always divisible by 32, since `BLOCK_SIZE()` is 64 bytes
                div(paddedBytesSize, 32), // input length in words (safe to pass, never exceed `type(uint32).max`)
                0,                        // output offset in words
                1,                        // output length in words
                numRounds                 // number of rounds (safe to pass, never exceed `type(uint64).max`)
            )
            let gasToPay := mul(SHA256_ROUND_GAS_COST(), numRounds)

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
