/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's keccak256 opcode.
 * @dev It accepts the data to be hashed in the calldata, propagates it to the zkEVM built-in circuit precompile via `precompileCall`, and burns the gas.
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

            /// @dev Returns the block size used by the keccak256 hashing function.
            /// The value 136 bytes corresponds to the size of the input data block that the keccak256 
            /// algorithm processes in each round, as defined in the keccak256 specification. This is derived 
            /// from the formula (1600 - 2 * bit length of the digest) / 8, where the bit length for keccak256
            /// is 256 bits. For more details, refer to the Keccak specification at
            /// https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf#page=30
            function BLOCK_SIZE() -> ret {
                ret := 136
            }

            /// @dev The gas cost of processing one keccak256 round.
            /// @dev This constant is made equal to the corresponding constant in
            /// https://github.com/matter-labs/era-zkevm_opcode_defs/blob/v1.4.1/src/circuit_prices.rs,
            /// which was automatically generated depending on the capacity of rounds for a 
            /// single Keccak256 circuit.
            function KECCAK_ROUND_GAS_COST() -> ret {
                ret := 40
            }

            /// @dev Returns a 32-bit mask value
            function UINT32_BIT_MASK() -> ret {
                ret := 0xffffffff
            }

            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////

            /// @dev Load raw calldata fat pointer
            function getCalldataPtr() -> calldataPtr {
                calldataPtr := verbatim_0i_1o("get_global::ptr_calldata")
            }
            
            /// @dev Packs precompile parameters into one word.
            /// Note: functions expect to work with 32/64 bits unsigned integers.
            /// Caller should ensure the type matching before!
            function unsafePackPrecompileParams(
                uint32_inputOffsetInBytes,
                uint32_inputLengthInBytes,
                uint32_outputOffsetInWords,
                uint32_outputLengthInWords,
                uint32_memoryPageToRead,
                uint32_memoryPageToWrite,
                uint64_perPrecompileInterpreted
            ) -> rawParams {
                rawParams := uint32_inputOffsetInBytes
                rawParams := or(rawParams, shl(32, uint32_inputLengthInBytes))
                rawParams := or(rawParams, shl(64, uint32_outputOffsetInWords))
                rawParams := or(rawParams, shl(96, uint32_outputLengthInWords))
                rawParams := or(rawParams, shl(128, uint32_memoryPageToRead))
                rawParams := or(rawParams, shl(160, uint32_memoryPageToWrite))
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
            
            // 1. Load raw calldata fat pointer
            let calldataFatPtr := getCalldataPtr()

            // 2. Parse calldata fat pointer
            let ptrMemoryPage := and(shr(32, calldataFatPtr), UINT32_BIT_MASK())
            let ptrStart := and(shr(64, calldataFatPtr), UINT32_BIT_MASK())
            let ptrLength := and(shr(96, calldataFatPtr), UINT32_BIT_MASK())

            // 3. Pack precompile parameters
            let precompileParams := unsafePackPrecompileParams(
                ptrStart,                         // input offset in bytes
                ptrLength,                        // input length in bytes (safe to pass, never exceed `type(uint32).max`)
                0,                                // output offset in words
                1,                                // output length in words (NOTE: VM doesn't check this value for now, but this could change in future)
                ptrMemoryPage,                    // memory page to read from
                0,                                // memory page to write to (0 means write to heap)
                0                                 // per precompile interpreted value (0 since circuit doesn't react on this value anyway)
            )
            // 4. Calculate number of required hash rounds per calldata
            let numRounds := add(div(ptrLength, BLOCK_SIZE()), 1)
            let gasToPay := mul(KECCAK_ROUND_GAS_COST(), numRounds)

            // 5. Call precompile
            let success := precompileCall(precompileParams, gasToPay)
            if iszero(success) {
                revert(0, 0)
            }
            return(0, 32)
        }
    }
}
