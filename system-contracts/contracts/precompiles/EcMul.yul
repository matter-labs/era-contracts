/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecmul precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "EcMul" {
    code {
        return(0, 0)
    }
    object "EcMul_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The gas cost of processing ecmul circuit precompile.
            function ECMUL_GAS_COST() -> ret {
                ret := 7000
            }

            // ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            // ////////////////////////////////////////////////////////////////

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

            /// @notice Burns remaining gas until revert.
            /// @dev This function is used to burn gas in the case of a failed precompile call.
            function burnGas() {
                // Precompiles that do not have a circuit counterpart
                // will burn the provided gas by calling this function.
                precompileCall(0, gas())
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // Retrieve the coordinates from the calldata
            let x := calldataload(0)
            let y := calldataload(32)
            let scalar := calldataload(64)

            // We conduct all validations inside the precompileCall

            mstore(0, x)
            mstore(32, y)
            mstore(64, scalar)

            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                3, // input length in words (x, y, scalar)
                0, // output offset in words
                2, // output length in words (x, y)
                0  // No special meaning, ecmul circuit doesn't check this value
            )
            let gasToPay := ECMUL_GAS_COST()

            let success := precompileCall(precompileParams, gasToPay)
            if not(success) {
                return(0, 0)
            }
            
            return(0, 64)
        }
    }
}
