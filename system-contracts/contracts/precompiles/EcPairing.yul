/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecpairing precompile.
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

            /// @dev The basic gas cost of processing ecpairing circuit precompile.
            function ECPAIRING_BASE_GAS_COST() -> ret {
                ret := 100000
            }

            /// @dev The additional gas cost of processing ecpairing circuit precompile.
            /// @dev Added per pair. 
            function ECPAIRING_PAIR_GAS_COST() -> ret {
                ret := 80000
            }

            /// @dev The amount of bytes necessary for encoding G1 and G2.
            /// @dev See https://eips.ethereum.org/EIPS/eip-197 for further details.
            function CHUNK_SIZE_BYTES() -> ret {
                ret := 192
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

            /// @dev Calculate the cost of ecpairing precompile call.
            /// @param pairs represent the length of the input divided by 192.
            function ecpairingGasCost(pairs) -> ret{
                let gasPerPairs := mul(ECPAIRING_PAIR_GAS_COST(), pairs)
                ret := add(ECPAIRING_BASE_GAS_COST(), gasPerPairs)
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

            let bytesSize := calldatasize()

            // Check that the input is the multiple of pairs of G1 and G2.
            if mod(bytesSize, CHUNK_SIZE_BYTES()){
                burnGas()
            }

            let pairs := div(bytesSize, CHUNK_SIZE_BYTES())

            // We conduct all validations inside the precompileCall

            calldatacopy(0, 0, bytesSize)

            let precompileParams := unsafePackPrecompileParams(
                0,              // input offset in words
                mul(6, pairs),  // input length in words multiples of (p_x, p_x, q_x_a, q_x_b, q_y_a, q_y_b)
                0,              // output offset in words
                1,              // output length in words (pairing check boolean)
                pairs           // number of pairs
            )
            let gasToPay := ecpairingGasCost(pairs)

            let success := precompileCall(precompileParams, gasToPay)
            if not(success) {
                return(0, 0)
            }

            return(0, 64)
            
        }
    }
}
