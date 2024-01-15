/**
 * @author Matter Labs
 * @notice The contract used to emulate EVM's keccak256 opcode.
 * @dev It accepts the data to be hashed in the calldata, propagate it to the zkEVM built-in circuit precompile via `precompileCall` and burn .
 */
 object "Keccak256" {
    code { }
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
            let numRounds := div(add(ptrLength, sub(BLOCK_SIZE(), 1)), BLOCK_SIZE())
            let gasToPay := 0

            // 5. Call precompile
            let success := precompileCall(precompileParams, gasToPay)
            if iszero(success) {
                revert(0, 0)
            }
            return(0, 32)
        }
    }
}
