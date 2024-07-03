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
    // TODO: Why not do this at the beginning once instead of every time?
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
        revert(0, 0)
    }

    if lt(tempSp, STACK_OFFSET()) {
        revert(0, 0)
    }

    let dup := mload(tempSp)                    

    newSp := add(sp, 0x20)
    mstore(newSp, dup)
}

function swapStackItem(sp, evmGas, position) ->  evmGasLeft {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, position))

    if or(gt(tempSp, BYTECODE_OFFSET()), eq(tempSp, BYTECODE_OFFSET())) {
        revert(0, 0)
    }

    if lt(tempSp, STACK_OFFSET()) {
        revert(0, 0)
    }


    let s2 := mload(sp)
    let s1 := mload(tempSp)                    

    mstore(sp, s1)
    mstore(tempSp, s2)
}

function popStackItem(sp) -> a, newSp {
    // We can not return any error here, because it would break compatibility
    if lt(sp, STACK_OFFSET()) {
        revert(0, 0)
    }

    a := mload(sp)
    newSp := sub(sp, 0x20)
}

function pushStackItem(sp, item) -> newSp {
    if or(gt(sp, BYTECODE_OFFSET()), eq(sp, BYTECODE_OFFSET())) {
        revert(0, 0)
    }

    newSp := add(sp, 0x20)
    mstore(newSp, item)
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
    // TODO: Unhardcode this selector
    mstore8(0, 0x4d)
    mstore8(1, 0xe2)
    mstore8(2, 0xe4)
    mstore8(3, 0x68)
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
    // 0xe03fe177
    // TODO: Unhardcode this selector
    mstore8(0, 0xe0)
    mstore8(1, 0x3f)
    mstore8(2, 0xe1)
    mstore8(3, 0x77)
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
    // TODO: make it a constnat
    isStatic := iszero(iszero(and(isStatic, 0x04)))
}

// Basically performs an extcodecopy, while returning the length of the bytecode.
function _fetchDeployedCode(addr, _offset, _len) -> codeLen {
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

    returndatacopy(_offset, 32, _len)
}

// Returns the length of the bytecode.
function _fetchDeployedCodeLen(addr) -> codeLen {
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
    // TODO: Unhardcode selector
    mstore8(0, 0x04)
    mstore8(1, 0xc1)
    mstore8(2, 0x4e)
    mstore8(3, 0x9e)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 4, 0, 64)

    if iszero(success) {
        // Should never happen
        revert(0, 0)
    }

    passGas := mload(0)
    isStatic := mload(32)

    if iszero(eq(passGas, INF_PASS_GAS())) {
        callerEVM := true
    }
}

function chargeGas(prevGas, toCharge) -> gasRemaining {
    if lt(prevGas, toCharge) {
        revert(0, 0)
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
// Take into account MEM_OFFSET_INNER() when passing the argsOfsset
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

function checkMemOverflow(location) {
    if gt(location, MAX_MEMORY_FRAME()) {
        revert(0, 0)
    }
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
    // TODO: Unhardcode this selector 0x482d2e74
    mstore8(0, 0x48)
    mstore8(1, 0x2d)
    mstore8(2, 0x2e)
    mstore8(3, 0x74)
    mstore(4, key)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    isWarm := mload(0)
}

function warmSlot(key,currentValue) -> isWarm, originalValue {
    // TODO: Unhardcode this selector 0xbdf78160
    mstore8(0, 0xbd)
    mstore8(1, 0xf7)
    mstore8(2, 0x81)
    mstore8(3, 0x60)
    mstore(4, key)
    mstore(36,currentValue)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 68, 0, 64)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    isWarm := mload(0)
    originalValue := mload(32)
}

function getNewAddress(addr) -> newAddr {
    let digest, nonce, addressEncoded, nonceEncoded, nonceEncodedLength, listLength, listLengthEconded

    nonce := getNonce(addr)

    addressEncoded := and(
        add(addr, shl(160, 0x94)),
        0xffffffffffffffffffffffffffffffffffffffffff
    )

    nonceEncoded := nonce
    nonceEncodedLength := 1
    if iszero(nonce) {
        nonceEncoded := 128
    }
    // The nonce has 4 bytes
    if gt(nonce, 0xFFFFFF) {
        nonceEncoded := shl(32, 0x84)
        nonceEncoded := add(nonceEncoded, nonce)
        nonceEncodedLength := 5
    }
    // The nonce has 3 bytes
    if and(gt(nonce, 0xFFFF), lt(nonce, 0x1000000)) {
        nonceEncoded := shl(24, 0x83)
        nonceEncoded := add(nonceEncoded, nonce)
        nonceEncodedLength := 4
    }
    // The nonce has 2 bytes
    if and(gt(nonce, 0xFF), lt(nonce, 0x10000)) {
        nonceEncoded := shl(16, 0x82)
        nonceEncoded := add(nonceEncoded, nonce)
        nonceEncodedLength := 3
    }
    // The nonce has 1 byte and it's in [0x80, 0xFF]
    if and(gt(nonce, 0x7F), lt(nonce, 0x100)) {
        nonceEncoded := shl(8, 0x81)
        nonceEncoded := add(nonceEncoded, nonce)
        nonceEncodedLength := 2
    }

    listLength := add(21, nonceEncodedLength)
    listLengthEconded := add(listLength, 0xC0)

    let arrayLength := add(168, mul(8, nonceEncodedLength))

    digest := add(
        shl(arrayLength, listLengthEconded),
        add(
            shl(
                mul(8, nonceEncodedLength),
                addressEncoded
            ),
            nonceEncoded
        )
    )

    mstore(0, shl(sub(248, arrayLength), digest))

    newAddr := and(
        keccak256(0, add(div(arrayLength, 8), 1)),
        0xffffffffffffffffffffffffffffffffffffffff
    )
}

function incrementNonce(addr) {
    mstore8(0, 0x30)
    mstore8(1, 0x63)
    mstore8(2, 0x95)
    mstore8(3, 0xc6)
    mstore(4, addr)

    let result := call(gas(), NONCE_HOLDER_SYSTEM_CONTRACT(), 0, 0, 36, 0, 0)

    if iszero(result) {
        revert(0, 0)
    }
}

function ensureAcceptableMemLocation(location) {
    if gt(location,MAX_POSSIBLE_MEM()) {
        revert(0,0) // Check if this is whats needed
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

function warmAddress(addr) -> isWarm {
    // TODO: Unhardcode this selector 0x8db2ba78
    mstore8(0, 0x8d)
    mstore8(1, 0xb2)
    mstore8(2, 0xba)
    mstore8(3, 0x78)
    mstore(4, addr)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 36, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    isWarm := mload(0)
}

function getNonce(addr) -> nonce {
    mstore8(0, 0xfb)
    mstore8(1, 0x1a)
    mstore8(2, 0x9a)
    mstore8(3, 0x57)
    mstore(4, addr)

    let result := staticcall(gas(), NONCE_HOLDER_SYSTEM_CONTRACT(), 0, 36, 0, 32)

    if iszero(result) {
        revert(0, 0)
    }

    nonce := mload(0)
}

function getRawNonce(addr) -> nonce {
    mstore8(0, 0x5a)
    mstore8(1, 0xa9)
    mstore8(2, 0xb6)
    mstore8(3, 0xb5)
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

    mstore8(0, 0x8c)
    mstore8(1, 0x04)
    mstore8(2, 0x04)
    mstore8(3, 0x77)
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
    let selector := 0xead77156

    mstore8(0, 0xea)
    mstore8(1, 0xd7)
    mstore8(2, 0x71)
    mstore8(3, 0x56)
    mstore(4, _passGas)
    mstore(36, _isStatic)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 68, 0, 0)
    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }
}

function _popEVMFrame() {
    // function popEVMFrame() external
    // 0xe467d2f0
    let selector := 0xe467d2f0

    mstore8(0, 0xe4)
    mstore8(1, 0x67)
    mstore8(2, 0xd2)
    mstore8(3, 0xf0)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 4, 0, 0)
    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }
}

// Each evm gas is 5 zkEVM one
// FIXME: change this variable to reflect real ergs : gas ratio
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

    if lt(sub(_gas,shl(30,1)), requiredGas) {
        // This cheks if enough zkevm gas was provided, we are substracting 2^30 since that's the stipend, 
        // and we need to make sure that the gas provided over that is enough for security reasons
        // revert(0, 0)
    }
    evmGas := div(sub(_gas, requiredGas), GAS_DIVISOR())
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
            returndatacopy(_outputOffset, 32, _outputLen)
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

    gasToPass, sp := popStackItem(oldSp)
    addr, sp := popStackItem(sp)
    argsOffset, sp := popStackItem(sp)
    argsSize, sp := popStackItem(sp)
    retOffset, sp := popStackItem(sp)
    retSize, sp := popStackItem(sp)

    checkMemOverflow(add(add(argsOffset, argsSize), MEM_OFFSET_INNER()))
    checkMemOverflow(add(add(retOffset, retSize), MEM_OFFSET_INNER()))

    extraCost := 0
    if iszero(warmAddress(addr)) {
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
    if _isEVM(addr) {
        _pushEVMFrame(gasToPass, true)
        // TODO Check the following comment from zkSync .sol.
        // We can not just pass all gas here to prevert overflow of zkEVM gas counter
        success := staticcall(gasToPass, addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, 0, 0)

        frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
        _popEVMFrame()
    }

    // zkEVM native
    if iszero(_isEVM(addr)) {
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

    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    extraCost := add(extraCost, getGasForPrecompiles(addr, argsOffset, argsSize))
    sp := pushStackItem(sp, success)
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
    if isStatic {
        if value {
            revert(0, 0)
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

    if and(is_evm, iszero(isStatic)) {
        _pushEVMFrame(gasToPassNew, isStatic)
        success := call(gasToPassNew, addr, value, argsOffset, argsSize, 0, 0)
        frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
        _popEVMFrame()
    }

    // zkEVM native
    if and(iszero(is_evm), iszero(isStatic)) {
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
}

function performCall(oldSp, evmGasLeft, isStatic) -> extraCost, sp {
    let gasToPass,addr,value,argsOffset,argsSize,retOffset,retSize

    gasToPass, sp := popStackItem(oldSp)
    addr, sp := popStackItem(sp)
    value, sp := popStackItem(sp)
    argsOffset, sp := popStackItem(sp)
    argsSize, sp := popStackItem(sp)
    retOffset, sp := popStackItem(sp)
    retSize, sp := popStackItem(sp)

    // static_gas = 0
    // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
    // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
    // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
    // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called. 2300 is thus removed from the cost, and also added to the gas input.
    // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.

    extraCost := 0
    if iszero(warmAddress(addr)) {
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

    checkMemOverflow(add(argsOffset, argsSize))
    checkMemOverflow(add(retOffset, retSize))

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

    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    extraCost := add(extraCost, getGasForPrecompiles(addr, argsOffset, argsSize))
    sp := pushStackItem(sp,success) 
}

function delegateCall(oldSp, oldIsStatic, evmGasLeft) -> sp, isStatic, extraCost {
    let addr, gasToPass, argsOffset, argsSize, retOffset, retSize

    sp := oldSp
    isStatic := oldIsStatic

    gasToPass, sp := popStackItem(sp)
    addr, sp := popStackItem(sp)
    argsOffset, sp := popStackItem(sp)
    argsSize, sp := popStackItem(sp)
    retOffset, sp := popStackItem(sp)
    retSize, sp := popStackItem(sp)

    checkMemOverflow(add(add(argsOffset, argsSize), MEM_OFFSET_INNER()))
    checkMemOverflow(add(add(retOffset, retSize), MEM_OFFSET_INNER()))

    if iszero(_isEVM(addr)) {
        revert(0, 0)
    }

    extraCost := 0
    if iszero(warmAddress(addr)) {
        extraCost := 2500
    }

    {
        let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
        extraCost := add(extraCost,maxExpand)
    }
    gasToPass := capGas(evmGasLeft,gasToPass)

    // TODO: Do this
    // if warmAccount(addr) {
    //     extraCost = GAS_WARM_ACCESS;
    // } else {
    //     extraCost = GAS_COLD_ACCOUNT_ACCESS;
    // }

    _pushEVMFrame(gasToPass, isStatic)
    let success := delegatecall(
        // We can not just pass all gas here to prevert overflow of zkEVM gas counter
        gasToPass,
        addr,
        add(MEM_OFFSET_INNER(), argsOffset),
        argsSize,
        0,
        0
    )

    let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)

    _popEVMFrame()

    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
    extraCost := add(extraCost, getGasForPrecompiles(addr, argsOffset, argsSize))
    sp := pushStackItem(sp, success)
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
    if _calleeIsEVM {
        _pushEVMFrame(_calleeGas, true)
        // TODO Check the following comment from zkSync .sol.
        // We can not just pass all gas here to prevert overflow of zkEVM gas counter
        success := staticcall(_calleeGas, _callee, _inputOffset, _inputLen, 0, 0)

        _gasLeft := _saveReturndataAfterEVMCall(_outputOffset, _outputLen)
        _popEVMFrame()
    }

    // zkEVM native
    if iszero(_calleeIsEVM) {
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
    //selector is 0x24e5ab4a

    mstore8(0, 0x24)
    mstore8(1, 0xe5)
    mstore8(2, 0xab)
    mstore8(3, 0x4a)

    let success := staticcall(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, 4, 0, 32)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    gasLeft := mload(0)
}

function genericCreate(addr, offset, size, sp, value, evmGasLeftOld) -> result, evmGasLeft {
    pop(warmAddress(addr))

    _eraseReturndataPointer()

    let gasForTheCall := capGas(evmGasLeftOld,INF_PASS_GAS())

    if lt(balance(addr),value) {
        revert(0,0)
    }

    let nonceNewAddr := getNonce(addr)
    let bytecodeNewAddr := extcodesize(addr)
    if or(gt(nonceNewAddr, 0), gt(bytecodeNewAddr, 0)) {
        incrementNonce(address())
        revert(0, 0)
    }

    offset := add(MEM_OFFSET_INNER(), offset)

    sp := pushStackItem(sp, mload(sub(offset, 0x80)))
    sp := pushStackItem(sp, mload(sub(offset, 0x60)))
    sp := pushStackItem(sp, mload(sub(offset, 0x40)))
    sp := pushStackItem(sp, mload(sub(offset, 0x20)))

    // Selector
    mstore(sub(offset, 0x80), 0x5b16a23c)
    // Arg1: address
    mstore(sub(offset, 0x60), addr)
    // Arg2: init code
    // Where the arg starts (third word)
    mstore(sub(offset, 0x40), 0x40)
    // Length of the init code
    mstore(sub(offset, 0x20), size)

    _pushEVMFrame(gasForTheCall, false)

    result := call(INF_PASS_GAS(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x64), add(size, 0x64), 0, 0)

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

    incrementNonce(address())

    let back

    back, sp := popStackItem(sp)
    mstore(sub(offset, 0x20), back)
    back, sp := popStackItem(sp)
    mstore(sub(offset, 0x40), back)
    back, sp := popStackItem(sp)
    mstore(sub(offset, 0x60), back)
    back, sp := popStackItem(sp)
    mstore(sub(offset, 0x80), back)
}

function performExtCodeCopy(evmGas,oldSp) -> evmGasLeft, sp {
    evmGasLeft := chargeGas(evmGas, 100)

    let addr, dest, offset, len
    addr, sp := popStackItem(oldSp)
    dest, sp := popStackItem(sp)
    offset, sp := popStackItem(sp)
    len, sp := popStackItem(sp)

    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
    // minimum_word_size = (size + 31) / 32

    let dynamicGas := add(
        mul(3, shr(5, add(len, 31))),
        expandMemory(add(dest, len))
    )
    if iszero(warmAddress(addr)) {
        dynamicGas := add(dynamicGas, 2500)
    }
    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

    let len_32 := shr(5, len)
    for {let i := 0} lt(i, len_32) { i := add(i, 1) } {
        mstore(shl(5,i),0)
    }
    let size_32 := shl(5,len_32)
    let rest_32 := sub(len, size_32)
    for {let i := 0} lt(i, rest_32) { i := add(i, 1) } {
        mstore8(add(size_32,i),0)
    }
    // Gets the code from the addr
    pop(_fetchDeployedCode(addr, add(offset, MEM_OFFSET_INNER()), len))
}

function performCreate(evmGas,oldSp,isStatic) -> evmGasLeft, sp {
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        revert(0, 0)
    }

    let value, offset, size

    value, sp := popStackItem(oldSp)
    offset, sp := popStackItem(sp)
    size, sp := popStackItem(sp)

    checkMemOverflow(add(MEM_OFFSET_INNER(), add(offset, size)))

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revert(0, 0)
    }

    if gt(value, balance(address())) {
        revert(0, 0)
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

    let addr := getNewAddress(address())

    let result
    result, evmGasLeft := genericCreate(addr, offset, size, sp, value, evmGasLeft)

    switch result
        case 0 { sp := pushStackItem(sp, 0) }
        default { sp := pushStackItem(sp, addr) }
}

function performCreate2(evmGas, oldSp, isStatic) -> evmGasLeft, sp, result, addr{
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        revert(0, 0)
    }

    let value, offset, size, salt

    value, sp := popStackItem(oldSp)
    offset, sp := popStackItem(sp)
    size, sp := popStackItem(sp)
    salt, sp := popStackItem(sp)

    checkMemOverflow(add(MEM_OFFSET_INNER(), add(offset, size)))

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revert(0, 0)
    }

    if gt(value, balance(address())) {
        revert(0, 0)
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

    {
        let hashedBytecode := keccak256(add(MEM_OFFSET_INNER(), offset), size)
        mstore8(0, 0xFF)
        mstore(0x01, shl(0x60, address()))
        mstore(0x15, salt)
        mstore(0x35, hashedBytecode)
    }

    addr := and(
        keccak256(0, 0x55),
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    )

    result, evmGasLeft := genericCreate(addr, offset, size, sp, value, evmGasLeft) 
}
