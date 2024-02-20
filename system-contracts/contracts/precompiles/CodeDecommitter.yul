/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecrecover precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "Sekp256r1" {
    code {
        return(0, 0)
    }
    object "Sekp256r1_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            // Group order of secp256r1, see https://eips.ethereum.org/EIPS/eip-7212
            function SECP256K1_GROUP_SIZE() -> ret {
                ret := 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
            }

            // Curve prime field modulus, see https://eips.ethereum.org/EIPS/eip-7212
            function PRIME_FIELD_MODULUS() -> ret {
                ret := 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
            }

            // The short weierstrass form of the curve is y^2 ≡ x^3 + ax + b.
            // This function returns the first (`a`) coeficient
            function ELLIPTIC_CURVE_WEIERSTRASS_FIRST_COEFICIENT() -> ret {
                ret := 0xffffffff00000001000000000000000000000000fffffffffffffffffffffffc
            }

            // The short weierstrass form of the curve is y^2 ≡ x^3 + ax + b.
            // This function returns the second (`b`) coeficient
            function ELLIPTIC_CURVE_WEIERSTRASS_SECOND_COEFICIENT() -> ret {
                ret := 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
            }

            /// @dev The gas cost of processing ecrecover circuit precompile.
            /// TODO: amend the price according to costs
            function ECRECOVER_GAS_COST() -> ret {
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


            let success := verbatim_2i_1o("decommit", 0, 0)
        }
    }
}
