/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecadd precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "EcAdd" {
    code {
        return(0, 0)
    }
    object "EcAdd_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The gas cost of processing ecadd circuit precompile.
            function ECADD_GAS_COST() -> ret {
                ret := 300
            }

            //////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            //////////////////////////////////////////////////////////////////

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
            let x1 := calldataload(0)
            let y1 := calldataload(32)
            let x2 := calldataload(64)
            let y2 := calldataload(96)

            // We conduct all validations inside the precompileCall

            mstore(0, x1)
            mstore(32, y1)
            mstore(64, x2)
            mstore(96, y2)

            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                4, // input length in words (x1, y1, x2, y2)
                0, // output offset in words
                2, // output length in words (x, y)
                0  // No special meaning, ecadd circuit doesn't check this value
            )
            let gasToPay := ECADD_GAS_COST()

            let success := precompileCall(precompileParams, gasToPay)
            if not(success) {
                return(0, 0)
            }

            return(0, 64)
        }
    }
}
