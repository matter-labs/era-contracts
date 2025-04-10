////////////////////////////////////////////////////////////////
//                      CONSTANTS
////////////////////////////////////////////////////////////////

function ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008002
}

function NONCE_HOLDER_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008003
}

function DEPLOYER_SYSTEM_CONTRACT() -> addr {
    addr :=  0x0000000000000000000000000000000000008006
}

function CODE_ORACLE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008012
}

function EVM_GAS_MANAGER_CONTRACT() -> addr {   
    addr :=  0x0000000000000000000000000000000000008013
}

function EVM_HASHES_STORAGE_CONTRACT() -> addr {   
    addr :=  0x0000000000000000000000000000000000008015
}

function MSG_VALUE_SYSTEM_CONTRACT() -> addr {
    addr :=  0x0000000000000000000000000000000000008009
}

function PANIC_RETURNDATASIZE_OFFSET() -> offset {
    offset := mul(23, 32)
}

function ORIGIN_CACHE_OFFSET() -> offset {
    offset := add(PANIC_RETURNDATASIZE_OFFSET(), 32)
}

function GASPRICE_CACHE_OFFSET() -> offset {
    offset := add(ORIGIN_CACHE_OFFSET(), 32)
}

function COINBASE_CACHE_OFFSET() -> offset {
    offset := add(GASPRICE_CACHE_OFFSET(), 32)
}

function BLOCKTIMESTAMP_CACHE_OFFSET() -> offset {
    offset := add(COINBASE_CACHE_OFFSET(), 32)
}

function BLOCKNUMBER_CACHE_OFFSET() -> offset {
    offset := add(BLOCKTIMESTAMP_CACHE_OFFSET(), 32)
}

function GASLIMIT_CACHE_OFFSET() -> offset {
    offset := add(BLOCKNUMBER_CACHE_OFFSET(), 32)
}

function CHAINID_CACHE_OFFSET() -> offset {
    offset := add(GASLIMIT_CACHE_OFFSET(), 32)
}

function BASEFEE_CACHE_OFFSET() -> offset {
    offset := add(CHAINID_CACHE_OFFSET(), 32)
}

function LAST_RETURNDATA_SIZE_OFFSET() -> offset {
    offset := add(BASEFEE_CACHE_OFFSET(), 32)
}

// Note: we have an empty memory slot after LAST_RETURNDATA_SIZE_OFFSET(), it is used to simplify stack logic

function STACK_OFFSET() -> offset {
    offset := add(LAST_RETURNDATA_SIZE_OFFSET(), 64)
}

function MAX_STACK_SLOT_OFFSET() -> offset {
    offset := add(STACK_OFFSET(), mul(1023, 32))
}

function BYTECODE_LEN_OFFSET() -> offset {
    offset := add(MAX_STACK_SLOT_OFFSET(), 32)
}

function MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN() -> max {
    max := 24576 // EIP-170
}

function MAX_POSSIBLE_INIT_BYTECODE_LEN() -> max {
    max := mul(2, MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()) // EIP-3860
}

function MEM_LEN_OFFSET() -> offset {
    offset := add(BYTECODE_LEN_OFFSET(), 32)
}

function MEM_OFFSET() -> offset {
    offset := add(MEM_LEN_OFFSET(), 32)
}

// Used to simplify gas calculations for memory expansion.
// The cost to increase the memory to 12 MB is close to 277M EVM gas
function MAX_POSSIBLE_MEM_LEN() -> max {
    max := 0xC00000 // 12MB
}

function MAX_UINT() -> max_uint {
    max_uint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
}

function MAX_UINT64() -> max {
    max := sub(shl(64, 1), 1)
}

// Each evm gas is 5 zkEVM one
function GAS_DIVISOR() -> gas_div { gas_div := 5 }

function OVERHEAD() -> overhead { overhead := 2000 }

function MAX_UINT32() -> ret { ret := 4294967295 } // 2^32 - 1

function MAX_POINTER_READ_OFFSET() -> ret { ret := sub(MAX_UINT32(), 32) } // EraVM will panic if offset + length overflows u32

function EMPTY_KECCAK() -> value {  // keccak("")
    value := 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
}

function ADDRESS_MASK() -> value { // mask for lower 160 bits
    value := 0xffffffffffffffffffffffffffffffffffffffff
}

function PREVRANDAO_VALUE() -> value {
    value := 2500000000000000 // This value is fixed in EraVM
}

/// @dev This restriction comes from circuit precompile call limitations
/// In future we should use MAX_UINT32 to prevent overflows during gas costs calculation
function MAX_MODEXP_INPUT_FIELD_SIZE() -> ret {
    ret := 32 // 256 bits
}

////////////////////////////////////////////////////////////////
//                  GENERAL FUNCTIONS
////////////////////////////////////////////////////////////////

// abort the whole EVM execution environment, including parent frames
function abortEvmEnvironment() {
    revert(0, 0)
}

function $llvm_NoInline_llvm$_invalid() { // revert consuming all EVM gas
    panic()
}

function panic() { // revert consuming all EVM gas
    // we return empty 32 bytes encoding 0 gas left if caller is EVM, and 0 bytes if caller isn't EVM
    // it is done without if-else block so this function will be inlined
    mstore(0, 0)
    revert(0, mload(PANIC_RETURNDATASIZE_OFFSET()))
}

function cached(cacheIndex, value) -> _value {
    _value := value
    mstore(cacheIndex, _value)
}

function chargeGas(prevGas, toCharge) -> gasRemaining {
    if lt(prevGas, toCharge) {
        panic()
    }

    gasRemaining := sub(prevGas, toCharge)
}

function getEvmGasFromContext() -> evmGas {
    // Caller must pass at least OVERHEAD() ergs
    let _gas := gas()
    if gt(_gas, OVERHEAD()) {
        evmGas := div(sub(_gas, OVERHEAD()), GAS_DIVISOR())
    }
}

// The argument to this function is the offset into the memory region IN BYTES.
function expandMemory(offset, size) -> gasCost {
    // memory expansion costs 0 if size is 0
    if size {
        checkOverflow(offset, size)
        gasCost := _expandMemoryInternal(add(offset, size))
    }
}

// This function can overflow, it is the job of the caller to ensure that it does not.
// The argument to this function is the new size of memory IN BYTES.
function _expandMemoryInternal(newMemsize) -> gasCost {
    if gt(newMemsize, MAX_POSSIBLE_MEM_LEN()) {
        panic()
    }   

    let oldSizeInWords := mload(MEM_LEN_OFFSET())

    // div rounding up
    let newSizeInWords := shr(5, add(newMemsize, 31))

    // memory_size_word = (memory_byte_size + 31) / 32
    // memory_cost = (memory_size_word ** 2) / 512 + (3 * memory_size_word)
    // memory_expansion_cost = new_memory_cost - last_memory_cost
    if gt(newSizeInWords, oldSizeInWords) {
        let linearPart := mul(3, sub(newSizeInWords, oldSizeInWords))
        let quadraticPart := sub(
            shr(
                9,
                mul(newSizeInWords, newSizeInWords),
            ),
            shr(
                9,
                mul(oldSizeInWords, oldSizeInWords),
            )
        )

        gasCost := add(linearPart, quadraticPart)

        mstore(MEM_LEN_OFFSET(), newSizeInWords)
    }
}

// Returns 0 if size is 0
function _memsizeRequired(offset, size) -> memorySize {
    if size {
        checkOverflow(offset, size)
        memorySize := add(offset, size)
    }
}

function expandMemory2(retOffset, retSize, argsOffset, argsSize) -> gasCost {
    let maxNewMemsize := _memsizeRequired(retOffset, retSize)
    let argsMemsize := _memsizeRequired(argsOffset, argsSize)

    if lt(maxNewMemsize, argsMemsize) {
        maxNewMemsize := argsMemsize  
    }

    if maxNewMemsize { // Memory expansion costs 0 if size is 0
        gasCost := _expandMemoryInternal(maxNewMemsize)
    }
}

function checkOverflow(data1, data2) {
    if lt(add(data1, data2), data2) {
        panic()
    }
}

function insufficientBalance(value) -> res {
    if value {
        res := gt(value, selfbalance())
    }
}

// It is the responsibility of the caller to ensure that ip is correct
function $llvm_AlwaysInline_llvm$_readIP(ip) -> opcode {
    opcode := shr(248, activePointerLoad(ip))
}

// It is the responsibility of the caller to ensure that start and length is correct
function readBytes(start, length) -> value {
    let rawValue := activePointerLoad(start)

    value := shr(mul(8, sub(32, length)), rawValue)
    // will be padded by zeroes if out of bounds
}

function getCodeAddress() -> addr {
    addr := verbatim_0i_1o("code_source")
}

function loadReturndataIntoActivePtr() {
    verbatim_0i_0o("return_data_ptr_to_active")
}

function swapActivePointer(index0, index1) {
    verbatim_2i_0o("active_ptr_swap", index0, index1)
}

function swapActivePointerWithEvmReturndataPointer() {
    verbatim_2i_0o("active_ptr_swap", 0, 2)
}

function activePointerLoad(pos) -> res {
    res := verbatim_1i_1o("active_ptr_data_load", pos)
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

function getIsStaticFromCallFlags() -> isStatic {
    isStatic := verbatim_0i_1o("get_global::call_flags")
    isStatic := iszero(iszero(and(isStatic, 0x04)))
}

function loadFromReturnDataPointer(pos) -> res {
    swapActivePointer(0, 1)
    loadReturndataIntoActivePtr()
    res := activePointerLoad(pos)
    swapActivePointer(0, 1)
}

function fetchFromSystemContract(to, argSize) -> res {
    let success := staticcall(gas(), to, 0, argSize, 0, 0)

    if iszero(success) {
        // This error should never happen
        abortEvmEnvironment()
    }

    res := loadFromReturnDataPointer(0)
}

function isAddrEmpty(addr) -> isEmpty {
    // We treat constructing EraVM contracts as non-existing
    if iszero(extcodesize(addr)) { // YUL doesn't have short-circuit evaluation
        if iszero(balance(addr)) {
            if iszero(getRawNonce(addr)) {
                isEmpty := 1
            }
        }
    }
}

// returns minNonce + 2^128 * deployment nonce.
function getRawNonce(addr) -> nonce {
    // selector for function getRawNonce(address addr)
    mstore(0, 0x5AA9B6B500000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)
    nonce := fetchFromSystemContract(NONCE_HOLDER_SYSTEM_CONTRACT(), 36)
}

function getRawCodeHash(addr) -> hash {
    // function getRawCodeHash(address _address)
    mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)
    hash := fetchFromSystemContract(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 36)
}

function getEvmExtcodehash(versionedBytecodeHash) -> evmCodeHash {
    // function getEvmCodeHash(bytes32 versionedBytecodeHash) external view returns(bytes32)
    mstore(0, 0x5F8F27B000000000000000000000000000000000000000000000000000000000)
    mstore(4, versionedBytecodeHash)
    evmCodeHash := fetchFromSystemContract(EVM_HASHES_STORAGE_CONTRACT(), 36)
}

function isHashOfConstructedEvmContract(rawCodeHash) -> isConstructedEVM {
    let version := shr(248, rawCodeHash)
    let isConstructedFlag := xor(shr(240, rawCodeHash), 1)
    isConstructedEVM := and(eq(version, 2), isConstructedFlag)
}

// Basically performs an extcodecopy, while returning the length of the copied bytecode.
function fetchDeployedCode(addr, dstOffset, srcOffset, len) -> copiedLen {
    let success, rawCodeHash := fetchBytecode(addr)
    // it fails if we don't have any code deployed at this address
    if success {
        // The length of the bytecode is encoded in versioned bytecode hash
        let codeLen := and(shr(224, rawCodeHash), 0xffff)

        if eq(shr(248, rawCodeHash), 1) {
            // For native zkVM contracts length encoded in words, not bytes
            codeLen := shl(5, codeLen) // * 32
        }

        if gt(len, codeLen) {
            len := codeLen
        }
    
        let _returndatasize := returndatasize()
        if gt(srcOffset, _returndatasize) {
            srcOffset := _returndatasize
        }
    
        if gt(add(len, srcOffset), _returndatasize) {
            len := sub(_returndatasize, srcOffset)
        }
    
        if len {
            returndatacopy(dstOffset, srcOffset, len)
        }
    
        copiedLen := len
    } 
}

function fetchBytecode(addr) -> success, rawCodeHash {
    rawCodeHash := getRawCodeHash(addr)
    mstore(0, rawCodeHash)
    
    success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)
}

function build_farcall_abi(isSystemCall, gas, dataStart, dataLength) -> farCallAbi {
    farCallAbi := shl(248, isSystemCall)
    // dataOffset is 0
    farCallAbi := or(farCallAbi, shl(64, dataStart))
    farCallAbi :=  or(farCallAbi, shl(96, dataLength))
    farCallAbi :=  or(farCallAbi, shl(192, gas))
    // shardId is 0
    // forwardingMode is 0
}

function performSystemCall(to, dataLength) {
    let success := performSystemCallRevertable(to, dataLength)

    if iszero(success) {
        // This error should never happen
        abortEvmEnvironment()
    }
}

function performSystemCallRevertable(to, dataLength) -> success {
    // system call, dataStart is 0
    let farCallAbi := build_farcall_abi(1, gas(), 0, dataLength)
    success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
}

function rawCall(gas, to, value, dataStart, dataLength, outputOffset, outputLen) -> success {
    switch iszero(value)
    case 0 {
        // system call to MsgValueSimulator, but call to "to" will be non-system
        let farCallAbi := build_farcall_abi(1, gas, dataStart, dataLength)
        success := verbatim_6i_1o("system_call", MSG_VALUE_SYSTEM_CONTRACT(), farCallAbi, value, to, 0, 0)
        if outputLen {
            if success {
                let rtdz := returndatasize()
                switch lt(rtdz, outputLen)
                case 0 { returndatacopy(outputOffset, 0, outputLen) }
                default { returndatacopy(outputOffset, 0, rtdz) }
            }
        }
    }
    default {
        // not a system call
        let farCallAbi := build_farcall_abi(0, gas, dataStart, dataLength)
        success := verbatim_4i_1o("raw_call", to, farCallAbi, outputOffset, outputLen)
    }
}

function rawStaticcall(gas, to, dataStart, dataLength, outputOffset, outputLen) -> success {
    // not a system call
    let farCallAbi := build_farcall_abi(0, gas, dataStart, dataLength)
    success := verbatim_4i_1o("raw_static_call", to, farCallAbi, outputOffset, outputLen)
}

////////////////////////////////////////////////////////////////
//                     STACK OPERATIONS
////////////////////////////////////////////////////////////////

function pushOpcodeInner(size, ip, sp, evmGas, oldStackHead) -> newIp, newSp, evmGasLeft, stackHead {
    evmGasLeft := chargeGas(evmGas, 3)

    newIp := add(ip, 1)
    let value := readBytes(newIp, size)

    newSp, stackHead := pushStackItem(sp, value, oldStackHead)
    newIp := add(newIp, size)
}

function dupStackItem(sp, evmGas, position, oldStackHead) -> newSp, evmGasLeft, stackHead {
    evmGasLeft := chargeGas(evmGas, 3)

    if iszero(lt(sp, MAX_STACK_SLOT_OFFSET())) {
        panic()
    }
    
    let tempSp := sub(sp, mul(0x20, sub(position, 1)))

    if lt(tempSp, STACK_OFFSET())  {
        panic()
    }

    mstore(sp, oldStackHead)
    stackHead := mload(tempSp)
    newSp := add(sp, 0x20)
}

function swapStackItem(sp, evmGas, position, oldStackHead) ->  evmGasLeft, stackHead {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, position))

    if lt(tempSp, STACK_OFFSET())  {
        panic()
    }

    stackHead := mload(tempSp)                    
    mstore(tempSp, oldStackHead)
}

function popStackItem(sp, oldStackHead) -> a, newSp, stackHead {
    // We can not return any error here, because it would break compatibility
    if lt(sp, STACK_OFFSET()) {
        panic()
    }

    a := oldStackHead
    newSp := sub(sp, 0x20)
    stackHead := mload(newSp)
}

function pushStackItem(sp, item, oldStackHead) -> newSp, stackHead {
    if iszero(lt(sp, MAX_STACK_SLOT_OFFSET())) {
        panic()
    }

    mstore(sp, oldStackHead)
    stackHead := item
    newSp := add(sp, 0x20)
}

function popStackItemWithoutCheck(sp, oldStackHead) -> a, newSp, stackHead {
    a := oldStackHead
    newSp := sub(sp, 0x20)
    stackHead := mload(newSp)
}

function popStackCheck(sp, numInputs) {
    if lt(sub(sp, mul(0x20, sub(numInputs, 1))), STACK_OFFSET()) {
        panic()
    }
}

function accessStackHead(sp, stackHead) -> value {
    if lt(sp, STACK_OFFSET()) {
        panic()
    }

    value := stackHead
}

////////////////////////////////////////////////////////////////
//               EVM GAS MANAGER FUNCTIONALITY
////////////////////////////////////////////////////////////////

// Address higher bytes must be cleaned before
function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
    // function warmAccount(address account)
    // non-standard selector 0x00
    // addr is packed in the same word with selector
    mstore(0, addr)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 32)

    if returndatasize() {
        isWarm := true
    }
}

function isSlotWarm(key) -> isWarm {
    // non-standard selector 0x01
    mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
    mstore(1, key)
    let success := staticcall(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 33, 0, 0)

    if iszero(success) {
        // This error should never happen
        abortEvmEnvironment()
    }

    if returndatasize() {
        isWarm := true
    }
}

function warmSlot(key, currentValue) -> isWarm, originalValue {
    // non-standard selector 0x02
    mstore(0, 0x0200000000000000000000000000000000000000000000000000000000000000)
    mstore(1, key)
    mstore(33, currentValue)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 65)

    originalValue := currentValue
    if returndatasize() {
        isWarm := true
        originalValue := loadFromReturnDataPointer(0)
    }
}

function pushEvmFrame(passGas, isStatic) {
    // function pushEVMFrame
    // non-standard selector 0x03
    mstore(0, or(0x0300000000000000000000000000000000000000000000000000000000000000, isStatic))
    mstore(32, passGas)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 64)
}

function consumeEvmFrame() -> passGas, isStatic, callerEVM {
    // function consumeEvmFrame(_caller) external returns (uint256 passGas, uint256 auxDataRes)
    // non-standard selector 0x04
    mstore(0, or(0x0400000000000000000000000000000000000000000000000000000000000000, caller()))

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 32)

    let _returndatasize := returndatasize()
    if _returndatasize {
        callerEVM := true
        mstore(PANIC_RETURNDATASIZE_OFFSET(), 32) // we should return 0 gas after panics

        passGas := loadFromReturnDataPointer(0)
        
        isStatic := gt(_returndatasize, 32)
    }
}

function resetEvmFrame() {
    // function resetEvmFrame()
    // non-standard selector 0x05
    mstore(0, 0x0500000000000000000000000000000000000000000000000000000000000000)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 1)
}

////////////////////////////////////////////////////////////////
//               CALLS FUNCTIONALITY
////////////////////////////////////////////////////////////////

function performCall(oldSp, evmGasLeft, oldStackHead, isStatic) -> newGasLeft, sp, stackHead {
    let gasToPass, rawAddr, value, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, 7)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    rawAddr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    // static_gas = 0
    // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
    // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
    // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
    // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called.
    // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.

    let addr, gasUsed := _genericPrecallLogic(rawAddr, argsOffset, argsSize, retOffset, retSize)

    if gt(value, 0) {
        if isStatic {
            panic()
        }

        gasUsed := add(gasUsed, 9000) // positive_value_cost

        if isAddrEmpty(addr) {
            gasUsed := add(gasUsed, 25000) // value_to_empty_account_cost
        }
    }

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)
    gasToPass := capGasForCall(evmGasLeft, gasToPass)
    evmGasLeft := sub(evmGasLeft, gasToPass)

    if gt(value, 0) {
        gasToPass := add(gasToPass, 2300)
    }

    let success, frameGasLeft := _genericCall(
        addr,
        gasToPass,
        value,
        add(argsOffset, MEM_OFFSET()),
        argsSize,
        add(retOffset, MEM_OFFSET()),
        retSize,
        isStatic
    )

    newGasLeft := add(evmGasLeft, frameGasLeft)
    stackHead := success
}

function performStaticCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
    let gasToPass, rawAddr, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, 6)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    rawAddr, sp, stackHead  := popStackItemWithoutCheck(sp, stackHead)
    argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    let addr, gasUsed := _genericPrecallLogic(rawAddr, argsOffset, argsSize, retOffset, retSize)

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)
    gasToPass := capGasForCall(evmGasLeft, gasToPass)
    evmGasLeft := sub(evmGasLeft, gasToPass)

    let success, frameGasLeft := _genericCall(
        addr,
        gasToPass,
        0,
        add(MEM_OFFSET(), argsOffset),
        argsSize,
        add(MEM_OFFSET(), retOffset),
        retSize,
        true
    )

    newGasLeft := add(evmGasLeft, frameGasLeft)
    stackHead := success
}


function performDelegateCall(oldSp, evmGasLeft, isStatic, oldStackHead) -> newGasLeft, sp, stackHead {
    let gasToPass, rawAddr, rawArgsOffset, argsSize, rawRetOffset, retSize

    popStackCheck(oldSp, 6)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    rawAddr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    rawArgsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    rawRetOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    let addr, gasUsed := _genericPrecallLogic(rawAddr, rawArgsOffset, argsSize, rawRetOffset, retSize)

    newGasLeft := chargeGas(evmGasLeft, gasUsed)
    gasToPass := capGasForCall(newGasLeft, gasToPass)

    newGasLeft := sub(newGasLeft, gasToPass)

    let success
    let frameGasLeft := gasToPass

    let retOffset := add(MEM_OFFSET(), rawRetOffset)
    let argsOffset := add(MEM_OFFSET(), rawArgsOffset)

    let rawCodeHash := getRawCodeHash(addr)
    switch isHashOfConstructedEvmContract(rawCodeHash)
    case 0 {
        // Not a constructed EVM contract
        let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
        switch precompileCost
        case 0 {
            // Not a precompile
            _eraseReturndataPointer()

            let isCallToEmptyContract := iszero(addr) // 0x00 is always "empty"
            if iszero(isCallToEmptyContract) {
                isCallToEmptyContract := iszero(and(shr(224, rawCodeHash), 0xffff)) // is codelen zero?
            }

            if isCallToEmptyContract {
                // In case of a call to the EVM contract that is currently being constructed, 
                // the DefaultAccount bytecode will be used instead. This is implemented at the virtual machine level.
                success := delegatecall(gas(), addr, argsOffset, argsSize, retOffset, retSize)
                _saveReturndataAfterZkEVMCall()               
            }

            // We forbid delegatecalls to EraVM native contracts
        } 
        default {
            // Precompile. Simulate using staticcall, since EraVM behavior differs here
            success, frameGasLeft := callPrecompile(addr, precompileCost, gasToPass, 0, argsOffset, argsSize, retOffset, retSize, true)
        }
    }
    default {
        // Constructed EVM contract
        pushEvmFrame(gasToPass, isStatic)
        // pass all remaining native gas
        success := delegatecall(gas(), addr, argsOffset, argsSize, 0, 0)

        frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
        if iszero(success) {
            resetEvmFrame()
        }
    }

    newGasLeft := add(newGasLeft, frameGasLeft)
    stackHead := success
}

function _genericPrecallLogic(rawAddr, argsOffset, argsSize, retOffset, retSize) -> addr, gasUsed {
    // memory_expansion_cost
    gasUsed := expandMemory2(retOffset, retSize, argsOffset, argsSize)

    addr := and(rawAddr, ADDRESS_MASK())

    let addressAccessCost := 100 // warm address access cost
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        addressAccessCost := 2600 // cold address access cost
    }

    gasUsed := add(gasUsed, addressAccessCost)
}

function _genericCall(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
    let rawCodeHash := getRawCodeHash(addr)
    switch isHashOfConstructedEvmContract(rawCodeHash)
    case 0 {
        // zkEVM native call
        let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
        switch precompileCost
        case 0 {
            // just smart contract
            success, frameGasLeft := callZkVmNative(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic, rawCodeHash)
        } 
        default {
            // precompile
            success, frameGasLeft := callPrecompile(addr, precompileCost, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic)
        }
    }
    default {
        switch insufficientBalance(value)
        case 0 {
            pushEvmFrame(gasToPass, isStatic)
            // pass all remaining native gas
            success := call(gas(), addr, value, argsOffset, argsSize, 0, 0)
            frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
            if iszero(success) {
                resetEvmFrame()
            }
        }
        default {
            frameGasLeft := gasToPass
            _eraseReturndataPointer()
        }
    }
}

function callPrecompile(addr, precompileCost, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
    switch lt(gasToPass, precompileCost)
    case 0 {
        let zkVmGasToPass := gas() // pass all remaining gas, precompiles should not call any contracts

        switch isStatic
        case 0 {
            success := rawCall(zkVmGasToPass, addr, value, argsOffset, argsSize, retOffset, retSize)
        }
        default {
            success := rawStaticcall(zkVmGasToPass, addr, argsOffset, argsSize, retOffset, retSize)
        }
        
        _saveReturndataAfterZkEVMCall()
    
        if success {
            frameGasLeft := sub(gasToPass, precompileCost)
        }
        // else consume all provided gas
    }
    default {
        // consume all provided gas
        _eraseReturndataPointer()
    }
}

// Call native ZkVm contract from EVM context
function callZkVmNative(addr, evmGasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic, rawCodeHash) -> success, frameGasLeft {
    let zkEvmGasToPass := mul(evmGasToPass, GAS_DIVISOR()) // convert EVM gas -> ZkVM gas

    let emptyContractExecutionCost := 500 // enough to call "empty" contract
    let isEmptyContract := or(iszero(addr), iszero(and(shr(224, rawCodeHash), 0xffff)))
    if isEmptyContract {
        // we should add some gas to cover overhead of calling EmptyContract or DefaultAccount
        // if value isn't zero, MsgValueSimulator will take required gas directly from our frame (as 2300 stipend)
        if iszero(value) {
            zkEvmGasToPass := add(zkEvmGasToPass, emptyContractExecutionCost)
        }
    }

    if gt(zkEvmGasToPass, MAX_UINT32()) { // just in case
        zkEvmGasToPass := MAX_UINT32()
    }

    // Please note, that decommitment cost and MsgValueSimulator additional overhead will be charged directly from this frame
    let zkEvmGasBefore := gas()
    switch isStatic
    case 0 {
        success := call(zkEvmGasToPass, addr, value, argsOffset, argsSize, retOffset, retSize)
    }
    default {
        success := staticcall(zkEvmGasToPass, addr, argsOffset, argsSize, retOffset, retSize)
    }
    let zkEvmGasUsed := sub(zkEvmGasBefore, gas())

    _saveReturndataAfterZkEVMCall()

    if gt(zkEvmGasUsed, zkEvmGasBefore) { // overflow case
        zkEvmGasUsed := 0 // should never happen
    }

    if isEmptyContract {
        if iszero(value) {
            zkEvmGasToPass := sub(zkEvmGasToPass, emptyContractExecutionCost)
        }
    
        zkEvmGasUsed := 0 // Calling empty contracts is free from the EVM point of view
    }

    // refund gas
    if gt(zkEvmGasToPass, zkEvmGasUsed) {
        frameGasLeft := div(sub(zkEvmGasToPass, zkEvmGasUsed), GAS_DIVISOR())
    }
}

function capGasForCall(evmGasLeft, oldGasToPass) -> gasToPass {
    let maxGasToPass := sub(evmGasLeft, shr(6, evmGasLeft)) // evmGasLeft >> 6 == evmGasLeft/64
    gasToPass := oldGasToPass
    if gt(oldGasToPass, maxGasToPass) { 
        gasToPass := maxGasToPass
    }
}

// The gas cost mentioned here is purely the cost of the contract, 
// and does not consider the cost of the call itself nor the instructions 
// to put the parameters in memory. 
function getGasForPrecompiles(addr, argsOffset, argsSize) -> gasToCharge {
    switch addr
        case 0x01 { // ecRecover
            gasToCharge := 3000
        }
        case 0x02 { // SHA2-256
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(60, mul(12, dataWordSize))
        }
        case 0x03 { // RIPEMD-160
            // We do not support RIPEMD-160
            gasToCharge := 0
        }
        case 0x04 { // identity
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(15, mul(3, dataWordSize))
        }
        case 0x05 { // modexp
            gasToCharge := modexpGasCost(argsOffset, argsSize)
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
        // 34,000 * k + 45,000 gas, where k is the number of pairings being computed.
        // The input must always be a multiple of 6 32-byte values.
        case 0x08 { // ecPairing
            let k := div(argsSize, 0xC0) // 0xC0 == 6*32
            gasToCharge := add(45000, mul(k, 34000))
        }
        case 0x09 { // blake2f
            // We do not support blake2f
            gasToCharge := 0
        }
        case 0x0a { // kzg point evaluation
            // We do not support kzg point evaluation
            gasToCharge := 0
        }
        default {
            gasToCharge := 0
        }
}

//////////// Modexp gas cost calculation ////////////

function modexpGasCost(inputOffset, inputSize) -> gasToCharge {
    // This precompile is a bit tricky since the gas depends on the input data
    let inputBoundary := add(inputOffset, inputSize)

    // modexp gas cost implements EIP-2565
    // https://eips.ethereum.org/EIPS/eip-2565

    // Expected input layout
    // [0; 31] (32 bytes)	Bsize	Byte size of B
    // [32; 63] (32 bytes)	Esize	Byte size of E
    // [64; 95] (32 bytes)	Msize	Byte size of M
    // [96; ..] input values

    let Bsize := mloadPotentiallyPaddedValue(inputOffset, inputBoundary)
    let Esize := mloadPotentiallyPaddedValue(add(inputOffset, 0x20), inputBoundary)
    let Msize := mloadPotentiallyPaddedValue(add(inputOffset, 0x40), inputBoundary)

    let inputIsTooBig := or(
        gt(Bsize, MAX_MODEXP_INPUT_FIELD_SIZE()), 
        or(gt(Esize, MAX_MODEXP_INPUT_FIELD_SIZE()), gt(Msize, MAX_MODEXP_INPUT_FIELD_SIZE()))
    )

    // The limitated size of parameters also prevents overflows during gas calculations.
    // The current value (32 bytes) violates EVM equivalence. This value comes from circuit limitations.

    switch inputIsTooBig
    case 1 {
        gasToCharge := MAX_UINT64() // Skip calculation, not supported or unpayable
    }
    default {
        // 96 + Bsize, offset of the exponent value
        let expOffset := add(add(inputOffset, 0x60), Bsize)

        // Calculate iteration count
        let iterationCount
        switch gt(Esize, 32)
        case 0 { // if exponent_length <= 32
            let exponent := mloadPotentiallyPaddedValue(expOffset, inputBoundary) // load 32 bytes
            exponent := shr(sub(32, Esize), exponent) // shift to the right if Esize not 32 bytes

            // if exponent == 0: iteration_count = 0
            // else: iteration_count = exponent.bit_length() - 1
            if exponent {
                iterationCount := msb(exponent)
            }
        }
        default { // elif exponent_length > 32
            // iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)

            // load last 32 bytes of exponent
            let exponentLast32Bytes := mloadPotentiallyPaddedValue(add(expOffset, sub(Esize, 32)), inputBoundary)
            iterationCount := add(shl(3, sub(Esize, 32)), msb(exponentLast32Bytes))
        }
        if iszero(iterationCount) {
            iterationCount := 1
        }

        // mult_complexity(Bsize, Msize), EIP-2565
        let words := shr(3, add(getMax(Bsize, Msize), 7))
        let multiplicationComplexity := mul(words, words)

        // return max(200, math.floor(multiplication_complexity * iteration_count / 3))
        gasToCharge := getMax(200, div(mul(multiplicationComplexity, iterationCount), 3))
    }
}

// Read value from bounded memory region. Any out-of-bounds bytes are zeroed out.
function mloadPotentiallyPaddedValue(index, memoryBound) -> value {
    value := mload(index)

    if lt(memoryBound, add(index, 32)) {
        memoryBound := getMax(index, memoryBound)
        let shift := sub(add(index, 32), memoryBound)
        let value := shl(shift, shr(shift, value))
    }
}

// Most significant bit
// credit to https://github.com/PaulRBerg/prb-math/blob/280fc5f77e1b21b9c54013aac51966be33f4a410/src/Common.sol#L323
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

function getMax(a, b) -> result {
    result := a
    if gt(b, a) {
        result := b
    }
}

//////////// Returndata pointers operation ////////////

function _saveReturndataAfterZkEVMCall() {
    swapActivePointerWithEvmReturndataPointer()
    loadReturndataIntoActivePtr()
    swapActivePointerWithEvmReturndataPointer()
    mstore(LAST_RETURNDATA_SIZE_OFFSET(), returndatasize())
}

function _saveReturndataAfterEVMCall(_outputOffset, _outputLen) -> _gasLeft {
    let rtsz := returndatasize()
    swapActivePointerWithEvmReturndataPointer()
    loadReturndataIntoActivePtr()

    // if (rtsz > 31)
    switch gt(rtsz, 31)
        case 0 {
            // Unexpected return data.
            // Most likely out-of-ergs or unexpected error in the emulator or system contracts
            abortEvmEnvironment()
        }
        default {
            _gasLeft := activePointerLoad(0)

            // We copy as much returndata as possible without going over the 
            // returndata size.
            switch lt(sub(rtsz, 32), _outputLen)
                case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }

            mstore(LAST_RETURNDATA_SIZE_OFFSET(), sub(rtsz, 32))

            // Skip first 32 bytes of the returnData
            ptrAddIntoActive(32)
        }
    swapActivePointerWithEvmReturndataPointer()
}

function _eraseReturndataPointer() {
    swapActivePointerWithEvmReturndataPointer()
    let activePtrSize := getActivePtrDataSize()
    ptrShrinkIntoActive(and(activePtrSize, 0xFFFFFFFF))// uint32(activePtrSize)
    swapActivePointerWithEvmReturndataPointer()
    mstore(LAST_RETURNDATA_SIZE_OFFSET(), 0)
}

////////////////////////////////////////////////////////////////
//                 CREATE FUNCTIONALITY
////////////////////////////////////////////////////////////////

function performCreate(oldEvmGasLeft, oldSp, oldStackHead) -> evmGasLeft, sp, stackHead {
    let value, offset, size

    popStackCheck(oldSp, 3)
    value, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    offset, sp, size := popStackItemWithoutCheck(sp, stackHead)

    evmGasLeft, stackHead := $llvm_NoInline_llvm$_genericCreate(offset, size, value, oldEvmGasLeft, false, 0)
}

function performCreate2(oldEvmGasLeft, oldSp, oldStackHead) -> evmGasLeft, sp, stackHead {
    let value, offset, size, salt

    popStackCheck(oldSp, 4)
    value, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    size, sp, salt := popStackItemWithoutCheck(sp, stackHead)

    evmGasLeft, stackHead := $llvm_NoInline_llvm$_genericCreate(offset, size, value, oldEvmGasLeft, true, salt)
}

function $llvm_NoInline_llvm$_genericCreate(offset, size, value, evmGasLeftOld, isCreate2, salt) -> evmGasLeft, addr  {
    // EIP-3860
    if gt(size, MAX_POSSIBLE_INIT_BYTECODE_LEN()) {
        panic()
    }

    // dynamicGas = init_code_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // + hash_cost, if isCreate2
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size, EIP-3860
    // code_deposit_cost = 200 * deployed_code_size, (charged inside call)
    let minimum_word_size := shr(5, add(size, 31)) // rounding up
    let dynamicGas := add(
        mul(2, minimum_word_size),
        expandMemory(offset, size)
    )
    if isCreate2 {
        // hash_cost = 6 * minimum_word_size
        dynamicGas := add(dynamicGas, mul(6, minimum_word_size))
    }
    evmGasLeft := chargeGas(evmGasLeftOld, dynamicGas)

    _eraseReturndataPointer()

    let err := insufficientBalance(value)

    if iszero(err) {
        offset := add(MEM_OFFSET(), offset) // caller must ensure that it doesn't overflow
        evmGasLeft, addr := _executeCreate(offset, size, value, evmGasLeft, isCreate2, salt)
    }
}

function _executeCreate(offset, size, value, evmGasLeftOld, isCreate2, salt) -> evmGasLeft, addr  {
    let gasForTheCall := capGasForCall(evmGasLeftOld, evmGasLeftOld) // pass 63/64 of remaining gas

    let bytecodeHash
    if isCreate2 {
        switch size
        case 0 {
            bytecodeHash := EMPTY_KECCAK()
        }
        default {
            bytecodeHash := keccak256(offset, size)
        }
    }

    // we want to calculate the address of new contract, and if it is deployable (no collision),
    // we need to increment deploy nonce.

    // selector: function precreateEvmAccountFromEmulator(bytes32 salt, bytes32 evmBytecodeHash)
    mstore(0, 0xf81dae8600000000000000000000000000000000000000000000000000000000)
    mstore(4, salt)
    mstore(36, bytecodeHash)
    let canBeDeployed := performSystemCallRevertable(DEPLOYER_SYSTEM_CONTRACT(), 68)

    if canBeDeployed {
        addr := and(loadFromReturnDataPointer(0), ADDRESS_MASK())
        pop($llvm_AlwaysInline_llvm$_warmAddress(addr)) // will stay warm even if constructor reverts
        // so even if constructor reverts, nonce stays incremented and addr stays warm

        // check for code collision
        canBeDeployed := 0
        if iszero(getRawCodeHash(addr)) {
            // check for nonce collision
            if iszero(getRawNonce(addr)) {
                canBeDeployed := 1
            }     
        }
    }

    if iszero(canBeDeployed) {
        // Nonce overflow, EVM not allowed or collision.
        // This is *internal* panic, consuming all passed gas.
        // Note: we should not consume all gas if nonce overflowed, but this should not happen in reality anyway
        evmGasLeft := chargeGas(evmGasLeftOld, gasForTheCall)
        addr := 0
    }


    if canBeDeployed {
        // verification of the correctness of the deployed bytecode and payment of gas for its storage will occur in the frame of the new contract
        pushEvmFrame(gasForTheCall, false)

        // move needed memory slots to the scratch space
        mstore(mul(10, 32), mload(sub(offset, 0x80)))
        mstore(mul(11, 32), mload(sub(offset, 0x60)))
        mstore(mul(12, 32), mload(sub(offset, 0x40)))
        mstore(mul(13, 32), mload(sub(offset, 0x20)))
    
        // selector: function createEvmFromEmulator(address newAddress, bytes calldata _initCode)
        mstore(sub(offset, 0x80), 0xe43cec64)
        mstore(sub(offset, 0x60), addr)
        mstore(sub(offset, 0x40), 0x40) // Where the arg starts (third word)
        mstore(sub(offset, 0x20), size) // Length of the init code
        
        let result := performSystemCallForCreate(value, sub(offset, 0x64), add(size, 0x64))

        // move memory slots back
        mstore(sub(offset, 0x80), mload(mul(10, 32)))
        mstore(sub(offset, 0x60), mload(mul(11, 32)))
        mstore(sub(offset, 0x40), mload(mul(12, 32)))
        mstore(sub(offset, 0x20), mload(mul(13, 32)))
    
        let gasLeft
        switch result
            case 0 {
                addr := 0
                gasLeft := _saveReturndataAfterEVMCall(0, 0)
                resetEvmFrame()
            }
            default {
                gasLeft, addr := _saveConstructorReturnGas()
            }
    
        let gasUsed := sub(gasForTheCall, gasLeft)
        evmGasLeft := chargeGas(evmGasLeftOld, gasUsed)
    }
}

function performSystemCallForCreate(value, bytecodeStart, bytecodeLen) -> success {
    // system call, not constructor call (ContractDeployer will call constructor)
    let farCallAbi := build_farcall_abi(1, gas(), bytecodeStart, bytecodeLen) 

    switch iszero(value)
    case 0 {
        success := verbatim_6i_1o("system_call", MSG_VALUE_SYSTEM_CONTRACT(), farCallAbi, value, DEPLOYER_SYSTEM_CONTRACT(), 1, 0)
    }
    default {
        success := verbatim_6i_1o("system_call", DEPLOYER_SYSTEM_CONTRACT(), farCallAbi, 0, 0, 0, 0)
    }
}

function _saveConstructorReturnGas() -> gasLeft, addr {
    swapActivePointerWithEvmReturndataPointer()
    loadReturndataIntoActivePtr()

    if lt(returndatasize(), 64) {
        // unexpected return data after constructor succeeded, should never happen.
        abortEvmEnvironment()
    }

    // ContractDeployer returns (uint256 gasLeft, address createdContract)
    gasLeft := activePointerLoad(0)
    addr := activePointerLoad(32)

    swapActivePointerWithEvmReturndataPointer()

    _eraseReturndataPointer()
}

////////////////////////////////////////////////////////////////
//               MEMORY REGIONS FUNCTIONALITY
////////////////////////////////////////////////////////////////

// Copy the region of memory
function $llvm_AlwaysInline_llvm$_memcpy(dest, src, len) {
    // Copy all the whole memory words in a cycle
    let destIndex := dest
    let srcIndex := src
    let destEndIndex := add(dest, and(len, sub(0, 32))) // len / 32 words
    for { } lt(destIndex, destEndIndex) {} {
        mstore(destIndex, mload(srcIndex))
        destIndex := add(destIndex, 32)
        srcIndex := add(srcIndex, 32)
    }

    // Copy the remainder (if any)
    let remainderLen := and(len, 31)
    if remainderLen {
        $llvm_AlwaysInline_llvm$_memWriteRemainder(destIndex, mload(srcIndex), remainderLen)
    }
}

// Write the last part of the copied/cleaned memory region (smaller than the memory word)
function $llvm_AlwaysInline_llvm$_memWriteRemainder(dest, remainder, len) {
    let remainderBitLength := shl(3, len) // bytes to bits

    let existingValue := mload(dest)
    let existingValueMask := shr(remainderBitLength, MAX_UINT())
    let existingValueMasked := and(existingValue, existingValueMask) // clean up place for remainder

    let remainderMasked := and(remainder, not(existingValueMask)) // using only `len` higher bytes of remainder word
    mstore(dest, or(remainderMasked, existingValueMasked))
}

// Clean the region of memory
function $llvm_AlwaysInline_llvm$_memsetToZero(dest, len) {
    // Clean all the whole memory words in a cycle
    let destEndIndex := add(dest, and(len, sub(0, 32))) // len / 32 words
    for {let i := dest} lt(i, destEndIndex) { i := add(i, 32) } {
        mstore(i, 0)
    }

    // Clean the remainder (if any)
    let remainderLen := and(len, 31)
    if remainderLen {
        $llvm_AlwaysInline_llvm$_memWriteRemainder(destEndIndex, 0, remainderLen)
    }
}

////////////////////////////////////////////////////////////////
//                 LOGS FUNCTIONALITY 
////////////////////////////////////////////////////////////////

function _genericLog(sp, stackHead, evmGasLeft, topicCount, isStatic) -> newEvmGasLeft, offset, size, newSp, newStackHead {
    newEvmGasLeft := chargeGas(evmGasLeft, 375)

    if isStatic {
        panic()
    }

    let rawOffset
    popStackCheck(sp, add(2, topicCount))
    rawOffset, newSp, newStackHead := popStackItemWithoutCheck(sp, stackHead)
    size, newSp, newStackHead := popStackItemWithoutCheck(newSp, newStackHead)

    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
    let dynamicGas := add(shl(3, size), expandMemory(rawOffset, size))
    dynamicGas := add(dynamicGas, mul(375, topicCount))

    newEvmGasLeft := chargeGas(newEvmGasLeft, dynamicGas)

    if size {
        offset := add(rawOffset, MEM_OFFSET())
    }
}