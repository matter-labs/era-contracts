/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's EcPairing precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "EcPairing" {
    code {
        return(0, 0)
    }
    object "EcPairing_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            function ONE_TUPLE_BYTES_SIZE() -> ret {
                ret := mul(32, 6)
            }

            function MAX_INPUT_BYTES_SIZE() -> ret {
                ret := mul(ONE_TUPLE_BYTES_SIZE(), 3)
            }

            /// @dev The gas cost of processing ecparing circuit precompile.
            function ECPAIRING_GAS_COST() -> ret {
                ret := 7000
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

            let bytesSize := calldatasize()
            
            // Wrapper checks
            if mod(bytesSize, ONE_TUPLE_BYTES_SIZE()) {
                revert(0, 0)
            }
            if gt(bytesSize, MAX_INPUT_BYTES_SIZE()) {
                revert(0, 0)
            }

            // Copy data
            calldatacopy(0, 0, bytesSize)

            // Precompile call
            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                div(bytesSize, 32), // input length in words
                0, // output offset in words
                1, // output length in words (success, signer)
                0  // No special meaning, EcPairing circuit doesn't check this value
            )
            let gasToPay := ECPAIRING_GAS_COST()

            // Check whether the call is successfully handled by the ecrecover circuit
            let success := precompileCall(precompileParams, gasToPay)
            if iszero(success) {
                revert(0, 0)
            }
            return(0, 32)
        }
    }
}
