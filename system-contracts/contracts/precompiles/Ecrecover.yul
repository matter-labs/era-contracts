/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecrecover precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
object "Ecrecover" {
    code {
        return(0, 0)
    }
    object "Ecrecover_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            // Group order of secp256k1, see https://en.bitcoin.it/wiki/Secp256k1
            function SECP256K1_GROUP_SIZE() -> ret {
                ret := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
            }

            /// @dev The gas cost of processing ecrecover circuit precompile.
            function ECRECOVER_GAS_COST() -> ret {
                ret := 1112
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

            let digest := calldataload(0)
            let v := calldataload(32)
            let r := calldataload(64)
            let s := calldataload(96)

            // Validate the input by the yellow paper rules (Appendix E. Precompiled contracts)
            let vIsInvalid := iszero(or(eq(v, 27), eq(v, 28)))
            let sIsInvalid := or(eq(s, 0), gt(s, sub(SECP256K1_GROUP_SIZE(), 1)))
            let rIsInvalid := or(eq(r, 0), gt(r, sub(SECP256K1_GROUP_SIZE(), 1)))

            if or(vIsInvalid, or(sIsInvalid, rIsInvalid)) {
                return(0, 0)
            }

            // Store the data in memory, so the ecrecover circuit will read it 
            mstore(0, digest)
            mstore(32, sub(v, 27))
            mstore(64, r)
            mstore(96, s)

            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                4, // input length in words (the signed digest, v, r, s)
                0, // output offset in words
                2, // output length in words (success, signer)
                0  // No special meaning, ecrecover circuit doesn't check this value
            )
            let gasToPay := ECRECOVER_GAS_COST()

            // Check whether the call is successfully handled by the ecrecover circuit
            let success := precompileCall(precompileParams, gasToPay)
            let internalSuccess := mload(0)

            switch and(success, internalSuccess)
            case 0 {
                return(0, 0)
            }
            default {
                return(32, 32)
            }
        }
    }
}
