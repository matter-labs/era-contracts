/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that emulates RIP-7212's P256VERIFY precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "P256Verify" {
    code {
        return(0, 0)
    }
    object "P256Verify_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The gas cost of processing V circuit precompile.
            function P256_VERIFY_GAS_COST() -> ret {
                ret := 12000
            }

            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////
            
            /// @dev Packs precompile parameters into one word.
            /// Note: functions expect to work with 32/64 bits unsigned integers.
            /// Caller should ensure the type matching before!
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

            if iszero(eq(calldatasize(), 160)) {
                return(0, 0)
            }

            let digest := calldataload(0)
            let r := calldataload(32)
            let s := calldataload(64)
            let x := calldataload(96)
            let y := calldataload(128)

            // The validity of the input as it is done in the internal precompile implementation.

            // Store the data in memory, so the secp256r1 circuit will read it 
            mstore(0, digest)
            mstore(32, r)
            mstore(64, s)
            mstore(96, x)
            mstore(128, y)

            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                5, // input length in words (the signed digest, r, s, x, y)
                0, // output offset in words
                1, // output length in words (success)
                0  // No special meaning, secp256r1 circuit doesn't check this value
            )
            let gasToPay := P256_VERIFY_GAS_COST()

            // Check whether the call is successfully handled by the secp256r1 circuit
            let success := precompileCall(precompileParams, gasToPay)
            let internalSuccess := mload(0)

            switch and(success, internalSuccess)
            case 0 {
                return(0, 0)
            }
            default {
                // The circuits might write `0` to the memory, while providing `internalSuccess` as `1`, so
                // we double check here.
                let writtenValue := mload(32)
                if eq(writtenValue, 0) {
                    return(0, 0)
                }

                return(32, 32)
            }
        }
    }
}
