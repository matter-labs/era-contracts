// SPDX-License-Identifier: MIT

object "EcPairing" {
    code {
        return(0, 0)
    }
    object "EcPairing_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The base gas cost of the ECPAIRING precompile.
            /// @notice This base cost is *not charged* per call, because each pairing
            ///         operation fully occupies one circuit slot. Hence, the base cost is 0.
            function ECPAIRING_BASE_GAS_COST() -> ret {
                /// In this circuit design, we execute exactly 1 pairing per circuit.
                /// So there's no need for a separate base cost per invocation.
                ret := 0
            }

            /// @dev The per-pair gas cost of ECPAIRING precompile.
            /// @notice Each pairing occupies an entire circuit, and is charged the full
            ///         circuit budget of `BASE_CIRCUIT_GAS = 80_000`.
            ///         This ensures gas accounting aligns with ZK circuit usage.
            ///
            /// @return ret The gas cost per G1-G2 pairing operation.
            function ECPAIRING_PAIR_GAS_COST() -> ret {
                ret := 80000
            }

            /// @dev The amount of bytes necessary for encoding G1 and G2.
            /// @dev See https://eips.ethereum.org/EIPS/eip-197 for further details.
            function CHUNK_SIZE_BYTES() -> ret {
                ret := 192
            }

            /// @notice The maximum value of the `uint32` type.
            function UINT32_MAX() -> ret {
                // 2^32 - 1
                ret := 4294967295
            }

            //////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            //////////////////////////////////////////////////////////////////

            /// @dev Packs precompile parameters into one word.
            /// Note: functions expect to work with 32/64 bits unsigned integers.
            /// Caller should ensure the type matching before!
            ///
            /// @notice The layout is as follows (from least to most significant bits):
            /// - [0..32)    uint32_inputOffsetInWords
            /// - [32..64)   uint32_inputLengthInWords
            /// - [64..96)   uint32_outputOffsetInWords
            /// - [96..128)  uint32_outputLengthInWords
            /// - [128..192) Reserved (e.g. memoryPageToRead / memoryPageToWrite) — currently unused and left as 0
            /// - [192..256) uint64_perPrecompileInterpreted (left-aligned in the 256-bit word)
            ///
            /// All fields except the last are packed contiguously into the lower 128 bits.
            /// The final `uint64_perPrecompileInterpreted` is left-aligned (i.e., stored in the top 64 bits),
            /// as memoryPageToRead and memoryPageToWrite are assumed to be zero and not used.
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
                // memoryPageToRead and memoryPageToWrite left as zero (bits 128..192)
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
            if iszero(bytesSize) {
                mstore(0, true)
                return(0, 32)
            }

            // Check that the input is the multiple of pairs of G1 and G2.
            if mod(bytesSize, CHUNK_SIZE_BYTES()){
                burnGas()
            }

            let pairs := div(bytesSize, CHUNK_SIZE_BYTES())

            // We conduct all validations inside the precompileCall
            calldatacopy(0, 0, bytesSize)

            let precompileParams := unsafePackPrecompileParams(
                0,              // input offset in words
                mul(6, pairs),  // input length in words multiples of (p_x, p_y, q_x_a, q_x_b, q_y_a, q_y_b)
                0,              // output offset in words
                2,              // output length in words with success (pairing check boolean)
                pairs           // number of pairs
            )
            let gasToPay := ecpairingGasCost(pairs)
            // Ensure the ecpairing cost does not exceed the maximum value of a `uint32`.
            // This scenario should never occur in practice given the large number of allocated bytes needed,
            // but we include the check as a safeguard.
            if gt(gasToPay, UINT32_MAX()) {
                gasToPay := UINT32_MAX()
            }

            let success := precompileCall(precompileParams, gasToPay)
            let internalSuccess := mload(0)

            switch and(success, internalSuccess)
            case 0 {
                revert(0, 0)
            }
            default {
                return(32, 32)
            }

        }
    }
}
