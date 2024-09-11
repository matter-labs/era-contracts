function SYSTEM_CONTRACTS_OFFSET() -> offset {
    offset := 0x8000
}

function ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008002
}

function NONCE_HOLDER_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008003
}

function DEPLOYER_SYSTEM_CONTRACT() -> addr {
    addr :=  0x0000000000000000000000000000000000008006
}

function CODE_ADDRESS_CALL_ADDRESS() -> addr {
    addr := 0x000000000000000000000000000000000000FFFE
}

function CODE_ORACLE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008012
}

function EVM_GAS_MANAGER_CONTRACT() -> addr {   
    addr :=  0x0000000000000000000000000000000000008013
}

function CALLFLAGS_CALL_ADDRESS() -> addr {
    addr := 0x000000000000000000000000000000000000FFEF
}

function DEBUG_SLOT_OFFSET() -> offset {
    offset := mul(32, 32)
}

function LAST_RETURNDATA_SIZE_OFFSET() -> offset {
    offset := add(DEBUG_SLOT_OFFSET(), mul(5, 32))
}

function STACK_OFFSET() -> offset {
    offset := add(LAST_RETURNDATA_SIZE_OFFSET(), 32)
}

function BYTECODE_OFFSET() -> offset {
    offset := add(STACK_OFFSET(), mul(1024, 32))
}

function INF_PASS_GAS() -> inf {
    inf := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
}

function MAX_POSSIBLE_BYTECODE() -> max {
    max := 32000
}

function MEM_OFFSET() -> offset {
    offset := add(BYTECODE_OFFSET(), MAX_POSSIBLE_BYTECODE())
}

function MEM_OFFSET_INNER() -> offset {
    offset := add(MEM_OFFSET(), 32)
}

function MAX_POSSIBLE_MEM() -> max {
    max := 0x100000 // 1MB
}

function MAX_MEMORY_FRAME() -> max {
    max := add(MEM_OFFSET_INNER(), MAX_POSSIBLE_MEM())
}

function MAX_UINT() -> max_uint {
    max_uint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
}

// It is the responsibility of the caller to ensure that ip >= BYTECODE_OFFSET + 32
function readIP(ip,maxAcceptablePos) -> opcode {
    if gt(ip, maxAcceptablePos) {
        revert(0, 0)
    }

    opcode := and(mload(sub(ip, 31)), 0xff)
}

function readBytes(start, maxAcceptablePos,length) -> value {
    if gt(add(start,sub(length,1)), maxAcceptablePos) {
        revert(0, 0)
    }
    value := shr(mul(8,sub(32,length)),mload(start))
}

function dupStackItem(sp, evmGas, position) -> newSp, evmGasLeft {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, sub(position, 1)))

    if or(gt(tempSp, BYTECODE_OFFSET()), eq(tempSp, BYTECODE_OFFSET())) {
        revertWithGas(evmGasLeft)
    }

    if lt(tempSp, STACK_OFFSET()) {
        revertWithGas(evmGasLeft)
    }

    let dup := mload(tempSp)                    

    newSp := add(sp, 0x20)
    mstore(newSp, dup)
}

function swapStackItem(sp, evmGas, position) ->  evmGasLeft {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, position))

    if or(gt(tempSp, BYTECODE_OFFSET()), eq(tempSp, BYTECODE_OFFSET())) {
        revertWithGas(evmGasLeft)
    }

    if lt(tempSp, STACK_OFFSET()) {
        revertWithGas(evmGasLeft)
    }


    let s2 := mload(sp)
    let s1 := mload(tempSp)                    

    mstore(sp, s1)
    mstore(tempSp, s2)
}

function popStackItem(sp, evmGasLeft) -> a, newSp {
    // We can not return any error here, because it would break compatibility
    if lt(sp, STACK_OFFSET()) {
        revertWithGas(evmGasLeft)
    }

    a := mload(sp)
    newSp := sub(sp, 0x20)
}

function pushStackItem(sp, item, evmGasLeft) -> newSp {
    if or(gt(sp, BYTECODE_OFFSET()), eq(sp, BYTECODE_OFFSET())) {
        revertWithGas(evmGasLeft)
    }

    newSp := add(sp, 0x20)
    mstore(newSp, item)
}

function popStackItemWithoutCheck(sp) -> a, newSp {
    a := mload(sp)
    newSp := sub(sp, 0x20)
}

function pushStackItemWithoutCheck(sp, item) -> newSp {
    newSp := add(sp, 0x20)
    mstore(newSp, item)
}

function popStackCheck(sp, evmGasLeft, numInputs) {
    if lt(sub(sp, mul(0x20, sub(numInputs, 1))), STACK_OFFSET()) {
        revertWithGas(evmGasLeft)
    }
}

function pushStackCheck(sp, evmGasLeft, numInputs) {
    if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_OFFSET())) {
        revertWithGas(evmGasLeft)
    }
}

function getCodeAddress() -> addr {
    addr := verbatim_0i_1o("code_source")
}

function loadReturndataIntoActivePtr() {
    verbatim_0i_0o("return_data_ptr_to_active")
}

function loadCalldataIntoActivePtr() {
    verbatim_0i_0o("calldata_ptr_to_active")
}

function getActivePtrDataSize() -> size {
    size := verbatim_0i_1o("active_ptr_data_size")
}

function copyActivePtrData(_dest, _source, _size) {
    verbatim_3i_0o("active_ptr_data_copy", _dest, _source, _size)
}

function ptrAddIntoActive(_dest) {
    verbatim_1i_0o("active_ptr_add_assign", _dest)
}

function ptrShrinkIntoActive(_dest) {
    verbatim_1i_0o("active_ptr_shrink_assign", _dest)
}

function _getRawCodeHash(account) -> hash {
    mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
    mstore(4, account)

    let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    hash := mload(0)
}

function _getCodeHash(account) -> hash {
    // function getCodeHash(uint256 _input) external view override returns (bytes32)
    mstore(0, 0xE03FE17700000000000000000000000000000000000000000000000000000000)
    mstore(4, account)

    let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    hash := mload(0)
}

function getIsStaticFromCallFlags() -> isStatic {
    isStatic := verbatim_0i_1o("get_global::call_flags")
    isStatic := iszero(iszero(and(isStatic, 0x04)))
}

// Basically performs an extcodecopy, while returning the length of the bytecode.
function _fetchDeployedCode(addr, _offset, _len) -> codeLen {
    codeLen := _fetchDeployedCodeWithDest(addr, 0, _len, _offset)
}

// Basically performs an extcodecopy, while returning the length of the bytecode.
function _fetchDeployedCodeWithDest(addr, _offset, _len, dest) -> codeLen {
    let codeHash := _getRawCodeHash(addr)

    mstore(0, codeHash)

    let success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    // The first word is the true length of the bytecode
    returndatacopy(0, 0, 32)
    codeLen := mload(0)

    if gt(_len, codeLen) {
        _len := codeLen
    }

    returndatacopy(dest, add(32,_offset), _len)
}

// Returns the length of the bytecode.
function _fetchDeployedCodeLen(addr) -> codeLen {
    let codeHash := _getRawCodeHash(addr)

    mstore(0, codeHash)

    let success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)

    switch iszero(success)
    case 1 {
        // The code oracle call can only fail in the case where the contract
        // we are querying is the current one executing and it has not yet been
        // deployed, i.e., if someone calls codesize (or extcodesize(address()))
        // inside the constructor. In that case, code length is zero.
        codeLen := 0
    }
    default {
        // The first word is the true length of the bytecode
        returndatacopy(0, 0, 32)
        codeLen := mload(0)
    }
}

function getDeployedBytecode() {
    let codeLen := _fetchDeployedCode(
        getCodeAddress(),
        add(BYTECODE_OFFSET(), 32),
        MAX_POSSIBLE_BYTECODE()
    )

    mstore(BYTECODE_OFFSET(), codeLen)
}

function consumeEvmFrame() -> passGas, isStatic, callerEVM {
    // function consumeEvmFrame() external returns (uint256 passGas, bool isStatic)
    mstore(0, 0x04C14E9E00000000000000000000000000000000000000000000000000000000)

    let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        4,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )
    let to := EVM_GAS_MANAGER_CONTRACT()
    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(success) {
        // Should never happen
        revert(0, 0)
    }

    returndatacopy(0,0,64)

    passGas := mload(0)
    isStatic := mload(32)

    if iszero(eq(passGas, INF_PASS_GAS())) {
        callerEVM := true
    }
}

function chargeGas(prevGas, toCharge) -> gasRemaining {
    if lt(prevGas, toCharge) {
        revertWithGas(0)
    }

    gasRemaining := sub(prevGas, toCharge)
}

function getMax(a, b) -> max {
    max := b
    if gt(a, b) {
        max := a
    }
}

function getMin(a, b) -> min {
    min := b
    if lt(a, b) {
        min := a
    }
}

function bitLength(n) -> bitLen {
    for { } gt(n, 0) { } { // while(n > 0)
        if iszero(n) {
            bitLen := 1
            break
        }
        n := shr(1, n)
        bitLen := add(bitLen, 1)
    }
}

function bitMaskFromBytes(nBytes) -> bitMask {
    bitMask := sub(exp(2, mul(nBytes, 8)), 1) // 2**(nBytes*8) - 1
}
// The gas cost mentioned here is purely the cost of the contract, 
// and does not consider the cost of the call itself nor the instructions 
// to put the parameters in memory. 
// Take into account MEM_OFFSET_INNER() when passing the argsOffset
function getGasForPrecompiles(addr, argsOffset, argsSize) -> gasToCharge {
    switch addr
        case 0x01 { // ecRecover
            gasToCharge := 3000
        }
        case 0x02 { // SHA2-256
            gasToCharge := 60
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(12, dataWordSize))
        }
        case 0x03 { // RIPEMD-160
            gasToCharge := 600
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(120, dataWordSize))
        }
        case 0x04 { // identity
            gasToCharge := 15
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(3, dataWordSize))
        }
        // [0; 31] (32 bytes)	Bsize	Byte size of B
        // [32; 63] (32 bytes)	Esize	Byte size of E
        // [64; 95] (32 bytes)	Msize	Byte size of M
        /*       
        def calculate_iteration_count(exponent_length, exponent):
            iteration_count = 0
            if exponent_length <= 32 and exponent == 0: iteration_count = 0
            elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
            elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)
            return max(iteration_count, 1)
        def calculate_gas_cost(base_length, modulus_length, exponent_length, exponent):
            multiplication_complexity = calculate_multiplication_complexity(base_length, modulus_length)
            iteration_count = calculate_iteration_count(exponent_length, exponent)
            return max(200, math.floor(multiplication_complexity * iteration_count / 3))
        */
        // modexp gas cost EIP below
        // https://eips.ethereum.org/EIPS/eip-2565
        case 0x05 { // modexp
            let mulComplex
            let Bsize := mload(argsOffset)
            let Esize := mload(add(argsOffset, 0x20))

            {
                let words := getMax(Bsize, mload(add(argsOffset, 0x40))) // shr(3, x) == x/8
                if and(lt(words, 64), eq(words, 64)){
                    // if x <= 64: return x ** 2
                    mulComplex := mul(words, words)
                }
                if and(and(lt(words, 1024), eq(words, 1024)), gt(words, 64)){
                    // elif x <= 1024: return x ** 2 // 4 + 96 * x - 3072
                    mulComplex := sub(add(shr(2, mul(words, words)), mul(96, words)), 3072)
                }
                if gt(words, 64) {
                    //  else: return x ** 2 // 16 + 480 * x - 199680
                    mulComplex := sub(add(shr(4, mul(words, words)), mul(480, words)), 199680)
                }
            }

            // [96 + Bsize; 96 + Bsize + Esize]	E
            let exponentFirst256, exponentIsZero, exponentBitLen
            if or(lt(Esize, 32), eq(Esize, 32)) {
                // Maybe there isn't exactly 32 bytes, so a mask should be applied
                exponentFirst256 := mload(add(add(argsOffset, 0x60), Bsize))
                exponentBitLen := bitLength(exponentFirst256)
                exponentIsZero := iszero(and(exponentFirst256, bitMaskFromBytes(Esize)))
            }
            if gt(Esize, 32) {
                exponentFirst256 := mload(add(add(argsOffset, 0x60), Bsize))
                exponentIsZero := iszero(exponentFirst256)
                let exponentNext
                // This is done because the first 32bytes of the exponent were loaded
                for { let i := 0 } lt(i,  div(Esize, 32)) { i := add(i, 1) Esize := sub(Esize, 32)  } { // check every 32bytes
                    // Maybe there isn't exactly 32 bytes, so a mask should be applied
                    exponentNext := mload(add(add(add(argsOffset, 0x60), Bsize), add(mul(i, 32), 32)))
                    exponentBitLen := add(bitLength(exponentNext), mul(mul(32, 8), add(i, 1)))
                    if iszero(iszero(and(exponentNext, bitMaskFromBytes(Esize)))) {
                        exponentIsZero := false
                    }
                }
            }

            // if exponent_length <= 32 and exponent == 0: iteration_count = 0
            // return max(iteration_count, 1)
            let iterationCount := 1
            // elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
            if and(lt(Esize, 32), iszero(exponentIsZero)) {
                iterationCount := sub(exponentBitLen, 1)
            }
            // elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)
            if gt(Esize, 32) {
                iterationCount := add(mul(8, sub(Esize, 32)), sub(bitLength(and(exponentFirst256, MAX_UINT())), 1))
            }

            gasToCharge := getMax(200, div(mul(mulComplex, iterationCount), 3))
        }
        // ecAdd ecMul ecPairing EIP below
        // https://eips.ethereum.org/EIPS/eip-1108
        case 0x06 { // ecAdd
            // The gas cost is fixed at 150. However, if the input
            // does not allow to compute a valid result, all the gas sent is consumed.
            gasToCharge := 150
        }
        case 0x07 { // ecMul
            // The gas cost is fixed at 6000. However, if the input
            // does not allow to compute a valid result, all the gas sent is consumed.
            gasToCharge := 6000
        }
        // 35,000 * k + 45,000 gas, where k is the number of pairings being computed.
        // The input must always be a multiple of 6 32-byte values.
        case 0x08 { // ecPairing
            gasToCharge := 45000
            let k := div(argsSize, 0xC0) // 0xC0 == 6*32
            gasToCharge := add(gasToCharge, mul(k, 35000))
        }
        case 0x09 { // blake2f
            // argsOffset[0; 3] (4 bytes) Number of rounds (big-endian uint)
            gasToCharge := and(mload(argsOffset), 0xFFFFFFFF) // last 4bytes
        }
        default {
            gasToCharge := 0
        }
}

function checkMemOverflowByOffset(offset, evmGasLeft) {
    if gt(offset, MAX_POSSIBLE_MEM()) {
        mstore(0, evmGasLeft)
        revert(0, 32)
    }
}

function checkMemOverflow(location, evmGasLeft) {
    if gt(location, MAX_MEMORY_FRAME()) {
        mstore(0, evmGasLeft)
        revert(0, 32)
    }
}

function checkMultipleOverflow(data1, data2, data3, evmGasLeft) {
    checkOverflow(data1, data2, evmGasLeft)
    checkOverflow(data1, data3, evmGasLeft)
    checkOverflow(data2, data3, evmGasLeft)
    checkOverflow(add(data1, data2), data3, evmGasLeft)
}

function checkOverflow(data1, data2, evmGasLeft) {
    if lt(add(data1, data2), data2) {
        revertWithGas(evmGasLeft)
    }
}

function revertWithGas(evmGasLeft) {
    mstore(0, evmGasLeft)
    revert(0, 32)
}

// This function can overflow, it is the job of the caller to ensure that it does not.
// The argument to this function is the offset into the memory region IN BYTES.
function expandMemory(newSize) -> gasCost {
    let oldSizeInWords := mload(MEM_OFFSET())

    // The add 31 here before dividing is there to account for misaligned
    // memory expansions, where someone calls this with a newSize that is not
    // a multiple of 32. For instance, if someone calls it with an offset of 33,
    // the new size in words should be 2, not 1, but dividing by 32 will give 1.
    // Adding 31 solves it.
    let newSizeInWords := div(add(newSize, 31), 32)

    if gt(newSizeInWords, oldSizeInWords) {
        let new_minus_old := sub(newSizeInWords, oldSizeInWords)
        gasCost := add(mul(3,new_minus_old), div(mul(new_minus_old,add(newSizeInWords,oldSizeInWords)),512))

        mstore(MEM_OFFSET(), newSizeInWords)
    }
}

// Essentially a NOP that will not get optimized away by the compiler
function $llvm_NoInline_llvm$_unoptimized() {
    pop(1)
}

function printHex(value) {
    mstore(add(DEBUG_SLOT_OFFSET(), 0x20), 0x00debdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebde)
    mstore(add(DEBUG_SLOT_OFFSET(), 0x40), value)
    mstore(DEBUG_SLOT_OFFSET(), 0x4A15830341869CAA1E99840C97043A1EA15D2444DA366EFFF5C43B4BEF299681)
    $llvm_NoInline_llvm$_unoptimized()
}

function printString(value) {
    mstore(add(DEBUG_SLOT_OFFSET(), 0x20), 0x00debdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdf)
    mstore(add(DEBUG_SLOT_OFFSET(), 0x40), value)
    mstore(DEBUG_SLOT_OFFSET(), 0x4A15830341869CAA1E99840C97043A1EA15D2444DA366EFFF5C43B4BEF299681)
    $llvm_NoInline_llvm$_unoptimized()
}

function isSlotWarm(key) -> isWarm {
    mstore(0, 0x482D2E7400000000000000000000000000000000000000000000000000000000)
    mstore(4, key)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    isWarm := mload(0)
}

function warmSlot(key,currentValue) -> isWarm, originalValue {
    mstore(0, 0xBDF7816000000000000000000000000000000000000000000000000000000000)
    mstore(4, key)
    mstore(36,currentValue)

    let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        68,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )
    let to := EVM_GAS_MANAGER_CONTRACT()
    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    returndatacopy(0, 0, 64)

    isWarm := mload(0)
    originalValue := mload(32)
}

function MAX_SYSTEM_CONTRACT_ADDR() -> ret {
    ret := 0x000000000000000000000000000000000000ffff
}

/// @dev Checks whether an address is an EOA (i.e. has not code deployed on it)
/// @param addr The address to check
function isEOA(addr) -> ret {
    ret := 0
    if gt(addr, MAX_SYSTEM_CONTRACT_ADDR()) {
        ret := iszero(_getRawCodeHash(addr))
    }
}

function incrementNonce(addr) {
    mstore(0, 0x306395C600000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)

    let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        36,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )
    let to := NONCE_HOLDER_SYSTEM_CONTRACT()
    let result := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(result) {
        revert(0, 0)
    }
} 

function getFarCallABI(
    dataOffset,
    memoryPage,
    dataStart,
    dataLength,
    gasPassed,
    shardId,
    forwardingMode,
    isConstructorCall,
    isSystemCall
) -> ret {
    let farCallAbi := 0
    farCallAbi :=  or(farCallAbi, dataOffset)
    farCallAbi :=  or(farCallAbi, shl(64, dataStart))
    farCallAbi :=  or(farCallAbi, shl(96, dataLength))
    farCallAbi :=  or(farCallAbi, shl(192, gasPassed))
    farCallAbi :=  or(farCallAbi, shl(224, shardId))
    farCallAbi :=  or(farCallAbi, shl(232, forwardingMode))
    farCallAbi :=  or(farCallAbi, shl(248, 1))
    ret := farCallAbi
}

function ensureAcceptableMemLocation(location) {
    if gt(location,MAX_POSSIBLE_MEM()) {
        revert(0,0) // Check if this is what's needed
    }
}

function addGasIfEvmRevert(isCallerEVM,offset,size,evmGasLeft) -> newOffset,newSize {
    newOffset := offset
    newSize := size
    if eq(isCallerEVM,1) {
        // include gas
        let previousValue := mload(sub(offset,32))
        mstore(sub(offset,32),evmGasLeft)
        //mstore(sub(offset,32),previousValue) // Im not sure why this is needed, it was like this in the solidity code,
        // but it appears to rewrite were we want to store the gas

        newOffset := sub(offset, 32)
        newSize := add(size, 32)
    }
}

function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
    mstore(0, 0x8DB2BA7800000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)

    let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        36,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )
    let to := EVM_GAS_MANAGER_CONTRACT()
    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    returndatacopy(0, 0, 32)
    isWarm := mload(0)
}

function getRawNonce(addr) -> nonce {
    mstore(0, 0x5AA9B6B500000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)

    let result := staticcall(gas(), NONCE_HOLDER_SYSTEM_CONTRACT(), 0, 36, 0, 32)

    if iszero(result) {
        revert(0, 0)
    }

    nonce := mload(0)
}

function _isEVM(_addr) -> isEVM {
    // bytes4 selector = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM.selector; (0x8c040477)
    // function isAccountEVM(address _addr) external view returns (bool);
    // IAccountCodeStorage constant ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT = IAccountCodeStorage(
    //      address(SYSTEM_CONTRACTS_OFFSET + 0x02)
    // );

    mstore(0, 0x8C04047700000000000000000000000000000000000000000000000000000000)
    mstore(4, _addr)

    let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    isEVM := mload(0)
}

function _pushEVMFrame(_passGas, _isStatic) {
    // function pushEVMFrame(uint256 _passGas, bool _isStatic) external

    mstore(0, 0xEAD7715600000000000000000000000000000000000000000000000000000000)
    mstore(4, _passGas)
    mstore(36, _isStatic)

    let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        68,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )

    let to := EVM_GAS_MANAGER_CONTRACT()
    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }
}

function _popEVMFrame() {
    // function popEVMFrame() external

     let farCallAbi := getFarCallABI(
        0,
        0,
        0,
        4,
        gas(),
        // Only rollup is supported for now
        0,
        0,
        0,
        1
    )

    let to := EVM_GAS_MANAGER_CONTRACT()

    mstore(0, 0xE467D2F000000000000000000000000000000000000000000000000000000000)

    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }
}

// Each evm gas is 5 zkEVM one
function GAS_DIVISOR() -> gas_div { gas_div := 5 }
function EVM_GAS_STIPEND() -> gas_stipend { gas_stipend := shl(30, 1) } // 1 << 30
function OVERHEAD() -> overhead { overhead := 2000 }

// From precompiles/CodeOracle
function DECOMMIT_COST_PER_WORD() -> cost { cost := 4 }
function UINT32_MAX() -> ret { ret := 4294967295 } // 2^32 - 1

function _calcEVMGas(_zkevmGas) -> calczkevmGas {
    calczkevmGas := div(_zkevmGas, GAS_DIVISOR())
}

function getEVMGas() -> evmGas {
    let _gas := gas()
    let requiredGas := add(EVM_GAS_STIPEND(), OVERHEAD())

    switch lt(_gas, requiredGas)
    case 1 {
        evmGas := 0
    }
    default {
        evmGas := div(sub(_gas, requiredGas), GAS_DIVISOR())
    }
}

function _getZkEVMGas(_evmGas, addr) -> zkevmGas {
    zkevmGas := mul(_evmGas, GAS_DIVISOR())
    let byteSize := extcodesize(addr)
    let should_ceil := mod(byteSize, 32)
    if gt(should_ceil, 0) {
        byteSize := add(byteSize, sub(32, should_ceil))
    }
    let decommitGasCost := mul(div(byteSize,32), DECOMMIT_COST_PER_WORD())
    zkevmGas := sub(zkevmGas, decommitGasCost)
    if gt(zkevmGas, UINT32_MAX()) {
        zkevmGas := UINT32_MAX()
    }
}

function _saveReturndataAfterEVMCall(_outputOffset, _outputLen) -> _gasLeft{
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()
    let rtsz := returndatasize()

    loadReturndataIntoActivePtr()

    // if (rtsz > 31)
    switch gt(rtsz, 31)
        case 0 {
            // Unexpected return data.
            _gasLeft := 0
            _eraseReturndataPointer()
        }
        default {
            returndatacopy(0, 0, 32)
            _gasLeft := mload(0)

            // We copy as much returndata as possible without going over the 
            // returndata size.
            switch lt(sub(rtsz, 32), _outputLen)
                case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }

            mstore(lastRtSzOffset, sub(rtsz, 32))

            // Skip the returnData
            ptrAddIntoActive(32)
        }
}

function _eraseReturndataPointer() {
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()

    let activePtrSize := getActivePtrDataSize()
    ptrShrinkIntoActive(and(activePtrSize, 0xFFFFFFFF))// uint32(activePtrSize)
    mstore(lastRtSzOffset, 0)
}

function _saveReturndataAfterZkEVMCall() {
    loadReturndataIntoActivePtr()
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()

    mstore(lastRtSzOffset, returndatasize())
}

function performStaticCall(oldSp,evmGasLeft) -> extraCost, sp {
    let gasToPass,addr, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, evmGasLeft, 6)
    gasToPass, sp := popStackItemWithoutCheck(oldSp)
    addr, sp := popStackItemWithoutCheck(sp)
    argsOffset, sp := popStackItemWithoutCheck(sp)
    argsSize, sp := popStackItemWithoutCheck(sp)
    retOffset, sp := popStackItemWithoutCheck(sp)
    retSize, sp := popStackItemWithoutCheck(sp)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkOverflow(argsOffset,argsSize, evmGasLeft)
    checkOverflow(retOffset, retSize, evmGasLeft)

    checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
    checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)

    extraCost := 0
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        extraCost := 2500
    }

    {
        let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
        extraCost := add(extraCost,maxExpand)
    }
    let maxGasToPass := sub(evmGasLeft, shr(6, evmGasLeft)) // evmGasLeft >> 6 == evmGasLeft/64
    if gt(gasToPass, maxGasToPass) { 
        gasToPass := maxGasToPass
    }

    let frameGasLeft
    let success
    switch _isEVM(addr)
    case 0 {
        // zkEVM native
        gasToPass := _getZkEVMGas(gasToPass, addr)
        let zkevmGasBefore := gas()
        success := staticcall(gasToPass, addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, add(MEM_OFFSET_INNER(), retOffset), retSize)
        _saveReturndataAfterZkEVMCall()

        let gasUsed := _calcEVMGas(sub(zkevmGasBefore, gas()))

        frameGasLeft := 0
        if gt(gasToPass, gasUsed) {
            frameGasLeft := sub(gasToPass, gasUsed)
        }
    }
    default {
        _pushEVMFrame(gasToPass, true)
        success := staticcall(gasToPass, addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, 0, 0)

        frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
        _popEVMFrame()
    }

    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
    switch iszero(precompileCost)
    case 1 {
        extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    }
    default {
        extraCost := add(extraCost, precompileCost)
    }

    sp := pushStackItem(sp, success, evmGasLeft)
}
function capGas(evmGasLeft,oldGasToPass) -> gasToPass {
    let maxGasToPass := sub(evmGasLeft, shr(6, evmGasLeft)) // evmGasLeft >> 6 == evmGasLeft/64
    gasToPass := oldGasToPass
    if gt(oldGasToPass, maxGasToPass) { 
        gasToPass := maxGasToPass
    }
}

function getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize) -> maxExpand{
    maxExpand := add(retOffset, retSize)
    switch lt(maxExpand,add(argsOffset, argsSize)) 
    case 0 {
        maxExpand := expandMemory(maxExpand)
    }
    default {
        maxExpand := expandMemory(add(argsOffset, argsSize))
    }
}

function _performCall(addr,gasToPass,value,argsOffset,argsSize,retOffset,retSize,isStatic) -> success, frameGasLeft, gasToPassNew{
    gasToPassNew := gasToPass
    let is_evm := _isEVM(addr)

    switch isStatic
    case 0 {
        switch is_evm
        case 0 {
            // zkEVM native
            gasToPassNew := _getZkEVMGas(gasToPassNew, addr)
            let zkevmGasBefore := gas()
            success := call(gasToPassNew, addr, value, argsOffset, argsSize, retOffset, retSize)
            _saveReturndataAfterZkEVMCall()
            let gasUsed := _calcEVMGas(sub(zkevmGasBefore, gas()))
    
            frameGasLeft := 0
            if gt(gasToPassNew, gasUsed) {
                frameGasLeft := sub(gasToPassNew, gasUsed)
            }
        }
        default {
            _pushEVMFrame(gasToPassNew, isStatic)
            success := call(EVM_GAS_STIPEND(), addr, value, argsOffset, argsSize, 0, 0)
            frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
            _popEVMFrame()
        }
    }
    default {
        if value {
            revertWithGas(gasToPassNew)
        }
        success, frameGasLeft:= _performStaticCall(
            is_evm,
            gasToPassNew,
            addr,
            argsOffset,
            argsSize,
            retOffset,
            retSize
        )
    }
}

function performCall(oldSp, evmGasLeft, isStatic) -> extraCost, sp {
    let gasToPass,addr,value,argsOffset,argsSize,retOffset,retSize

    popStackCheck(oldSp, evmGasLeft, 7)
    gasToPass, sp := popStackItemWithoutCheck(oldSp)
    addr, sp := popStackItemWithoutCheck(sp)
    value, sp := popStackItemWithoutCheck(sp)
    argsOffset, sp := popStackItemWithoutCheck(sp)
    argsSize, sp := popStackItemWithoutCheck(sp)
    retOffset, sp := popStackItemWithoutCheck(sp)
    retSize, sp := popStackItemWithoutCheck(sp)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    // static_gas = 0
    // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
    // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
    // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
    // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called. 2300 is thus removed from the cost, and also added to the gas input.
    // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.

    extraCost := 0
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        extraCost := 2500
    }

    if gt(value, 0) {
        extraCost := add(extraCost,6700)
        gasToPass := add(gasToPass,2300)
    }

    if and(isAddrEmpty(addr), gt(value, 0)) {
        extraCost := add(extraCost,25000)
    }
    {
        let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
        extraCost := add(extraCost,maxExpand)
    }
    gasToPass := capGas(evmGasLeft,gasToPass)

    argsOffset := add(argsOffset,MEM_OFFSET_INNER())
    retOffset := add(retOffset,MEM_OFFSET_INNER())

    checkOverflow(argsOffset,argsSize, evmGasLeft)
    checkOverflow(retOffset,retSize, evmGasLeft)

    checkMemOverflow(add(argsOffset, argsSize), evmGasLeft)
    checkMemOverflow(add(retOffset, retSize), evmGasLeft)

    let success, frameGasLeft 
    success, frameGasLeft, gasToPass:= _performCall(
        addr,
        gasToPass,
        value,
        argsOffset,
        argsSize,
        retOffset,
        retSize,
        isStatic
    )

    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
    switch iszero(precompileCost)
    case 1 {
        extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    }
    default {
        extraCost := add(extraCost, precompileCost)
    }
    sp := pushStackItem(sp,success, evmGasLeft) 
}

function delegateCall(oldSp, oldIsStatic, evmGasLeft) -> sp, isStatic, extraCost {
    let addr, gasToPass, argsOffset, argsSize, retOffset, retSize

    sp := oldSp
    isStatic := oldIsStatic

    popStackCheck(sp, evmGasLeft, 6)
    gasToPass, sp := popStackItemWithoutCheck(sp)
    addr, sp := popStackItemWithoutCheck(sp)
    argsOffset, sp := popStackItemWithoutCheck(sp)
    argsSize, sp := popStackItemWithoutCheck(sp)
    retOffset, sp := popStackItemWithoutCheck(sp)
    retSize, sp := popStackItemWithoutCheck(sp)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkOverflow(argsOffset, argsSize, evmGasLeft)
    checkOverflow(retOffset, retSize, evmGasLeft)

    checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
    checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)

    if iszero(_isEVM(addr)) {
        revertWithGas(evmGasLeft)
    }

    extraCost := 0
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        extraCost := 2500
    }

    {
        let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
        extraCost := add(extraCost,maxExpand)
    }
    gasToPass := capGas(evmGasLeft,gasToPass)

    _pushEVMFrame(gasToPass, isStatic)
    let success := delegatecall(
        // We can not just pass all gas here to prevent overflow of zkEVM gas counter
        EVM_GAS_STIPEND(),
        addr,
        add(MEM_OFFSET_INNER(), argsOffset),
        argsSize,
        0,
        0
    )

    let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)

    _popEVMFrame()

    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
    switch iszero(precompileCost)
    case 1 {
        extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    }
    default {
        extraCost := add(extraCost, precompileCost)
    }
    sp := pushStackItem(sp, success, evmGasLeft)
}

function getMessageCallGas (
    _value,
    _gas,
    _gasLeft,
    _memoryCost,
    _extraGas
) -> gasPlusExtra, gasPlusStipend {
    let callStipend := 2300
    if iszero(_value) {
        callStipend := 0
    }

    switch lt(_gasLeft, add(_extraGas, _memoryCost))
        case 0
        {
            let _gasTemp := sub(sub(_gasLeft, _extraGas), _memoryCost)
            // From the Tangerine Whistle fork, gas is capped at all but one 64th (remaining_gas / 64)
            // of the remaining gas of the current context. If a call tries to send more, the gas is 
            // changed to match the maximum allowed.
            let maxGasToPass := sub(_gasTemp, shr(6, _gasTemp)) // _gas >> 6 == _gas/64
            if gt(_gas, maxGasToPass) {
                _gas := maxGasToPass
            }
            gasPlusExtra := add(_gas, _extraGas)
            gasPlusStipend := add(_gas, callStipend)
        }
        default {
            gasPlusExtra := add(_gas, _extraGas)
            gasPlusStipend := add(_gas, callStipend)
        }
}

function _performStaticCall(
    _calleeIsEVM,
    _calleeGas,
    _callee,
    _inputOffset,
    _inputLen,
    _outputOffset,
    _outputLen
) ->  success, _gasLeft {
    switch _calleeIsEVM
    case 0 {
        // zkEVM native
        _calleeGas := _getZkEVMGas(_calleeGas, _callee)
        let zkevmGasBefore := gas()
        success := staticcall(_calleeGas, _callee, _inputOffset, _inputLen, _outputOffset, _outputLen)

        _saveReturndataAfterZkEVMCall()

        let gasUsed := _calcEVMGas(sub(zkevmGasBefore, gas()))

        _gasLeft := 0
        if gt(_calleeGas, gasUsed) {
            _gasLeft := sub(_calleeGas, gasUsed)
        }
    }
    default {
        _pushEVMFrame(_calleeGas, true)
        success := staticcall(EVM_GAS_STIPEND(), _callee, _inputOffset, _inputLen, 0, 0)

        _gasLeft := _saveReturndataAfterEVMCall(_outputOffset, _outputLen)
        _popEVMFrame()
    }
}

function isAddrEmpty(addr) -> isEmpty {
    isEmpty := 0
    if iszero(extcodesize(addr)) { // YUL doesn't have short-circuit evaluation
        if iszero(balance(addr)) {
            if iszero(getRawNonce(addr)) {
                isEmpty := 1
            }
        }
    }
}

function _fetchConstructorReturnGas() -> gasLeft {
    mstore(0, 0x24E5AB4A00000000000000000000000000000000000000000000000000000000)

    let success := staticcall(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, 4, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    gasLeft := mload(0)
}

function $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeftOld, isCreate2, salt) -> result, evmGasLeft, addr {
    pop($llvm_AlwaysInline_llvm$_warmAddress(addr))

    _eraseReturndataPointer()

    let gasForTheCall := capGas(evmGasLeftOld,INF_PASS_GAS())

    if lt(selfbalance(),value) {
        revertWithGas(evmGasLeftOld)
    }

    offset := add(MEM_OFFSET_INNER(), offset)

    pushStackCheck(sp, evmGasLeftOld, 4)
    sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x80)))
    sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x60)))
    sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x40)))
    sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x20)))

    _pushEVMFrame(gasForTheCall, false)

    if isCreate2 {
        // Create2EVM selector
        mstore(sub(offset, 0x80), 0x4e96f4c0)
        // salt
        mstore(sub(offset, 0x60), salt)
        // Where the arg starts (third word)
        mstore(sub(offset, 0x40), 0x40)
        // Length of the init code
        mstore(sub(offset, 0x20), size)


        result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x64), add(size, 0x64), 0, 32)
    }


    if iszero(isCreate2) {
        // CreateEVM selector
        mstore(sub(offset, 0x60), 0xff311601)
        // Where the arg starts (second word)
        mstore(sub(offset, 0x40), 0x20)
        // Length of the init code
        mstore(sub(offset, 0x20), size)


        result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x44), add(size, 0x44), 0, 32)
    }

    addr := mload(0)

    let gasLeft
    switch result
        case 0 {
            gasLeft := _saveReturndataAfterEVMCall(0, 0)
        }
        default {
            gasLeft := _fetchConstructorReturnGas()
        }

    let gasUsed := sub(gasForTheCall, gasLeft)
    evmGasLeft := chargeGas(evmGasLeftOld, gasUsed)

    _popEVMFrame()

    let back

    // skipping check since we pushed exactly 4 items earlier
    back, sp := popStackItemWithoutCheck(sp)
    mstore(sub(offset, 0x20), back)
    back, sp := popStackItemWithoutCheck(sp)
    mstore(sub(offset, 0x40), back)
    back, sp := popStackItemWithoutCheck(sp)
    mstore(sub(offset, 0x60), back)
    back, sp := popStackItemWithoutCheck(sp)
    mstore(sub(offset, 0x80), back)
}

function $llvm_AlwaysInline_llvm$_copyRest(dest, val, len) {
    let rest_bits := shl(3, len)
    let upper_bits := sub(256, rest_bits)
    let val_mask := shl(upper_bits, MAX_UINT())
    let val_masked := and(val, val_mask)
    let dst_val := mload(dest)
    let dst_mask := shr(rest_bits, MAX_UINT())
    let dst_masked := and(dst_val, dst_mask)
    mstore(dest, or(val_masked, dst_masked))
}

function $llvm_AlwaysInline_llvm$_memcpy(dest, src, len) {
    let dest_addr := dest
    let src_addr := src
    let dest_end := add(dest, and(len, sub(0, 32)))
    for { } lt(dest_addr, dest_end) {} {
        mstore(dest_addr, mload(src_addr))
        dest_addr := add(dest_addr, 32)
        src_addr := add(src_addr, 32)
    }

    let rest_len := and(len, 31)
    if rest_len {
        $llvm_AlwaysInline_llvm$_copyRest(dest_addr, mload(src_addr), rest_len)
    }
}

function $llvm_AlwaysInline_llvm$_memsetToZero(dest,len) {
    let dest_end := add(dest, and(len, sub(0, 32)))
    for {let i := dest} lt(i, dest_end) { i := add(i, 32) } {
        mstore(i, 0)
    }

    let rest_len := and(len, 31)
    if rest_len {
        $llvm_AlwaysInline_llvm$_copyRest(dest_end, 0, rest_len)
    }
}

function performExtCodeCopy(evmGas,oldSp) -> evmGasLeft, sp {
    evmGasLeft := chargeGas(evmGas, 100)

    let addr, dest, offset, len
    popStackCheck(oldSp, evmGasLeft, 4)
    addr, sp := popStackItemWithoutCheck(oldSp)
    dest, sp := popStackItemWithoutCheck(sp)
    offset, sp := popStackItemWithoutCheck(sp)
    len, sp := popStackItemWithoutCheck(sp)

    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
    // minimum_word_size = (size + 31) / 32

    let dynamicGas := add(
        mul(3, shr(5, add(len, 31))),
        expandMemory(add(dest, len))
    )
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        dynamicGas := add(dynamicGas, 2500)
    }
    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

    $llvm_AlwaysInline_llvm$_memsetToZero(dest, len)

    // Gets the code from the addr
    if and(iszero(iszero(_getRawCodeHash(addr))),gt(len,0)) {
        pop(_fetchDeployedCodeWithDest(addr, offset, len,add(dest,MEM_OFFSET_INNER())))  
    }
}

function performCreate(evmGas,oldSp,isStatic) -> evmGasLeft, sp {
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        revertWithGas(evmGasLeft)
    }

    let value, offset, size

    popStackCheck(oldSp, evmGasLeft, 3)
    value, sp := popStackItemWithoutCheck(oldSp)
    offset, sp := popStackItemWithoutCheck(sp)
    size, sp := popStackItemWithoutCheck(sp)

    checkOverflow(offset, size, evmGasLeft)
    checkMemOverflowByOffset(add(offset, size), evmGasLeft)

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revertWithGas(evmGasLeft)
    }

    if gt(value, balance(address())) {
        revertWithGas(evmGasLeft)
    }

    // dynamicGas = init_code_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size
    // code_deposit_cost = 200 * deployed_code_size
    let dynamicGas := add(
        shr(4, add(size, 31)),
        expandMemory(add(offset, size))
    )
    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

    let result, addr
    result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft, false, 0)

    switch result
        case 0 { sp := pushStackItem(sp, 0, evmGasLeft) }
        default { sp := pushStackItem(sp, addr, evmGasLeft) }
}

function performCreate2(evmGas, oldSp, isStatic) -> evmGasLeft, sp, result, addr{
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        revertWithGas(evmGasLeft)
    }

    let value, offset, size, salt

    popStackCheck(oldSp, evmGasLeft, 4)
    value, sp := popStackItemWithoutCheck(oldSp)
    offset, sp := popStackItemWithoutCheck(sp)
    size, sp := popStackItemWithoutCheck(sp)
    salt, sp := popStackItemWithoutCheck(sp)

    checkOverflow(offset, size, evmGasLeft)
    checkMemOverflowByOffset(add(offset, size), evmGasLeft)

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revertWithGas(evmGasLeft)
    }

    if gt(value, balance(address())) {
        revertWithGas(evmGasLeft)
    }

    // dynamicGas = init_code_cost + hash_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size
    // hash_cost = 6 * minimum_word_size
    // code_deposit_cost = 200 * deployed_code_size
    evmGasLeft := chargeGas(evmGasLeft, add(
        expandMemory(add(offset, size)),
        shr(2, add(size, 31))
    ))

    result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft,true,salt)
}
