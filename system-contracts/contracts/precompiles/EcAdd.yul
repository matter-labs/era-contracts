object "EcAdd" {
    code {
        return(0, 0)
    }
    object "EcAdd_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @notice Constant function for value three in Montgomery form.
            /// @dev This value was precomputed using Python.
            /// @return m_three The value three in Montgomery form.
            function MONTGOMERY_THREE() -> m_three {
                m_three := 19052624634359457937016868847204597229365286637454337178037183604060995791063
            }

            /// @notice Constant function for the alt_bn128 field order.
            /// @dev See https://eips.ethereum.org/EIPS/eip-196 for further details.
            /// @return ret The alt_bn128 field order.
            function P() -> ret {
                ret := 21888242871839275222246405745257275088696311157297823662689037894645226208583
            }

            /// @notice Constant function for the pre-computation of R^2 % N for the Montgomery REDC algorithm.
            /// @dev R^2 is the Montgomery residue of the value 2^512.
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further detals.
            /// @dev This value was precomputed using Python.
            /// @return ret The value R^2 modulus the curve field order.
            function R2_MOD_P() -> ret {
                ret := 3096616502983703923843567936837374451735540968419076528771170197431451843209
            }

            /// @notice Constant function for the pre-computation of N' for the Montgomery REDC algorithm.
            /// @dev N' is a value such that NN' = -1 mod R, with N being the curve field order.
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further detals.
            /// @dev This value was precomputed using Python.
            /// @return ret The value N'.
            function N_PRIME() -> ret {
                ret := 111032442853175714102588374283752698368366046808579839647964533820976443843465
            }

            //////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            //////////////////////////////////////////////////////////////////

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

            /// @notice Retrieves the highest half of the multiplication result.
            /// @param multiplicand The value to multiply.
            /// @param multiplier The multiplier.
            /// @return ret The highest half of the multiplication result.
            function getHighestHalfOfMultiplication(multiplicand, multiplier) -> ret {
                ret := verbatim_2i_1o("mul_high", multiplicand, multiplier)
            }

            /// @notice Computes the modular subtraction of two values.
            /// @param minuend The value to subtract from.
            /// @param subtrahend The value to subtract.
            /// @param modulus The modulus.
            /// @return difference The modular subtraction of the two values.
            function submod(minuend, subtrahend, modulus) -> difference {
                difference := addmod(minuend, sub(modulus, subtrahend), modulus)
            }

            /// @notice Computes an addition and checks for overflow.
            /// @param augend The value to add to.
            /// @param addend The value to add.
            /// @return sum The sum of the two values.
            /// @return overflowed True if the addition overflowed, false otherwise.
            function overflowingAdd(augend, addend) -> sum, overflowed {
                sum := add(augend, addend)
                overflowed := lt(sum, augend)
            }

            // @notice Checks if a point is on the curve.
            // @dev The curve in question is the alt_bn128 curve.
            // @dev The Short Weierstrass equation of the curve is y^2 = x^3 + 3.
            // @param x The x coordinate of the point in Montgomery form.
            // @param y The y coordinate of the point in Montgomery form.
            // @return ret True if the point is on the curve, false otherwise.
            function pointIsInCurve(x, y) -> ret {
                let ySquared := montgomeryMul(y, y)
                let xSquared := montgomeryMul(x, x)
                let xQubed := montgomeryMul(xSquared, x)
                let xQubedPlusThree := montgomeryAdd(xQubed, MONTGOMERY_THREE())

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

            /// @notice Computes the inverse in Montgomery Form of a number in Montgomery Form.
            /// @dev Reference: https://github.com/lambdaclass/lambdaworks/blob/main/math/src/field/fields/montgomery_backed_prime_fields.rs#L169
            /// @dev Let `base` be a number in Montgomery Form, then base = a*R mod P() being `a` the base number (not in Montgomery Form)
            /// @dev Let `inv` be the inverse of a number `a` in Montgomery Form, then inv = a^(-1)*R mod P()
            /// @dev The original binary extended euclidean algorithms takes a number a and returns a^(-1) mod N
            /// @dev In our case N is P(), and we'd like the input and output to be in Montgomery Form (a*R mod P() 
            /// @dev and a^(-1)*R mod P() respectively).
            /// @dev If we just pass the input as a number in Montgomery Form the result would be a^(-1)*R^(-1) mod P(),
            /// @dev but we want it to be a^(-1)*R mod P().
            /// @dev For that, we take advantage of the algorithm's linearity and multiply the result by R^2 mod P()
            /// @dev to get R^2*a^(-1)*R^(-1) mod P() = a^(-1)*R mod P() as the desired result in Montgomery Form.
            /// @dev `inv` takes the value of `b` or `c` being the result sometimes `b` and sometimes `c`. In paper
            /// @dev multiplying `b` or `c` by R^2 mod P() results on starting their values as b = R2_MOD_P() and c = 0.
            /// @param base A number `a` in Montgomery Form, then base = a*R mod P().
            /// @return inv The inverse of a number `a` in Montgomery Form, then inv = a^(-1)*R mod P().
            function binaryExtendedEuclideanAlgorithm(base) -> inv {
                let modulus := P()
                let u := base
                let v := modulus
                // Avoids unnecessary reduction step.
                let b := R2_MOD_P()
                let c := 0

                for {} and(iszero(eq(u, 1)), iszero(eq(v, 1))) {} {
                    for {} iszero(and(u, 1)) {} {
                        u := shr(1, u)
                        let current := b
                        switch and(current, 1)
                        case 0 {
                            b := shr(1, b)
                        }
                        case 1 {
                            b := shr(1, add(b, modulus))
                        }
                    }

                    for {} iszero(and(v, 1)) {} {
                        v := shr(1, v)
                        let current := c
                        switch and(current, 1)
                        case 0 {
                            c := shr(1, c)
                        }
                        case 1 {
                            c := shr(1, add(c, modulus))
                        }
                    }

                    switch gt(v, u)
                    case 0 {
                        u := sub(u, v)
                        if lt(b, c) {
                            b := add(b, modulus)
                        }
                        b := sub(b, c)
                    }
                    case 1 {
                        v := sub(v, u)
                        if lt(c, b) {
                            c := add(c, modulus)
                        }
                        c := sub(c, b)
                    }
                }

                switch eq(u, 1)
                case 0 {
                    inv := c
                }
                case 1 {
                    inv := b
                }
            }

            /// @notice Implementation of the Montgomery reduction algorithm (a.k.a. REDC).
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm
            /// @param lowestHalfOfT The lowest half of the value T.
            /// @param higherHalfOfT The higher half of the value T.
            /// @return S The result of the Montgomery reduction.
            function REDC(lowestHalfOfT, higherHalfOfT) -> S {
                let m := mul(lowestHalfOfT, N_PRIME())
                let hi := add(higherHalfOfT, getHighestHalfOfMultiplication(m, P()))
                let lo, overflowed := overflowingAdd(lowestHalfOfT, mul(m, P()))
                if overflowed {
                    hi := add(hi, 1)
                }
                S := hi
                if iszero(lt(hi, P())) {
                    S := sub(hi, P())
                }
            }

            /// @notice Encodes a field element into the Montgomery form using the Montgomery reduction algorithm (REDC).
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further details on transforming a field element into the Montgomery form.
            /// @param a The field element to encode.
            /// @return ret The field element in Montgomery form.
            function intoMontgomeryForm(a) -> ret {
                let hi := getHighestHalfOfMultiplication(a, R2_MOD_P())
                let lo := mul(a, R2_MOD_P())
                ret := REDC(lo, hi)
            }

            /// @notice Decodes a field element out of the Montgomery form using the Montgomery reduction algorithm (REDC).
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further details on transforming a field element out of the Montgomery form.
            /// @param m The field element in Montgomery form to decode.
            /// @return ret The decoded field element.
            function outOfMontgomeryForm(m) -> ret {
                let hi := 0
                let lo := m
                ret := REDC(lo, hi)
            }

            /// @notice Computes the Montgomery addition.
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further details on the Montgomery multiplication.
            /// @param augend The augend in Montgomery form.
            /// @param addend The addend in Montgomery form.
            /// @return ret The result of the Montgomery addition.
            function montgomeryAdd(augend, addend) -> ret {
                ret := add(augend, addend)
                if iszero(lt(ret, P())) {
                    ret := sub(ret, P())
                }
            }

            /// @notice Computes the Montgomery subtraction.
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further details on the Montgomery multiplication.
            /// @param minuend The minuend in Montgomery form.
            /// @param subtrahend The subtrahend in Montgomery form.
            /// @return ret The result of the Montgomery subtraction.
            function montgomerySub(minuend, subtrahend) -> ret {
                ret := montgomeryAdd(minuend, sub(P(), subtrahend))
            }

            /// @notice Computes the Montgomery multiplication using the Montgomery reduction algorithm (REDC).
            /// @dev See https://en.wikipedia.org/wiki/Montgomery_modular_multiplication#The_REDC_algorithm for further details on the Montgomery multiplication.
            /// @param multiplicand The multiplicand in Montgomery form.
            /// @param multiplier The multiplier in Montgomery form.
            /// @return ret The result of the Montgomery multiplication.
            function montgomeryMul(multiplicand, multiplier) -> ret {
                let higherHalfOfProduct := getHighestHalfOfMultiplication(multiplicand, multiplier)
                let lowestHalfOfProduct := mul(multiplicand, multiplier)
                ret := REDC(lowestHalfOfProduct, higherHalfOfProduct)
            }

            /// @notice Computes the Montgomery modular inverse skipping the Montgomery reduction step.
            /// @dev The Montgomery reduction step is skept because a modification in the binary extended Euclidean algorithm is used to compute the modular inverse.
            /// @dev See the function `binaryExtendedEuclideanAlgorithm` for further details.
            /// @param a The field element in Montgomery form to compute the modular inverse of.
            /// @return invmod The result of the Montgomery modular inverse (in Montgomery form).
            function montgomeryModularInverse(a) -> invmod {
                invmod := binaryExtendedEuclideanAlgorithm(a)
            }

            /// @notice Computes the Montgomery division.
            /// @dev The Montgomery division is computed by multiplying the dividend with the modular inverse of the divisor.
            /// @param dividend The dividend in Montgomery form.
            /// @param divisor The divisor in Montgomery form.
            /// @return quotient The result of the Montgomery division.
            function montgomeryDiv(dividend, divisor) -> quotient {
                quotient := montgomeryMul(dividend, montgomeryModularInverse(divisor))
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
            if and(p1IsInfinity, iszero(p2IsInfinity)) {
                // Infinity + P = P

                // Ensure that the coordinates are between 0 and the field order.
                if or(iszero(isOnFieldOrder(x2)), iszero(isOnFieldOrder(y2))) {
                    burnGas()
                }

                let m_x2 := intoMontgomeryForm(x2)
                let m_y2 := intoMontgomeryForm(y2)

                // Ensure that the point is in the curve (Y^2 = X^3 + 3).
                if iszero(pointIsInCurve(m_x2, m_y2)) {
                    burnGas()
                }

                // We just need to go into the Montgomery form to perform the
                // computations in pointIsInCurve, but we do not need to come back.

                mstore(0, x2)
                mstore(32, y2)
                return(0, 64)
            }
            if and(iszero(p1IsInfinity), p2IsInfinity) {
                // P + Infinity = P

                // Ensure that the coordinates are between 0 and the field order.
                if or(iszero(isOnFieldOrder(x1)), iszero(isOnFieldOrder(y1))) {
                    burnGas()
                }

                let m_x1 := intoMontgomeryForm(x1)
                let m_y1 := intoMontgomeryForm(y1)

                // Ensure that the point is in the curve (Y^2 = X^3 + 3).
                if iszero(pointIsInCurve(m_x1, m_y1)) {
                    burnGas()
                }

                // We just need to go into the Montgomery form to perform the
                // computations in pointIsInCurve, but we do not need to come back.

                mstore(0, x1)
                mstore(32, y1)
                return(0, 64)
            }

            // Ensure that the coordinates are between 0 and the field order.
            if or(iszero(isOnFieldOrder(x1)), iszero(isOnFieldOrder(y1))) {
                burnGas()
            }

            // Ensure that the coordinates are between 0 and the field order.
            if or(iszero(isOnFieldOrder(x2)), iszero(isOnFieldOrder(y2))) {
                burnGas()
            }

            // There's no need for transforming into Montgomery form
            // for this case.
            if and(eq(x1, x2), eq(submod(0, y1, P()), y2)) {
                // P + (-P) = Infinity

                let m_x1 := intoMontgomeryForm(x1)
                let m_y1 := intoMontgomeryForm(y1)
                let m_x2 := intoMontgomeryForm(x2)
                let m_y2 := intoMontgomeryForm(y2)

                // Ensure that the points are in the curve (Y^2 = X^3 + 3).
                if or(iszero(pointIsInCurve(m_x1, m_y1)), iszero(pointIsInCurve(m_x2, m_y2))) {
                    burnGas()
                }

                // We just need to go into the Montgomery form to perform the
                // computations in pointIsInCurve, but we do not need to come back.

                mstore(0, 0)
                mstore(32, 0)
                return(0, 64)
            }

            if and(eq(x1, x2), and(iszero(eq(y1, y2)), iszero(eq(y1, submod(0, y2, P()))))) {
                burnGas()
            }

            if and(eq(x1, x2), eq(y1, y2)) {
                // P + P = 2P

                let x := intoMontgomeryForm(x1)
                let y := intoMontgomeryForm(y1)

                // Ensure that the points are in the curve (Y^2 = X^3 + 3).
                if iszero(pointIsInCurve(x, y)) {
                    burnGas()
                }

                // (3 * x1^2 + a) / (2 * y1)
                let x1_squared := montgomeryMul(x, x)
                let slope := montgomeryDiv(addmod(x1_squared, addmod(x1_squared, x1_squared, P()), P()), addmod(y, y, P()))
                // x3 = slope^2 - 2 * x1
                let x3 := submod(montgomeryMul(slope, slope), addmod(x, x, P()), P())
                // y3 = slope * (x1 - x3) - y1
                let y3 := submod(montgomeryMul(slope, submod(x, x3, P())), y, P())

                x3 := outOfMontgomeryForm(x3)
                y3 := outOfMontgomeryForm(y3)

                mstore(0, x3)
                mstore(32, y3)
                return(0, 64)
            }

            // P1 + P2 = P3

            x1 := intoMontgomeryForm(x1)
            y1 := intoMontgomeryForm(y1)
            x2 := intoMontgomeryForm(x2)
            y2 := intoMontgomeryForm(y2)

            // Ensure that the points are in the curve (Y^2 = X^3 + 3).
            if or(iszero(pointIsInCurve(x1, y1)), iszero(pointIsInCurve(x2, y2))) {
                burnGas()
            }

            // (y2 - y1) / (x2 - x1)
            let slope := montgomeryDiv(submod(y2, y1, P()), submod(x2, x1, P()))
            // x3 = slope^2 - x1 - x2
            let x3 := submod(montgomeryMul(slope, slope), addmod(x1, x2, P()), P())
            // y3 = slope * (x1 - x3) - y1
            let y3 := submod(montgomeryMul(slope, submod(x1, x3, P())), y1, P())

            x3 := outOfMontgomeryForm(x3)
            y3 := outOfMontgomeryForm(y3)

            mstore(0, x3)
            mstore(32, y3)
            return(0, 64)
        }
    }
}
