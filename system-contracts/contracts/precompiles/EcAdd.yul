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

            /// @notice Constant function for the alt_bn128 field order.
            /// @dev See https://eips.ethereum.org/EIPS/eip-196 for further details.
            /// @return ret The alt_bn128 field order.
            function P() -> ret {
                ret := 21888242871839275222246405745257275088696311157297823662689037894645226208583
            }

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

            // @notice Checks if a point is on the curve.
            // @dev The curve in question is the alt_bn128 curve.
            // @dev The Short Weierstrass equation of the curve is y^2 = x^3 + 3.
            // @param x The x coordinate of the point.
            // @param y The y coordinate of the point.
            // @return ret True if the point is on the curve, false otherwise.
            function pointIsInCurve(x, y) -> ret {
                let ySquared := mulmod(y, y, P())
                let xSquared := mulmod(x, x, P())
                let xQubed := mulmod(xSquared, x, P())
                let xQubedPlusThree := addmod(xQubed, 3, P())

                ret := eq(ySquared, xQubedPlusThree)
            }

            /// @notice Checks if a point is the point at infinity.
            /// @dev The point at infinity is defined as the point (0, 0).
            /// @dev See https://eips.ethereum.org/EIPS/eip-196 for further details.
            /// @param x The x coordinate of the point.
            /// @param y The y coordinate of the point.
            /// @return ret True if the point is the point at infinity, false otherwise.
            function isInfinity(x, y) -> ret {
                ret := iszero(or(x, y))
            }

            /// @notice Checks if a coordinate is on the curve field order.
            /// @dev A coordinate is on the curve field order if it is on the range [0, curveFieldOrder).
            /// @dev This check is required in the precompile specification. See https://eips.ethereum.org/EIPS/eip-196 for further details.
            /// @param coordinate The coordinate to check.
            /// @return ret True if the coordinate is in the range, false otherwise.
            function isOnFieldOrder(coordinate) -> ret {
                ret := lt(coordinate, P())
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // Retrieve the coordinates from the calldata
            let x1 := calldataload(0)
            let y1 := calldataload(32)
            let x2 := calldataload(64)
            let y2 := calldataload(96)


            let p1IsInfinity := isInfinity(x1, y1)
            let p2IsInfinity := isInfinity(x2, y2)

            if and(p1IsInfinity, p2IsInfinity) {
                // Infinity + Infinity = Infinity
                mstore(0, 0)
                mstore(32, 0)
                return(0, 64)
            }
            if and(p1IsInfinity, not(p2IsInfinity)) {
                // Infinity + P = P

                // Ensure that the coordinates are between 0 and the field order.
                if or(not(isOnFieldOrder(x2)), not(isOnFieldOrder(y2))) {
                    burnGas()
                }

                // Ensure that the point is in the curve (Y^2 = X^3 + 3).
                if not(pointIsInCurve(x2, y2)) {
                    burnGas()
                }

                mstore(0, x2)
                mstore(32, y2)
                return(0, 64)
            }
            if and(not(p1IsInfinity), p2IsInfinity) {
                // P + Infinity = P

                // Ensure that the coordinates are between 0 and the field order.
                if or(not(isOnFieldOrder(x1)), not(isOnFieldOrder(y1))) {
                    burnGas()
                }

                // Ensure that the point is in the curve (Y^2 = X^3 + 3).
                if not(pointIsInCurve(x1, y1)) {
                    burnGas()
                }

                mstore(0, x1)
                mstore(32, y1)
                return(0, 64)
            }

            // Ensure that the coordinates are between 0 and the field order.
            if or(not(isOnFieldOrder(x1)), not(isOnFieldOrder(y1))) {
                burnGas()
            }

            // Ensure that the coordinates are between 0 and the field order.
            if or(not(isOnFieldOrder(x2)), not(isOnFieldOrder(y2))) {
                burnGas()
            }

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
