/// (!) Note: this code is unused until we have modexp precompile support
/// This is draft, it is necessary to take into account the case when argsSize is less than expected (data is truncated and padded with zeroes)
/// Also we need to check sanity of Bsize, Esize, Msize

/// @dev credit to https://github.com/PaulRBerg/prb-math/blob/280fc5f77e1b21b9c54013aac51966be33f4a410/src/Common.sol#L323
function msb(x) -> result {
    let factor := shl(7, gt(x, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)) // 2^128
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(6, gt(x, 0xFFFFFFFFFFFFFFFF)) // 2^64
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(5, gt(x, 0xFFFFFFFF)) // 2^32
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(4, gt(x, 0xFFFF))  // 2^16
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(3, gt(x, 0xFF)) // 2^8
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(2, gt(x, 0xF)) // 2^4
    x := shr(factor, x)
    result := or(result, factor)
    factor := shl(1, gt(x, 0x3)) // 2^2
    x := shr(factor, x)
    result := or(result, factor)
    factor := gt(x, 0x1) // 2^1
    // No need to shift x any more.
    result := or(result, factor)
}

// modexp gas cost EIP below
// https://eips.ethereum.org/EIPS/eip-2565
// [0; 31] (32 bytes)	Bsize	Byte size of B
// [32; 63] (32 bytes)	Esize	Byte size of E
// [64; 95] (32 bytes)	Msize	Byte size of M
let Bsize := mload(argsOffset)
let Esize := mload(add(argsOffset, 0x20))

let mulComplex
{
    // mult_complexity(Bsize, Msize), EIP-2565
    let words := getMax(Bsize, mload(add(argsOffset, 0x40)))
    words := div(add(words, 7), 8) // TODO OVERFLOW CHECKS
    mulComplex := mul(words, words)
}

/*       
def calculate_iteration_count(exponent_length, exponent):
    iteration_count = 0
    if exponent_length <= 32 and exponent == 0: iteration_count = 0
    elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
    elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)
    return max(iteration_count, 1)
*/
// [96 + Bsize; 96 + Bsize + Esize]	E
let iterationCount := 0
let expOffset := add(add(argsOffset, 0x60), Bsize)
switch gt(Esize, 32)
case 0 { // if exponent_length <= 32
    let exponent := mload(expOffset) // load 32 bytes
    exponent := shr(sub(32, Esize), exponent) // shift to the right if Esize not 32 bytes

    // if exponent_length <= 32 and exponent == 0: iteration_count = 0
    // elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
    if exponent {
        iterationCount := msb(exponent)
    }
}
default { // elif exponent_length > 32
    // elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)

    // load last 32 bytes of exponent
    let exponentLast256 := mload(add(expOffset, sub(Esize, 32)))
    iterationCount := add(mul(8, sub(Esize, 32)), msb(exponentLast256))
}
if iszero(iterationCount) {
    iterationCount := 1
}

/* 
    return max(200, math.floor(multiplication_complexity * iteration_count / 3))
*/
gasToCharge := getMax(200, div(mul(mulComplex, iterationCount), 3))