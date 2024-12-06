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

function MSG_VALUE_SYSTEM_CONTRACT() -> addr {
    addr :=  0x0000000000000000000000000000000000008009
}

function ORIGIN_CACHE_OFFSET() -> offset {
    offset := mul(23, 32)
}

function GASPRICE_CACHE_OFFSET() -> offset {
    offset := mul(24, 32)
}

function COINBASE_CACHE_OFFSET() -> offset {
    offset := mul(25, 32)
}

function BLOCKTIMESTAMP_CACHE_OFFSET() -> offset {
    offset := mul(26, 32)
}

function BLOCKNUMBER_CACHE_OFFSET() -> offset {
    offset := mul(27, 32)
}

function PREVRANDAO_CACHE_OFFSET() -> offset {
    offset := mul(28, 32)
}

function GASLIMIT_CACHE_OFFSET() -> offset {
    offset := mul(29, 32)
}

function CHAINID_CACHE_OFFSET() -> offset {
    offset := mul(30, 32)
}

function BASEFEE_CACHE_OFFSET() -> offset {
    offset := mul(31, 32)
}

function LAST_RETURNDATA_SIZE_OFFSET() -> offset {
    offset := add(BASEFEE_CACHE_OFFSET(), 32)
}

function STACK_OFFSET() -> offset {
    offset := add(LAST_RETURNDATA_SIZE_OFFSET(), 64)
}

function MAX_STACK_SLOT_OFFSET() -> offset {
    offset := add(STACK_OFFSET(), mul(1023, 32))
}

function BYTECODE_LEN_OFFSET() -> offset {
    offset := add(MAX_STACK_SLOT_OFFSET(), 32)
}

function BYTECODE_OFFSET() -> offset {
    offset := add(BYTECODE_LEN_OFFSET(), 32)
}

// reserved empty slot to simplify PUSH N opcodes
function EMPTY_CODE_OFFSET() -> offset {
    offset := add(BYTECODE_OFFSET(), MAX_POSSIBLE_ACTIVE_BYTECODE())
}

function MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN() -> max {
    max := 24576 // EIP-170
}

function MAX_POSSIBLE_INIT_BYTECODE_LEN() -> max {
    max := mul(2, MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()) // EIP-3860
}

function MEM_LEN_OFFSET() -> offset {
    offset := add(EMPTY_CODE_OFFSET(), 32)
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

// We need to pass some gas for MsgValueSimulator internal logic to decommit emulator etc
function MSG_VALUE_SIMULATOR_STIPEND_GAS() -> gas_stipend {
        gas_stipend := 35000 // 27000 + a little bit more
}

function OVERHEAD() -> overhead { overhead := 2000 }

function UINT32_MAX() -> ret { ret := 4294967295 } // 2^32 - 1

function EMPTY_KECCAK() -> value {  // keccak("")
    value := 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
}


////////////////////////////////////////////////////////////////
//                  GENERAL FUNCTIONS
////////////////////////////////////////////////////////////////

// abort the whole EVM execution environment, including parent frames
function abortEvmEnvironment() {
    revert(0, 0)
}

function $llvm_NoInline_llvm$_panic() { // revert consuming all EVM gas
    mstore(0, 0)
    revert(0, 32)
}

function revertWithGas(evmGasLeft) {
    mstore(0, evmGasLeft)
    revert(0, 32)
}

function panic() { // revert consuming all EVM gas
    mstore(0, 0)
    revert(0, 32)
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

// This function can overflow, it is the job of the caller to ensure that it does not.
// The argument to this function is the offset into the memory region IN BYTES.
function expandMemory(offset, size) -> gasCost {
    // memory expansion costs 0 if size is 0
    if size {
        let oldSizeInWords := mload(MEM_LEN_OFFSET())

        // div rounding up
        let newSizeInWords := div(add(add(offset, size), 31), 32)
    
        // memory_size_word = (memory_byte_size + 31) / 32
        // memory_cost = (memory_size_word ** 2) / 512 + (3 * memory_size_word)
        // memory_expansion_cost = new_memory_cost - last_memory_cost
        if gt(newSizeInWords, oldSizeInWords) {
            let linearPart := mul(3, sub(newSizeInWords, oldSizeInWords))
            let quadraticPart := sub(
                div(
                    mul(newSizeInWords, newSizeInWords),
                    512
                ),
                div(
                    mul(oldSizeInWords, oldSizeInWords),
                    512
                )
            )
    
            gasCost := add(linearPart, quadraticPart)
    
            mstore(MEM_LEN_OFFSET(), newSizeInWords)
        }
    }
}

function expandMemory2(retOffset, retSize, argsOffset, argsSize) -> maxExpand {
    switch lt(add(retOffset, retSize), add(argsOffset, argsSize)) 
    case 0 {
        maxExpand := expandMemory(retOffset, retSize)
    }
    default {
        maxExpand := expandMemory(argsOffset, argsSize)
    }
}

function checkMemIsAccessible(relativeOffset, size) {
    if size {
        checkOverflow(relativeOffset, size)

        if gt(add(relativeOffset, size), MAX_POSSIBLE_MEM_LEN()) {
            panic()
        }   
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
function readIP(ip, bytecodeEndOffset) -> opcode {
    if lt(ip, bytecodeEndOffset) {
        opcode := and(mload(sub(ip, 31)), 0xff)
    }
    // STOP else
}

// It is the responsibility of the caller to ensure that start and length is correct
function readBytes(start, length) -> value {
    value := shr(mul(8, sub(32, length)), mload(start))
    // will be padded by zeroes if out of bounds (we have reserved EMPTY_CODE_OFFSET() slot)
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

function getIsStaticFromCallFlags() -> isStatic {
    isStatic := verbatim_0i_1o("get_global::call_flags")
    isStatic := iszero(iszero(and(isStatic, 0x04)))
}

function fetchFromSystemContract(to, argSize) -> res {
    let success := staticcall(gas(), to, 0, argSize, 0, 0)

    if iszero(success) {
        // This error should never happen
        abortEvmEnvironment()
    }

    returndatacopy(0, 0, 32)
    res := mload(0) 
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
    mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)
    hash := fetchFromSystemContract(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 36)
}

function getEvmExtcodehash(addr) -> evmCodeHash {
    mstore(0, 0x54A3314700000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)
    evmCodeHash := fetchFromSystemContract(DEPLOYER_SYSTEM_CONTRACT(), 36)
}

function isEvmContract(addr) -> isEVM {
    // function isAccountEVM(address addr) external view returns (bool);
    mstore(0, 0x8C04047700000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)
    isEVM := fetchFromSystemContract(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 36)
}

function isHashOfConstructedEvmContract(rawCodeHash) -> isConstructedEVM {
    let version := shr(248, rawCodeHash)
    let isConstructedFlag := xor(shr(240, rawCodeHash), 1)
    isConstructedEVM := and(eq(version, 2), isConstructedFlag)
}

// Basically performs an extcodecopy, while returning the length of the copied bytecode.
function fetchDeployedCode(addr, dstOffset, srcOffset, len) -> copiedLen {
    let codeHash := getRawCodeHash(addr)
    mstore(0, codeHash)
    
    let success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)
    // it fails if we don't have any code deployed at this address
    if success {
        returndatacopy(0, 0, 32)
        // The first word of returndata is the true length of the bytecode
        let codeLen := mload(0)

        if gt(len, codeLen) {
            len := codeLen
        }
    
        let shiftedSrcOffset := add(32, srcOffset) // first 32 bytes is length
    
        let _returndatasize := returndatasize()
        if gt(shiftedSrcOffset, _returndatasize) {
            shiftedSrcOffset := _returndatasize
        }
    
        if gt(add(len, shiftedSrcOffset), _returndatasize) {
            len := sub(_returndatasize, shiftedSrcOffset)
        }
    
        if len {
            returndatacopy(dstOffset, shiftedSrcOffset, len)
        }
    
        copiedLen := len
    } 
}

// Returns the length of the EVM bytecode.
function fetchDeployedEvmCodeLen(addr) -> codeLen {
    let codeHash := getRawCodeHash(addr)
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

function getMax(a, b) -> max {
    max := b
    if gt(a, b) {
        max := a
    }
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

function pushStackItemWithoutCheck(sp, item, oldStackHead) -> newSp, stackHead {
    mstore(sp, oldStackHead)
    stackHead := item
    newSp := add(sp, 0x20)
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

function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
    // function warmAccount(address account)
    // non-standard selector 0x00
    // addr is packed in the same word with selector
    mstore(0, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 32)

    if returndatasize() {
        isWarm := true
    }
}

function isSlotWarm(key) -> isWarm {
    // non-standard selector 0x01
    mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
    mstore(1, key)
    // should be call since we use TSTORE in gas manager
    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 33, 0, 0)

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
        returndatacopy(0, 0, 32)
        originalValue := mload(0)
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
    // function consumeEvmFrame() external returns (uint256 passGas, uint256 auxDataRes)
    // non-standard selector 0x04
    mstore(0, 0x0400000000000000000000000000000000000000000000000000000000000000)
    mstore(1, caller())

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 33)

    let _returndatasize := returndatasize()
    if _returndatasize {
        callerEVM := true

        returndatacopy(0, 0, 32)
        passGas := mload(0)
        
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
        let precompileCost := getGasForPrecompiles(addr, argsSize)
        switch precompileCost
        case 0 {
            // Not a precompile
            switch eq(1, shr(248, rawCodeHash))
            case 0 {
                // Empty contract or EVM contract being constructed
                success := delegatecall(gas(), addr, argsOffset, argsSize, retOffset, retSize)
                _saveReturndataAfterZkEVMCall()
            }
            default {
                // We forbid delegatecalls to EraVM native contracts
                _eraseReturndataPointer()
            }
        } 
        default {
            // Precompile. Simlate using staticcall, since EraVM behavior differs here
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
    addr := and(rawAddr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkMemIsAccessible(argsOffset, argsSize)
    checkMemIsAccessible(retOffset, retSize)

    gasUsed := 100 // warm address access cost
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        gasUsed := 2600 // cold address access cost
    }

    // memory_expansion_cost
    gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
}

function _genericCall(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
    switch isHashOfConstructedEvmContract(getRawCodeHash(addr))
    case 0 {
        // zkEVM native call
        let precompileCost := getGasForPrecompiles(addr, argsSize)
        switch precompileCost
        case 0 {
            // just smart contract
            success, frameGasLeft := callZkVmNative(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic)
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
    let zkVmGasToPass := gas() // pass all remaining gas, precompiles should not call any contracts
    if lt(gasToPass, precompileCost) {
        zkVmGasToPass := 0  // in EVM precompile should revert consuming all gas in that case
        precompileCost := gasToPass // just in case
    }

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

// Call native ZkVm contract from EVM context
function callZkVmNative(addr, evmGasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
    let zkEvmGasToPass := mul(evmGasToPass, GAS_DIVISOR()) // convert EVM gas -> ZkVM gas

    if gt(zkEvmGasToPass, UINT32_MAX()) { // just in case
        zkEvmGasToPass := UINT32_MAX()
    }

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
        zkEvmGasUsed := zkEvmGasToPass // should never happen
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
function getGasForPrecompiles(addr, argsSize) -> gasToCharge {
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
            // We do not support modexp
            gasToCharge := 0
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

function _saveReturndataAfterZkEVMCall() {
    loadReturndataIntoActivePtr()
    mstore(LAST_RETURNDATA_SIZE_OFFSET(), returndatasize())
}

function _saveReturndataAfterEVMCall(_outputOffset, _outputLen) -> _gasLeft {
    let rtsz := returndatasize()
    loadReturndataIntoActivePtr()

    // if (rtsz > 31)
    switch gt(rtsz, 31)
        case 0 {
            // Unexpected return data.
            // Most likely out-of-ergs or unexpected error in the emulator or system contracts
            abortEvmEnvironment()
        }
        default {
            returndatacopy(0, 0, 32)
            _gasLeft := mload(0)

            // We copy as much returndata as possible without going over the 
            // returndata size.
            switch lt(sub(rtsz, 32), _outputLen)
                case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }

            mstore(LAST_RETURNDATA_SIZE_OFFSET(), sub(rtsz, 32))

            // Skip the returnData
            ptrAddIntoActive(32)
        }
}

function _eraseReturndataPointer() {
    let activePtrSize := getActivePtrDataSize()
    ptrShrinkIntoActive(and(activePtrSize, 0xFFFFFFFF))// uint32(activePtrSize)
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
    checkMemIsAccessible(offset, size)

    // EIP-3860
    if gt(size, MAX_POSSIBLE_INIT_BYTECODE_LEN()) {
        panic()
    }

    // dynamicGas = init_code_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // + hash_cost, if isCreate2
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size, EIP-3860
    // code_deposit_cost = 200 * deployed_code_size, (charged inside call)
    let minimum_word_size := div(add(size, 31), 32) // rounding up
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

    let bytecodeHash := 0
    if isCreate2 {
        bytecodeHash := keccak256(offset, size)
    }

    // we want to calculate the address of new contract, and if it is deployable (no collision),
    // we need to increment deploy nonce.

    // selector: function precreateEvmAccountFromEmulator(bytes32 salt, bytes32 evmBytecodeHash)
    mstore(0, 0xf81dae8600000000000000000000000000000000000000000000000000000000)
    mstore(4, salt)
    mstore(36, bytecodeHash)
    let precreateResult := performSystemCallRevertable(DEPLOYER_SYSTEM_CONTRACT(), 68)

    if iszero(precreateResult) {
        // Collision, nonce overflow or EVM not allowed.
        // This is *internal* panic, consuming all passed gas.
        // Note: we should not consume all gas if nonce overflowed, but this should not happen in reality anyway
        evmGasLeft := chargeGas(evmGasLeftOld, gasForTheCall)
    }

    if precreateResult {
        returndatacopy(0, 0, 32)
        addr := mload(0)
    
        pop($llvm_AlwaysInline_llvm$_warmAddress(addr)) // will stay warm even if constructor reverts
        // so even if constructor reverts, nonce stays incremented and addr stays warm
    
        // verification of the correctness of the deployed bytecode and payment of gas for its storage will occur in the frame of the new contract
        pushEvmFrame(gasForTheCall, false)

        // move needed memory slots to the scratch space
        mstore(mul(10, 32), mload(sub(offset, 0x80))
        mstore(mul(11, 32), mload(sub(offset, 0x60))
        mstore(mul(12, 32), mload(sub(offset, 0x40))
        mstore(mul(13, 32), mload(sub(offset, 0x20))
    
        // selector: function createEvmFromEmulator(address newAddress, bytes calldata _initCode)
        mstore(sub(offset, 0x80), 0xe43cec64)
        mstore(sub(offset, 0x60), addr)
        mstore(sub(offset, 0x40), 0x40) // Where the arg starts (third word)
        mstore(sub(offset, 0x20), size) // Length of the init code
        
        let result := performSystemCallForCreate(value, sub(offset, 0x64), add(size, 0x64))

        // move memory slots back
        mstore(sub(offset, 0x80), mload(mul(10, 32))
        mstore(sub(offset, 0x60), mload(mul(11, 32))
        mstore(sub(offset, 0x40), mload(mul(12, 32))
        mstore(sub(offset, 0x20), mload(mul(13, 32))
    
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
    loadReturndataIntoActivePtr()

    if lt(returndatasize(), 64) {
        // unexpected return data after constructor succeeded, should never happen.
        abortEvmEnvironment()
    }

    // ContractDeployer returns (uint256 gasLeft, address createdContract)
    returndatacopy(0, 0, 64)
    gasLeft := mload(0)
    addr := mload(32)

    _eraseReturndataPointer()
}

////////////////////////////////////////////////////////////////
//               EXTCODECOPY FUNCTIONALITY
////////////////////////////////////////////////////////////////

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