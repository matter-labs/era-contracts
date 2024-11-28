// stack pointer - index to first stack element; empty stack = -1
let sp := sub(STACK_OFFSET(), 32)
// instruction pointer - index to next instruction. Not called pc because it's an
// actual yul/evm instruction.
let ip := BYTECODE_OFFSET()
let stackHead

let bytecodeEndOffset := add(BYTECODE_OFFSET(), mload(BYTECODE_LEN_OFFSET()))

for { } true { } {
    let opcode := readIP(ip, bytecodeEndOffset)

    switch opcode
    case 0x00 { // OP_STOP
        break
    }
    case 0x01 { // OP_ADD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        popStackCheck(sp, 2)
        let a
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := add(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x02 { // OP_MUL
        evmGasLeft := chargeGas(evmGasLeft, 5)

        popStackCheck(sp, 2)
        let a
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := mul(a, stackHead)
        ip := add(ip, 1)
    }
    case 0x03 { // OP_SUB
        evmGasLeft := chargeGas(evmGasLeft, 3)

        popStackCheck(sp, 2)
        let a
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := sub(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x04 { // OP_DIV
        evmGasLeft := chargeGas(evmGasLeft, 5)

        popStackCheck(sp, 2)
        let a
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := div(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x05 { // OP_SDIV
        evmGasLeft := chargeGas(evmGasLeft, 5)

        popStackCheck(sp, 2)
        let a
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := sdiv(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x06 { // OP_MOD
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a
        popStackCheck(sp, 2)
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := mod(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x07 { // OP_SMOD
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a
        popStackCheck(sp, 2)
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        stackHead := smod(a, stackHead)

        ip := add(ip, 1)
    }
    case 0x08 { // OP_ADDMOD
        evmGasLeft := chargeGas(evmGasLeft, 8)

        let a, b, N

        popStackCheck(sp, 3)
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        b, sp, N := popStackItemWithoutCheck(sp, stackHead)
        stackHead := addmod(a, b, N)

        ip := add(ip, 1)
    }
    case 0x09 { // OP_MULMOD
        evmGasLeft := chargeGas(evmGasLeft, 8)

        let a, b, N

        popStackCheck(sp, 3)
        a, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        b, sp, N := popStackItemWithoutCheck(sp, stackHead)

        stackHead := mulmod(a, b, N)
        ip := add(ip, 1)
    }
    case 0x0A { // OP_EXP
        evmGasLeft := chargeGas(evmGasLeft, 10)

        let a, exponent

        popStackCheck(sp, 2)
        a, sp, exponent := popStackItemWithoutCheck(sp, stackHead)

        let to_charge := 0
        let exponentCopy := exponent
        for {} gt(exponentCopy, 0) {} { // while exponent > 0
            to_charge := add(to_charge, 50)
            exponentCopy := shr(8, exponentCopy)
        } 
        evmGasLeft := chargeGas(evmGasLeft, to_charge)

        stackHead := exp(a, exponent)

        ip := add(ip, 1)
    }
    case 0x0B { // OP_SIGNEXTEND
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let b, x

        popStackCheck(sp, 2)
        b, sp, x := popStackItemWithoutCheck(sp, stackHead)
        stackHead := signextend(b, x)

        ip := add(ip, 1)
    }
    case 0x10 { // OP_LT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := lt(a, b)

        ip := add(ip, 1)
    }
    case 0x11 { // OP_GT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead:= gt(a, b)

        ip := add(ip, 1)
    }
    case 0x12 { // OP_SLT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := slt(a, b)

        ip := add(ip, 1)
    }
    case 0x13 { // OP_SGT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b
        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := sgt(a, b)

        ip := add(ip, 1)
    }
    case 0x14 { // OP_EQ
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b
        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := eq(a, b)

        ip := add(ip, 1)
    }
    case 0x15 { // OP_ISZERO
        evmGasLeft := chargeGas(evmGasLeft, 3)

        stackHead := iszero(accessStackHead(sp, stackHead))

        ip := add(ip, 1)
    }
    case 0x16 { // OP_AND
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b
        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := and(a,b)

        ip := add(ip, 1)
    }
    case 0x17 { // OP_OR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b
        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := or(a,b)

        ip := add(ip, 1)
    }
    case 0x18 { // OP_XOR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b
        popStackCheck(sp, 2)
        a, sp, b := popStackItemWithoutCheck(sp, stackHead)
        stackHead := xor(a, b)

        ip := add(ip, 1)
    }
    case 0x19 { // OP_NOT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        stackHead := not(accessStackHead(sp, stackHead))

        ip := add(ip, 1)
    }
    case 0x1A { // OP_BYTE
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let i, x
        popStackCheck(sp, 2)
        i, sp, x := popStackItemWithoutCheck(sp, stackHead)
        stackHead := byte(i, x)

        ip := add(ip, 1)
    }
    case 0x1B { // OP_SHL
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value
        popStackCheck(sp, 2)
        shift, sp, value := popStackItemWithoutCheck(sp, stackHead)
        stackHead := shl(shift, value)

        ip := add(ip, 1)
    }
    case 0x1C { // OP_SHR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value
        popStackCheck(sp, 2)
        shift, sp, value := popStackItemWithoutCheck(sp, stackHead)
        stackHead := shr(shift, value)

        ip := add(ip, 1)
    }
    case 0x1D { // OP_SAR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value
        popStackCheck(sp, 2)
        shift, sp, value := popStackItemWithoutCheck(sp, stackHead)
        stackHead := sar(shift, value)

        ip := add(ip, 1)
    }
    case 0x20 { // OP_KECCAK256
        evmGasLeft := chargeGas(evmGasLeft, 30)

        let offset, size

        popStackCheck(sp, 2)
        offset, sp, size := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // When an offset is first accessed (either read or write), memory may trigger 
        // an expansion, which costs gas.
        // dynamicGas = 6 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let dynamicGas := add(mul(6, shr(5, add(size, 31))), expandMemory(offset, size))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        stackHead := keccak256(add(MEM_OFFSET(), offset), size)

        ip := add(ip, 1)
    }
    case 0x30 { // OP_ADDRESS
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp, stackHead := pushStackItem(sp, address(), stackHead)
        ip := add(ip, 1)
    }
    case 0x31 { // OP_BALANCE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr := accessStackHead(sp, stackHead)
        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500)
        }

        stackHead := balance(addr)

        ip := add(ip, 1)
    }
    case 0x32 { // OP_ORIGIN
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _origin := mload(ORIGIN_CACHE_OFFSET())
        if iszero(_origin) {
            _origin := cached(ORIGIN_CACHE_OFFSET(), origin())
        }
        sp, stackHead := pushStackItem(sp, _origin, stackHead)
        ip := add(ip, 1)
    }
    case 0x33 { // OP_CALLER
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp, stackHead := pushStackItem(sp, caller(), stackHead)
        ip := add(ip, 1)
    }
    case 0x34 { // OP_CALLVALUE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp, stackHead := pushStackItem(sp, callvalue(), stackHead)
        ip := add(ip, 1)
    }
    case 0x35 { // OP_CALLDATALOAD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let calldataOffset := accessStackHead(sp, stackHead)

        stackHead := 0
        // EraVM will revert if offset + length overflows uint32
        if lt(calldataOffset, UINT32_MAX()) {
            stackHead := calldataload(calldataOffset)
        }

        ip := add(ip, 1)
    }
    case 0x36 { // OP_CALLDATASIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp, stackHead := pushStackItem(sp, calldatasize(), stackHead)
        ip := add(ip, 1)
    }
    case 0x37 { // OP_CALLDATACOPY
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let dstOffset, sourceOffset, len

        popStackCheck(sp, 3)
        dstOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        sourceOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        len, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(dstOffset, len)

        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(dstOffset, len))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        dstOffset := add(dstOffset, MEM_OFFSET())

        // EraVM will revert if offset + length overflows uint32
        if gt(sourceOffset, UINT32_MAX()) {
            sourceOffset := UINT32_MAX()
        }

        // Check bytecode out-of-bounds access
        let truncatedLen := len
        if gt(add(sourceOffset, len), UINT32_MAX()) {
            truncatedLen := sub(UINT32_MAX(), sourceOffset) // truncate
            $llvm_AlwaysInline_llvm$_memsetToZero(add(dstOffset, truncatedLen), sub(len, truncatedLen)) // pad with zeroes any out-of-bounds
        }

        if truncatedLen {
            calldatacopy(dstOffset, sourceOffset, truncatedLen)
        }

        ip := add(ip, 1)
        
    }
    case 0x38 { // OP_CODESIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let bytecodeLen := mload(BYTECODE_LEN_OFFSET())
        sp, stackHead := pushStackItem(sp, bytecodeLen, stackHead)
        ip := add(ip, 1)
    }
    case 0x39 { // OP_CODECOPY
    
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let dstOffset, sourceOffset, len

        popStackCheck(sp, 3)
        dstOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        sourceOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        len, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(dstOffset, len)

        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(dstOffset, len))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        dstOffset := add(dstOffset, MEM_OFFSET())

        if gt(sourceOffset, MAX_UINT64()) {
            sourceOffset := MAX_UINT64()
        } 

        sourceOffset := add(sourceOffset, BYTECODE_OFFSET())

        if gt(sourceOffset, MEM_LEN_OFFSET()) {
            sourceOffset := MEM_LEN_OFFSET()
        }

        // Check bytecode out-of-bounds access
        let truncatedLen := len
        if gt(add(sourceOffset, len), MEM_LEN_OFFSET()) {
            truncatedLen := sub(MEM_LEN_OFFSET(), sourceOffset) // truncate
            $llvm_AlwaysInline_llvm$_memsetToZero(add(dstOffset, truncatedLen), sub(len, truncatedLen)) // pad with zeroes any out-of-bounds
        }

        if truncatedLen {
            $llvm_AlwaysInline_llvm$_memcpy(dstOffset, sourceOffset, truncatedLen)
        }
        
        ip := add(ip, 1)
    }
    case 0x3A { // OP_GASPRICE
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _gasprice := mload(GASPRICE_CACHE_OFFSET())
        if iszero(_gasprice) {
            _gasprice := cached(GASPRICE_CACHE_OFFSET(), gasprice())
        }
        sp, stackHead := pushStackItem(sp, _gasprice, stackHead)
        ip := add(ip, 1)
    }
    case 0x3B { // OP_EXTCODESIZE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr := accessStackHead(sp, stackHead)

        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500)
        }

        switch isEvmContract(addr) 
            case 0  { stackHead := extcodesize(addr) }
            default { stackHead := fetchDeployedEvmCodeLen(addr) }

        ip := add(ip, 1)
    }
    case 0x3C { // OP_EXTCODECOPY
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr, dstOffset, srcOffset, len
        popStackCheck(sp, 4)
        addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        dstOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        srcOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        len, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    
        checkMemIsAccessible(dstOffset, len)
    
        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
        // minimum_word_size = (size + 31) / 32
        let dynamicGas := add(
            mul(3, shr(5, add(len, 31))),
            expandMemory(dstOffset, len)
        )
        
        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
            dynamicGas := add(dynamicGas, 2500)
        }

        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        if gt(srcOffset, MAX_UINT64()) {
            srcOffset := MAX_UINT64()
        } 
        
        if gt(len, 0) {
            let copiedLen
            if getRawCodeHash(addr) {
                 // Gets the code from the addr
                 copiedLen := fetchDeployedCode(addr, add(dstOffset, MEM_OFFSET()), srcOffset, len)
            }

            if lt(copiedLen, len) {
                $llvm_AlwaysInline_llvm$_memsetToZero(add(dstOffset, copiedLen), sub(len, copiedLen))
            }
        }
    
        ip := add(ip, 1)
    }
    case 0x3D { // OP_RETURNDATASIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let rdz := mload(LAST_RETURNDATA_SIZE_OFFSET())
        sp, stackHead := pushStackItem(sp, rdz, stackHead)
        ip := add(ip, 1)
    }
    case 0x3E { // OP_RETURNDATACOPY
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let dstOffset, sourceOffset, len
        popStackCheck(sp, 3)
        dstOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        sourceOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        len, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(dstOffset, len)

        // minimum_word_size = (size + 31) / 32
        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(dstOffset, len))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        checkOverflow(sourceOffset, len)

        // Check returndata out-of-bounds error
        if gt(add(sourceOffset, len), mload(LAST_RETURNDATA_SIZE_OFFSET())) {
            panic()
        }

        copyActivePtrData(add(MEM_OFFSET(), dstOffset), sourceOffset, len)
        ip := add(ip, 1)
    }
    case 0x3F { // OP_EXTCODEHASH
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr := accessStackHead(sp, stackHead)
        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500) 
        }

        ip := add(ip, 1)
        if iszero(addr) {
            stackHead := 0
            continue
        }

        switch isEvmContract(addr)
        case 0 {
            stackHead := extcodehash(addr)
        }
        default {
            stackHead := getEvmExtcodehash(addr)
        }
        
    }
    case 0x40 { // OP_BLOCKHASH
        evmGasLeft := chargeGas(evmGasLeft, 20)

        stackHead := blockhash(accessStackHead(sp, stackHead))

        ip := add(ip, 1)
    }
    case 0x41 { // OP_COINBASE
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _coinbase := mload(COINBASE_CACHE_OFFSET())
        if iszero(_coinbase) {
            _coinbase := cached(COINBASE_CACHE_OFFSET(), coinbase())
        }
        sp, stackHead := pushStackItem(sp, _coinbase, stackHead)
        ip := add(ip, 1)
    }
    case 0x42 { // OP_TIMESTAMP
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _blocktimestamp := mload(BLOCKTIMESTAMP_CACHE_OFFSET())
        if iszero(_blocktimestamp) {
            _blocktimestamp := cached(BLOCKTIMESTAMP_CACHE_OFFSET(), timestamp())
        }
        sp, stackHead := pushStackItem(sp, _blocktimestamp, stackHead)
        ip := add(ip, 1)
    }
    case 0x43 { // OP_NUMBER
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _blocknumber := mload(BLOCKNUMBER_CACHE_OFFSET())
        if iszero(_blocknumber) {
            _blocknumber := cached(BLOCKNUMBER_CACHE_OFFSET(), number())
        }
        sp, stackHead := pushStackItem(sp, _blocknumber, stackHead)
        ip := add(ip, 1)
    }
    case 0x44 { // OP_PREVRANDAO
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _prevrandao := mload(PREVRANDAO_CACHE_OFFSET())
        if iszero(_prevrandao) {
            _prevrandao := cached(PREVRANDAO_CACHE_OFFSET(), prevrandao())
        }
        sp, stackHead := pushStackItem(sp, _prevrandao, stackHead)
        ip := add(ip, 1)
    }
    case 0x45 { // OP_GASLIMIT
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _gasLimit := mload(GASLIMIT_CACHE_OFFSET())
        if iszero(_gasLimit) {
            _gasLimit := cached(GASLIMIT_CACHE_OFFSET(), gaslimit())
        }
        sp, stackHead := pushStackItem(sp, _gasLimit, stackHead)
        ip := add(ip, 1)
    }
    case 0x46 { // OP_CHAINID
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _chainId := mload(CHAINID_CACHE_OFFSET())
        if iszero(_chainId) {
            _chainId := cached(CHAINID_CACHE_OFFSET(), chainid())
        }
        sp, stackHead := pushStackItem(sp, _chainId, stackHead)
        ip := add(ip, 1)
    }
    case 0x47 { // OP_SELFBALANCE
        evmGasLeft := chargeGas(evmGasLeft, 5)
        sp, stackHead := pushStackItem(sp, selfbalance(), stackHead)
        ip := add(ip, 1)
    }
    case 0x48 { // OP_BASEFEE
        evmGasLeft := chargeGas(evmGasLeft, 2)
        let _baseFee := mload(BASEFEE_CACHE_OFFSET())
        if iszero(_baseFee) {
            _baseFee := cached(BASEFEE_CACHE_OFFSET(), basefee())
        }
        sp, stackHead := pushStackItem(sp, _baseFee, stackHead)
        ip := add(ip, 1)
    }
    case 0x50 { // OP_POP
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let _y

        _y, sp, stackHead := popStackItem(sp, stackHead)
        ip := add(ip, 1)
    }
    case 0x51 { // OP_MLOAD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset := accessStackHead(sp, stackHead)

        checkMemIsAccessible(offset, 32)
        let expansionGas := expandMemory(offset, 32)
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        stackHead := mload(add(MEM_OFFSET(), offset))

        ip := add(ip, 1)
    }
    case 0x52 { // OP_MSTORE
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset, value

        popStackCheck(sp, 2)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, 32)
        let expansionGas := expandMemory(offset, 32)
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        mstore(add(MEM_OFFSET(), offset), value)
        ip := add(ip, 1)
    }
    case 0x53 { // OP_MSTORE8
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset, value

        popStackCheck(sp, 2)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, 1)
        let expansionGas := expandMemory(offset, 1)
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        mstore8(add(MEM_OFFSET(), offset), value)
        ip := add(ip, 1)
    }
    case 0x54 { // OP_SLOAD
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let key := accessStackHead(sp, stackHead)
        let wasWarm := isSlotWarm(key)

        if iszero(wasWarm) {
            evmGasLeft := chargeGas(evmGasLeft, 2000)
        }

        let value := sload(key)

        if iszero(wasWarm) {
            let _wasW, _orgV := warmSlot(key, value)
        }

        stackHead := value
        ip := add(ip, 1)
    }
    case 0x55 { // OP_SSTORE
        if isStatic {
            panic()
        }

        if lt(evmGasLeft, 2301) { // if <= 2300
            panic()
        }

        let key, value

        popStackCheck(sp, 2)
        key, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        ip := add(ip, 1)

        let dynamicGas := 100
        // Here it is okay to read before we charge since we known anyway that
        // the context has enough funds to compensate at least for the read.
        let currentValue := sload(key)
        let wasWarm, originalValue := warmSlot(key, currentValue)

        if iszero(wasWarm) {
            dynamicGas := add(dynamicGas, 2100)
        }

        if eq(value, currentValue) { // no-op
            evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            continue
        }

        if eq(originalValue, currentValue) {
            switch originalValue
            case 0 {
                dynamicGas := add(dynamicGas, 19900)
            }
            default {
                dynamicGas := add(dynamicGas, 2800)
            }
        }

        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
        sstore(key, value)
    }
    // NOTE: We don't currently do full jumpdest validation
    // (i.e. validating a jumpdest isn't in PUSH data)
    case 0x56 { // OP_JUMP
        evmGasLeft := chargeGas(evmGasLeft, 9) // charge for OP_JUMP (8) and OP_JUMPDEST (1) immediately

        let counter
        counter, sp, stackHead := popStackItem(sp, stackHead)

        ip := add(BYTECODE_OFFSET(), counter)

        // Check next opcode is JUMPDEST
        let nextOpcode := readIP(ip, bytecodeEndOffset)
        if iszero(eq(nextOpcode, 0x5B)) {
            panic()
        }

        // execute JUMPDEST immediately
        ip := add(ip, 1)
    }
    case 0x57 { // OP_JUMPI
        evmGasLeft := chargeGas(evmGasLeft, 10)

        let counter, b

        popStackCheck(sp, 2)
        counter, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        b, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        if iszero(b) {
            ip := add(ip, 1)
            continue
        }

        ip := add(BYTECODE_OFFSET(), counter)

        // Check next opcode is JUMPDEST
        let nextOpcode := readIP(ip, bytecodeEndOffset)
        if iszero(eq(nextOpcode, 0x5B)) {
            panic()
        }

        // execute JUMPDEST immediately
        evmGasLeft := chargeGas(evmGasLeft, 1)
        ip := add(ip, 1)
    }
    case 0x58 { // OP_PC
        evmGasLeft := chargeGas(evmGasLeft, 2)
        ip := add(ip, 1)

        // PC = ip - 32 (bytecode size) - 1 (current instruction)
        sp, stackHead := pushStackItem(sp, sub(sub(ip, BYTECODE_LEN_OFFSET()), 33), stackHead)
    }
    case 0x59 { // OP_MSIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let size

        size := mload(MEM_LEN_OFFSET())
        size := shl(5, size)
        sp, stackHead := pushStackItem(sp, size, stackHead)
        ip := add(ip, 1)
    }
    case 0x5A { // OP_GAS
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp, stackHead := pushStackItem(sp, evmGasLeft, stackHead)
        ip := add(ip, 1)
    }
    case 0x5B { // OP_JUMPDEST
        evmGasLeft := chargeGas(evmGasLeft, 1)
        ip := add(ip, 1)
    }
    case 0x5C { // OP_TLOAD
        evmGasLeft := chargeGas(evmGasLeft, 100)

        stackHead := tload(accessStackHead(sp, stackHead))
        ip := add(ip, 1)
    }
    case 0x5D { // OP_TSTORE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        if isStatic {
            panic()
        }

        let key, value
        popStackCheck(sp, 2)
        key, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        tstore(key, value)
        ip := add(ip, 1)
    }
    case 0x5E { // OP_MCOPY
        let destOffset, offset, size
        popStackCheck(sp, 3)
        destOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)
        checkMemIsAccessible(destOffset, size)

        // dynamic_gas = 3 * words_copied + memory_expansion_cost
        let dynamicGas := expandMemory2(offset, size, destOffset, size)
        let wordsCopied := div(add(size, 31), 32) // div rounding up
        dynamicGas := add(dynamicGas, mul(3, wordsCopied))

        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        mcopy(add(destOffset, MEM_OFFSET()), add(offset, MEM_OFFSET()), size)
        ip := add(ip, 1)
    }
    case 0x5F { // OP_PUSH0
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let value := 0

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 1)
    }
    case 0x60 { // OP_PUSH1
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 1)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 1)
    }
    case 0x61 { // OP_PUSH2
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 2)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 2)
    }     
    case 0x62 { // OP_PUSH3
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 3)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 3)
    }
    case 0x63 { // OP_PUSH4
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 4)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 4)
    }
    case 0x64 { // OP_PUSH5
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 5)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 5)
    }
    case 0x65 { // OP_PUSH6
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 6)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 6)
    }
    case 0x66 { // OP_PUSH7
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 7)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 7)
    }
    case 0x67 { // OP_PUSH8
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 8)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 8)
    }
    case 0x68 { // OP_PUSH9
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 9)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 9)
    }
    case 0x69 { // OP_PUSH10
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 10)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 10)
    }
    case 0x6A { // OP_PUSH11
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 11)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 11)
    }
    case 0x6B { // OP_PUSH12
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 12)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 12)
    }
    case 0x6C { // OP_PUSH13
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 13)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 13)
    }
    case 0x6D { // OP_PUSH14
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 14)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 14)
    }
    case 0x6E { // OP_PUSH15
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 15)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 15)
    }
    case 0x6F { // OP_PUSH16
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 16)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 16)
    }
    case 0x70 { // OP_PUSH17
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 17)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 17)
    }
    case 0x71 { // OP_PUSH18
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 18)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 18)
    }
    case 0x72 { // OP_PUSH19
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 19)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 19)
    }
    case 0x73 { // OP_PUSH20
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 20)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 20)
    }
    case 0x74 { // OP_PUSH21
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 21)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 21)
    }
    case 0x75 { // OP_PUSH22
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 22)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 22)
    }
    case 0x76 { // OP_PUSH23
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 23)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 23)
    }
    case 0x77 { // OP_PUSH24
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 24)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 24)
    }
    case 0x78 { // OP_PUSH25
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 25)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 25)
    }
    case 0x79 { // OP_PUSH26
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 26)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 26)
    }
    case 0x7A { // OP_PUSH27
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 27)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 27)
    }
    case 0x7B { // OP_PUSH28
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 28)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 28)
    }
    case 0x7C { // OP_PUSH29
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 29)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 29)
    }
    case 0x7D { // OP_PUSH30
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 30)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 30)
    }
    case 0x7E { // OP_PUSH31
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 31)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 31)
    }
    case 0x7F { // OP_PUSH32
        evmGasLeft := chargeGas(evmGasLeft, 3)

        ip := add(ip, 1)
        let value := readBytes(ip, 32)

        sp, stackHead := pushStackItem(sp, value, stackHead)
        ip := add(ip, 32)
    }
    case 0x80 { // OP_DUP1 
        evmGasLeft := chargeGas(evmGasLeft, 3)
        sp, stackHead := pushStackItem(sp, stackHead, stackHead)
        ip := add(ip, 1)
    }
    case 0x81 { // OP_DUP2
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 2, stackHead)
        ip := add(ip, 1)
    }
    case 0x82 { // OP_DUP3
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 3, stackHead)
        ip := add(ip, 1)
    }
    case 0x83 { // OP_DUP4    
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 4, stackHead)
        ip := add(ip, 1)
    }
    case 0x84 { // OP_DUP5
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 5, stackHead)
        ip := add(ip, 1)
    }
    case 0x85 { // OP_DUP6
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 6, stackHead)
        ip := add(ip, 1)
    }
    case 0x86 { // OP_DUP7    
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 7, stackHead)
        ip := add(ip, 1)
    }
    case 0x87 { // OP_DUP8
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 8, stackHead)
        ip := add(ip, 1)
    }
    case 0x88 { // OP_DUP9
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 9, stackHead)
        ip := add(ip, 1)
    }
    case 0x89 { // OP_DUP10   
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 10, stackHead)
        ip := add(ip, 1)
    }
    case 0x8A { // OP_DUP11
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 11, stackHead)
        ip := add(ip, 1)
    }
    case 0x8B { // OP_DUP12
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 12, stackHead)
        ip := add(ip, 1)
    }
    case 0x8C { // OP_DUP13
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 13, stackHead)
        ip := add(ip, 1)
    }
    case 0x8D { // OP_DUP14
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 14, stackHead)
        ip := add(ip, 1)
    }
    case 0x8E { // OP_DUP15
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 15, stackHead)
        ip := add(ip, 1)
    }
    case 0x8F { // OP_DUP16
        sp, evmGasLeft, stackHead := dupStackItem(sp, evmGasLeft, 16, stackHead)
        ip := add(ip, 1)
    }
    case 0x90 { // OP_SWAP1 
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 1, stackHead)
        ip := add(ip, 1)
    }
    case 0x91 { // OP_SWAP2
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 2, stackHead)
        ip := add(ip, 1)
    }
    case 0x92 { // OP_SWAP3
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 3, stackHead)
        ip := add(ip, 1)
    }
    case 0x93 { // OP_SWAP4    
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 4, stackHead)
        ip := add(ip, 1)
    }
    case 0x94 { // OP_SWAP5
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 5, stackHead)
        ip := add(ip, 1)
    }
    case 0x95 { // OP_SWAP6
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 6, stackHead)
        ip := add(ip, 1)
    }
    case 0x96 { // OP_SWAP7    
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 7, stackHead)
        ip := add(ip, 1)
    }
    case 0x97 { // OP_SWAP8
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 8, stackHead)
        ip := add(ip, 1)
    }
    case 0x98 { // OP_SWAP9
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 9, stackHead)
        ip := add(ip, 1)
    }
    case 0x99 { // OP_SWAP10   
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 10, stackHead)
        ip := add(ip, 1)
    }
    case 0x9A { // OP_SWAP11
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 11, stackHead)
        ip := add(ip, 1)
    }
    case 0x9B { // OP_SWAP12
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 12, stackHead)
        ip := add(ip, 1)
    }
    case 0x9C { // OP_SWAP13
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 13, stackHead)
        ip := add(ip, 1)
    }
    case 0x9D { // OP_SWAP14
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 14, stackHead)
        ip := add(ip, 1)
    }
    case 0x9E { // OP_SWAP15
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 15, stackHead)
        ip := add(ip, 1)
    }
    case 0x9F { // OP_SWAP16
        evmGasLeft, stackHead := swapStackItem(sp, evmGasLeft, 16, stackHead)
        ip := add(ip, 1)
    }
    case 0xA0 { // OP_LOG0
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            panic()
        }

        let offset, size
        popStackCheck(sp, 2)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(offset, size))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        log0(add(offset, MEM_OFFSET()), size)
        ip := add(ip, 1)
    }
    case 0xA1 { // OP_LOG1
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            panic()
        }

        let offset, size
        popStackCheck(sp, 3)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(offset, size))
        dynamicGas := add(dynamicGas, 375)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {   
            let topic1
            topic1, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            log1(add(offset, MEM_OFFSET()), size, topic1)
        }
        ip := add(ip, 1)
    }
    case 0xA2 { // OP_LOG2
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            panic()
        }

        let offset, size
        popStackCheck(sp, 4)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(offset, size))
        dynamicGas := add(dynamicGas, 750)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {
            let topic1, topic2
            topic1, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic2, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            log2(add(offset, MEM_OFFSET()), size, topic1, topic2)
        }
        ip := add(ip, 1)
    }
    case 0xA3 { // OP_LOG3
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            panic()
        }

        let offset, size
        popStackCheck(sp, 5)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(offset, size))
        dynamicGas := add(dynamicGas, 1125)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {
            let topic1, topic2, topic3
            topic1, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic2, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic3, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            log3(add(offset, MEM_OFFSET()), size, topic1, topic2, topic3)
        }     
        ip := add(ip, 1)
    }
    case 0xA4 { // OP_LOG4
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            panic()
        }

        let offset, size
        popStackCheck(sp, 6)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(offset, size))
        dynamicGas := add(dynamicGas, 1500)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {
            let topic1, topic2, topic3, topic4
            topic1, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic2, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic3, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            topic4, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            log4(add(offset, MEM_OFFSET()), size, topic1, topic2, topic3, topic4)
        }     
        ip := add(ip, 1)
    }
    case 0xF0 { // OP_CREATE
        evmGasLeft := chargeGas(evmGasLeft, 32000)

        if isStatic {
            panic()
        }

        evmGasLeft, sp, stackHead := performCreate(evmGasLeft, sp, stackHead)
        ip := add(ip, 1)
    }
    case 0xF1 { // OP_CALL
        // A function was implemented in order to avoid stack depth errors.
        switch isStatic
        case 0 {
            evmGasLeft, sp, stackHead := performCall(sp, evmGasLeft, stackHead)
        }
        default {
            evmGasLeft, sp, stackHead := performStaticCall(sp, evmGasLeft, stackHead)
        }
        ip := add(ip, 1)
    }
    case 0xF3 { // OP_RETURN
        let offset, size

        popStackCheck(sp, 2)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)

        evmGasLeft := chargeGas(evmGasLeft, expandMemory(offset, size))

        returnLen := size
        
        // Don't check overflow here since previous checks are enough to ensure this is safe
        returnOffset := add(MEM_OFFSET(), offset)
        break
    }
    case 0xF4 { // OP_DELEGATECALL
        evmGasLeft, sp, stackHead := performDelegateCall(sp, evmGasLeft, isStatic, stackHead)
        ip := add(ip, 1)
    }
    case 0xF5 { // OP_CREATE2
        evmGasLeft := chargeGas(evmGasLeft, 32000)

        if isStatic {
            panic()
        }

        evmGasLeft, sp, stackHead := performCreate2(evmGasLeft, sp, stackHead)
        ip := add(ip, 1)
    }
    case 0xFA { // OP_STATICCALL
        evmGasLeft, sp, stackHead := performStaticCall(sp, evmGasLeft, stackHead)
        ip := add(ip, 1)
    }
    case 0xFD { // OP_REVERT
        let offset,size

        popStackCheck(sp, 2)
        offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

        checkMemIsAccessible(offset, size)
        evmGasLeft := chargeGas(evmGasLeft, expandMemory(offset, size))

        // Don't check overflow here since previous checks are enough to ensure this is safe
        offset := add(offset, MEM_OFFSET())

        if eq(isCallerEVM, 1) {
            offset := sub(offset, 32)
            size := add(size, 32)
    
            // include gas
            mstore(offset, evmGasLeft)
        }

        revert(offset, size)
    }
    case 0xFE { // OP_INVALID
        evmGasLeft := 0
        revertWithGas(evmGasLeft)
    }
    // We explicitly add unused opcodes to optimize the jump table by compiler.
    <!-- @include EvmEmulatorLoopUnusedOpcodes.template.yul -->
    default {
        $llvm_NoInline_llvm$_panic()
    }
}
