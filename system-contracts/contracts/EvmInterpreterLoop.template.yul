// stack pointer - index to first stack element; empty stack = -1
let sp := sub(STACK_OFFSET(), 32)
// instruction pointer - index to next instruction. Not called pc because it's an
// actual yul/evm instruction.
let ip := add(BYTECODE_OFFSET(), 32)
let opcode

for { } true { } {
    opcode := readIP(ip)

    ip := add(ip, 1)

    switch opcode
    case 0x00 { // OP_STOP
        break
    }
    case 0x01 { // OP_ADD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, add(a, b))
    }
    case 0x02 { // OP_MUL
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, mul(a, b))
    }
    case 0x03 { // OP_SUB
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sub(a, b))
    }
    case 0x04 { // OP_DIV
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, div(a, b))
    }
    case 0x05 { // OP_SDIV
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sdiv(a, b))
    }
    case 0x06 { // OP_MOD
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, mod(a, b))
    }
    case 0x07 { // OP_SMOD
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, smod(a, b))
    }
    case 0x08 { // OP_ADDMOD
        evmGasLeft := chargeGas(evmGasLeft, 8)

        let a, b, N

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)
        N, sp := popStackItem(sp)

        sp := pushStackItem(sp, addmod(a, b, N))
    }
    case 0x09 { // OP_MULMOD
        evmGasLeft := chargeGas(evmGasLeft, 8)

        let a, b, N

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)
        N, sp := popStackItem(sp)

        sp := pushStackItem(sp, mulmod(a, b, N))
    }
    case 0x0A { // OP_EXP
        evmGasLeft := chargeGas(evmGasLeft, 10)

        let a, exponent

        a, sp := popStackItem(sp)
        exponent, sp := popStackItem(sp)

        sp := pushStackItem(sp, exp(a, exponent))

        if exponent {
            let expSizeByte := div(add(exponent, 256), 256) // TODO: Replace with shr(8, add(exponent, 256))
            evmGasLeft := chargeGas(evmGasLeft, mul(50, expSizeByte))
        }
    }
    case 0x0B { // OP_SIGNEXTEND
        evmGasLeft := chargeGas(evmGasLeft, 5)

        let b, x

        b, sp := popStackItem(sp)
        x, sp := popStackItem(sp)

        sp := pushStackItem(sp, signextend(b, x))
    }
    case 0x10 { // OP_LT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, lt(a, b))
    }
    case 0x11 { // OP_GT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, gt(a, b))
    }
    case 0x12 { // OP_SLT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, slt(a, b))
    }
    case 0x13 { // OP_SGT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sgt(a, b))
    }
    case 0x14 { // OP_EQ
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, eq(a, b))
    }
    case 0x15 { // OP_ISZERO
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a

        a, sp := popStackItem(sp)

        sp := pushStackItem(sp, iszero(a))
    }
    case 0x16 { // OP_AND
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, and(a,b))
    }
    case 0x17 { // OP_OR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, or(a,b))
    }
    case 0x18 { // OP_XOR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, xor(a, b))
    }
    case 0x19 { // OP_NOT
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let a

        a, sp := popStackItem(sp)

        sp := pushStackItem(sp, not(a))
    }
    case 0x1A { // OP_BYTE
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let i, x

        i, sp := popStackItem(sp)
        x, sp := popStackItem(sp)

        sp := pushStackItem(sp, byte(i, x))
    }
    case 0x1B { // OP_SHL
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, shl(shift, value))
    }
    case 0x1C { // OP_SHR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, shr(shift, value))
    }
    case 0x1D { // OP_SAR
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, sar(shift, value))
    }
    case 0x20 { // OP_KECCAK256
        evmGasLeft := chargeGas(evmGasLeft, 30)

        let offset, size

        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        let keccak := keccak256(add(MEM_OFFSET_INNER(), offset), size)

        // When an offset is first accessed (either read or write), memory may trigger 
        // an expansion, which costs gas.
        // dynamicGas = 6 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let minWordSize := shr(5, add(size, 31))
        let dynamicGas := add(mul(6, minWordSize), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        sp := pushStackItem(sp, keccak)
    }
    case 0x30 { // OP_ADDRESS
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, address())
    }
    case 0x31 { // OP_BALANCE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr

        addr, sp := popStackItem(sp)

        if iszero(warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500)
        }

        sp := pushStackItem(sp, balance(addr))
    }
    case 0x32 { // OP_ORIGIN
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, origin())
    }
    case 0x33 { // OP_CALLER
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, caller())
    }
    case 0x34 { // OP_CALLVALUE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, callvalue())
    }
    case 0x35 { // OP_CALLDATALOAD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let i

        i, sp := popStackItem(sp)

        sp := pushStackItem(sp, calldataload(i))
    }
    case 0x36 { // OP_CALLDATASIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, calldatasize())
    }
    case 0x37 { // OP_CALLDATACOPY
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let destOffset, offset, size

        destOffset, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, size), MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(destOffset, size), MEM_OFFSET_INNER()))

        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let minWordSize := shr(5, add(size, 31))
        let dynamicGas := add(mul(3, minWordSize), expandMemory(add(destOffset, size)))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        calldatacopy(add(destOffset, MEM_OFFSET_INNER()), offset, size)
    }
    case 0x38 { // OP_CODESIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let bytecodeLen := mload(BYTECODE_OFFSET())
        sp := pushStackItem(sp, bytecodeLen)
    }
    case 0x39 { // OP_CODECOPY
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let dst, offset, len

        dst, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        len, sp := popStackItem(sp)

        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let minWordSize := shr(5, add(len, 31))
        let dynamicGas := add(mul(3, minWordSize), expandMemory(add(dst, len)))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        dst := add(dst, MEM_OFFSET_INNER())
        offset := add(add(offset, BYTECODE_OFFSET()), 32)

        checkMemOverflow(add(dst, len))
        // Check bytecode overflow
        if gt(add(offset, len), sub(MEM_OFFSET(), 1)) {
            revert(0, 0)
        }

        for { let i := 0 } lt(i, len) { i := add(i, 1) } {
            mstore8(
                add(dst, i),
                shr(248, mload(add(offset, i)))
            )
        }
    }
    case 0x3A { // OP_GASPRICE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, gasprice())
    }
    case 0x3B { // OP_EXTCODESIZE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr
        addr, sp := popStackItem(sp)

        if iszero(warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500)
        }

        // TODO: check, the .sol uses extcodesize directly, but it doesnt seem to work
        // if a contract is created it works, but if the address is a zkSync's contract
        // what happens?
        switch _isEVM(addr) 
            case 0  { sp := pushStackItem(sp, extcodesize(addr)) }
            default { sp := pushStackItem(sp, _fetchDeployedCodeLen(addr)) }
    }
    case 0x3C { // OP_EXTCODECOPY
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr, dest, offset, len
        addr, sp := popStackItem(sp)
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

        // TODO: Check if Zeroing out the memory is necessary
        let _lastByte := add(dest, len)
        for {let i := dest} lt(i, _lastByte) { i := add(i, 1) } {
            mstore8(i, 0)
        }
        // Gets the code from the addr
        pop(_fetchDeployedCode(addr, add(offset, MEM_OFFSET_INNER()), len))
    }
    case 0x3D { // OP_RETURNDATASIZE
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let rdz := mload(LAST_RETURNDATA_SIZE_OFFSET())
        sp := pushStackItem(sp, rdz)
    }
    case 0x3E { // OP_RETURNDATACOPY
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let dest, offset, len
        dest, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        len, sp := popStackItem(sp)

        // TODO: check if these conditions are met
        // The addition offset + size overflows.
        // offset + size is larger than RETURNDATASIZE.
        if gt(add(offset, len), LAST_RETURNDATA_SIZE_OFFSET()) {
            revert(0, 0)
        }
        checkMemOverflow(add(add(dest, MEM_OFFSET_INNER()), len))

        // minimum_word_size = (size + 31) / 32
        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
        let minWordSize := shr(5, add(len, 31))
        let dynamicGas := add(mul(3, minWordSize), expandMemory(add(dest, len)))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        copyActivePtrData(add(MEM_OFFSET_INNER(), dest), offset, len)
    }
    case 0x3F { // OP_EXTCODEHASH
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let addr
        addr, sp := popStackItem(sp)

        if iszero(warmAddress(addr)) {
            evmGasLeft := chargeGas(evmGasLeft, 2500) 
        }

        sp := pushStackItem(sp, extcodehash(addr))
    }
    case 0x40 { // OP_BLOCKHASH
        evmGasLeft := chargeGas(evmGasLeft, 20)

        let blockNumber
        blockNumber, sp := popStackItem(sp)

        sp := pushStackItem(sp, blockhash(blockNumber))
    }
    case 0x41 { // OP_COINBASE
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, coinbase())
    }
    case 0x42 { // OP_TIMESTAMP
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, timestamp())
    }
    case 0x43 { // OP_NUMBER
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, number())
    }
    case 0x44 { // OP_PREVRANDAO
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, prevrandao())
    }
    case 0x45 { // OP_GASLIMIT
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, gaslimit())
    }
    case 0x46 { // OP_CHAINID
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, chainid())
    }
    case 0x47 { // OP_SELFBALANCE
        evmGasLeft := chargeGas(evmGasLeft, 5)
        sp := pushStackItem(sp, selfbalance())
    }
    case 0x48 { // OP_BASEFEE
        evmGasLeft := chargeGas(evmGasLeft, 2)
        sp := pushStackItem(sp, basefee())
    }
    case 0x50 { // OP_POP
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let _y

        _y, sp := popStackItem(sp)
    }
    case 0x51 { // OP_MLOAD
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset

        offset, sp := popStackItem(sp)

        let expansionGas := expandMemory(offset) // TODO: add +32 here
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        let memValue := mload(add(MEM_OFFSET_INNER(), offset))
        sp := pushStackItem(sp, memValue)
    }
    case 0x52 { // OP_MSTORE
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset, value

        offset, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        let expansionGas := expandMemory(offset) // TODO: add +32 here
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        mstore(add(MEM_OFFSET_INNER(), offset), value)
    }
    case 0x53 { // OP_MSTORE8
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let offset, value

        offset, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        let expansionGas := expandMemory(offset) // TODO: add +1 here
        evmGasLeft := chargeGas(evmGasLeft, expansionGas)

        mstore8(add(MEM_OFFSET_INNER(), offset), value)
    }
    case 0x54 { // OP_SLOAD
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let key, value, isWarm

        key, sp := popStackItem(sp)

        let wasWarm := isSlotWarm(key)

        if iszero(wasWarm) {
            evmGasLeft := chargeGas(evmGasLeft, 2000)
        }

        value := sload(key)

        if iszero(wasWarm) {
            let _wasW, _orgV := warmSlot(key, value)
        }

        sp := pushStackItem(sp,value)
    }
    case 0x55 { // OP_SSTORE
        evmGasLeft := chargeGas(evmGasLeft, 100)

        if isStatic {
            revert(0, 0)
        }

        let key, value, gasSpent

        key, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        {
            // Here it is okay to read before we charge since we known anyway that
            // the context has enough funds to compensate at least for the read.
            // Im not sure if we need this before: require(gasLeft > GAS_CALL_STIPEND);
            let currentValue := sload(key)
            let wasWarm, originalValue := warmSlot(key, currentValue)

            if eq(value, currentValue) {
                continue
            }

            if eq(originalValue, currentValue) {
                gasSpent := 19900
                if originalValue {
                    gasSpent := 2800
                }
            }

            if iszero(wasWarm) {
                gasSpent := add(gasSpent, 2100)
            }
        }

        evmGasLeft := chargeGas(evmGasLeft, gasSpent)
        sstore(key, value)
    }
    // NOTE: We don't currently do full jumpdest validation
    // (i.e. validating a jumpdest isn't in PUSH data)
    case 0x56 { // OP_JUMP
        evmGasLeft := chargeGas(evmGasLeft, 8)

        let counter

        counter, sp := popStackItem(sp)

        ip := add(add(BYTECODE_OFFSET(), 32), counter)

        // Check next opcode is JUMPDEST
        let nextOpcode := readIP(ip)
        if iszero(eq(nextOpcode, 0x5B)) {
            revert(0, 0)
        }
    }
    case 0x57 { // OP_JUMPI
        evmGasLeft := chargeGas(evmGasLeft, 10)

        let counter, b

        counter, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        if iszero(b) {
            continue
        }

        ip := add(add(BYTECODE_OFFSET(), 32), counter)

        // Check next opcode is JUMPDEST
        let nextOpcode := readIP(ip)
        if iszero(eq(nextOpcode, 0x5B)) {
            revert(0, 0)
        }
    }
    case 0x58 { // OP_PC
        evmGasLeft := chargeGas(evmGasLeft, 2)

        // PC = ip - 32 (bytecode size) - 1 (current instruction)
        sp := pushStackItem(sp, sub(sub(ip, BYTECODE_OFFSET()), 33))
    }
    case 0x59 { // OP_MSIZE
        evmGasLeft := chargeGas(evmGasLeft,2)

        let size

        size := mload(MEM_OFFSET())
        size := shl(5,size)
        sp := pushStackItem(sp,size)

    }
    case 0x5A { // OP_GAS
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, evmGasLeft)
    }
    case 0x5B { // OP_JUMPDEST
        evmGasLeft := chargeGas(evmGasLeft, 1)
    }
    case 0x5F { // OP_PUSH0
        evmGasLeft := chargeGas(evmGasLeft, 2)

        let value := 0

        sp := pushStackItem(sp, value)
    }
    case 0x60 { // OP_PUSH1
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,1)

        sp := pushStackItem(sp, value)
        ip := add(ip, 1)
    }
    case 0x61 { // OP_PUSH2
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,2)

        sp := pushStackItem(sp, value)
        ip := add(ip, 2)
    }     
    case 0x62 { // OP_PUSH3
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,3)

        sp := pushStackItem(sp, value)
        ip := add(ip, 3)
    }
    case 0x63 { // OP_PUSH4
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,4)

        sp := pushStackItem(sp, value)
        ip := add(ip, 4)
    }
    case 0x64 { // OP_PUSH5
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,5)

        sp := pushStackItem(sp, value)
        ip := add(ip, 5)
    }
    case 0x65 { // OP_PUSH6
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,6)

        sp := pushStackItem(sp, value)
        ip := add(ip, 6)
    }
    case 0x66 { // OP_PUSH7
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,7)

        sp := pushStackItem(sp, value)
        ip := add(ip, 7)
    }
    case 0x67 { // OP_PUSH8
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,8)

        sp := pushStackItem(sp, value)
        ip := add(ip, 8)
    }
    case 0x68 { // OP_PUSH9
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,9)

        sp := pushStackItem(sp, value)
        ip := add(ip, 9)
    }
    case 0x69 { // OP_PUSH10
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,10)

        sp := pushStackItem(sp, value)
        ip := add(ip, 10)
    }
    case 0x6A { // OP_PUSH11
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,11)

        sp := pushStackItem(sp, value)
        ip := add(ip, 11)
    }
    case 0x6B { // OP_PUSH12
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,12)

        sp := pushStackItem(sp, value)
        ip := add(ip, 12)
    }
    case 0x6C { // OP_PUSH13
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,13)

        sp := pushStackItem(sp, value)
        ip := add(ip, 13)
    }
    case 0x6D { // OP_PUSH14
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,14)

        sp := pushStackItem(sp, value)
        ip := add(ip, 14)
    }
    case 0x6E { // OP_PUSH15
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,15)

        sp := pushStackItem(sp, value)
        ip := add(ip, 15)
    }
    case 0x6F { // OP_PUSH16
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,16)

        sp := pushStackItem(sp, value)
        ip := add(ip, 16)
    }
    case 0x70 { // OP_PUSH17
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,17)

        sp := pushStackItem(sp, value)
        ip := add(ip, 17)
    }
    case 0x71 { // OP_PUSH18
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,18)

        sp := pushStackItem(sp, value)
        ip := add(ip, 18)
    }
    case 0x72 { // OP_PUSH19
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,19)

        sp := pushStackItem(sp, value)
        ip := add(ip, 19)
    }
    case 0x73 { // OP_PUSH20
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,20)

        sp := pushStackItem(sp, value)
        ip := add(ip, 20)
    }
    case 0x74 { // OP_PUSH21
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,21)

        sp := pushStackItem(sp, value)
        ip := add(ip, 21)
    }
    case 0x75 { // OP_PUSH22
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,22)

        sp := pushStackItem(sp, value)
        ip := add(ip, 22)
    }
    case 0x76 { // OP_PUSH23
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,23)

        sp := pushStackItem(sp, value)
        ip := add(ip, 23)
    }
    case 0x77 { // OP_PUSH24
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,24)

        sp := pushStackItem(sp, value)
        ip := add(ip, 24)
    }
    case 0x78 { // OP_PUSH25
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,25)

        sp := pushStackItem(sp, value)
        ip := add(ip, 25)
    }
    case 0x79 { // OP_PUSH26
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,26)

        sp := pushStackItem(sp, value)
        ip := add(ip, 26)
    }
    case 0x7A { // OP_PUSH27
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,27)

        sp := pushStackItem(sp, value)
        ip := add(ip, 27)
    }
    case 0x7B { // OP_PUSH28
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,28)

        sp := pushStackItem(sp, value)
        ip := add(ip, 28)
    }
    case 0x7C { // OP_PUSH29
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,29)

        sp := pushStackItem(sp, value)
        ip := add(ip, 29)
    }
    case 0x7D { // OP_PUSH30
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,30)

        sp := pushStackItem(sp, value)
        ip := add(ip, 30)
    }
    case 0x7E { // OP_PUSH31
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,31)

        sp := pushStackItem(sp, value)
        ip := add(ip, 31)
    }
    case 0x7F { // OP_PUSH32
        evmGasLeft := chargeGas(evmGasLeft, 3)

        let value := readBytes(ip,32)

        sp := pushStackItem(sp, value)
        ip := add(ip, 32)
    }
    case 0x80 { // OP_DUP1 
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 1)
    }
    case 0x81 { // OP_DUP2
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 2)
    }
    case 0x82 { // OP_DUP3
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 3)
    }
    case 0x83 { // OP_DUP4    
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 4)
    }
    case 0x84 { // OP_DUP5
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 5)
    }
    case 0x85 { // OP_DUP6
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 6)
    }
    case 0x86 { // OP_DUP7    
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 7)
    }
    case 0x87 { // OP_DUP8
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 8)
    }
    case 0x88 { // OP_DUP9
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 9)
    }
    case 0x89 { // OP_DUP10   
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 10)
    }
    case 0x8A { // OP_DUP11
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 11)
    }
    case 0x8B { // OP_DUP12
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 12)
    }
    case 0x8C { // OP_DUP13
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 13)
    }
    case 0x8D { // OP_DUP14
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 14)
    }
    case 0x8E { // OP_DUP15
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 15)
    }
    case 0x8F { // OP_DUP16
        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 16)
    }
    case 0x90 { // OP_SWAP1 
        evmGasLeft := swapStackItem(sp, evmGasLeft, 1)
    }
    case 0x91 { // OP_SWAP2
        evmGasLeft := swapStackItem(sp, evmGasLeft, 2)
    }
    case 0x92 { // OP_SWAP3
        evmGasLeft := swapStackItem(sp, evmGasLeft, 3)
    }
    case 0x93 { // OP_SWAP4    
        evmGasLeft := swapStackItem(sp, evmGasLeft, 4)
    }
    case 0x94 { // OP_SWAP5
        evmGasLeft := swapStackItem(sp, evmGasLeft, 5)
    }
    case 0x95 { // OP_SWAP6
        evmGasLeft := swapStackItem(sp, evmGasLeft, 6)
    }
    case 0x96 { // OP_SWAP7    
        evmGasLeft := swapStackItem(sp, evmGasLeft, 7)
    }
    case 0x97 { // OP_SWAP8
        evmGasLeft := swapStackItem(sp, evmGasLeft, 8)
    }
    case 0x98 { // OP_SWAP9
        evmGasLeft := swapStackItem(sp, evmGasLeft, 9)
    }
    case 0x99 { // OP_SWAP10   
        evmGasLeft := swapStackItem(sp, evmGasLeft, 10)
    }
    case 0x9A { // OP_SWAP11
        evmGasLeft := swapStackItem(sp, evmGasLeft, 11)
    }
    case 0x9B { // OP_SWAP12
        evmGasLeft := swapStackItem(sp, evmGasLeft, 12)
    }
    case 0x9C { // OP_SWAP13
        evmGasLeft := swapStackItem(sp, evmGasLeft, 13)
    }
    case 0x9D { // OP_SWAP14
        evmGasLeft := swapStackItem(sp, evmGasLeft, 14)
    }
    case 0x9E { // OP_SWAP15
        evmGasLeft := swapStackItem(sp, evmGasLeft, 15)
    }
    case 0x9F { // OP_SWAP16
        evmGasLeft := swapStackItem(sp, evmGasLeft, 16)
    }
    case 0xA0 { // OP_LOG0
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        log0(add(offset, MEM_OFFSET_INNER()), size)
    }
    case 0xA1 { // OP_LOG1
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            revert(0, 0)
        }

        let offset, size, topic1
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)
        topic1, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
        dynamicGas := add(dynamicGas, 375)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        log1(add(offset, MEM_OFFSET_INNER()), size, topic1)
    }
    case 0xA2 { // OP_LOG2
        evmGasLeft := chargeGas(evmGasLeft, 375)
        if isStatic {
            revert(0, 0)
        }

        let offset, size, topic1, topic2
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)
        topic1, sp := popStackItem(sp)
        topic2, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
        dynamicGas := add(dynamicGas, 750)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        log2(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2)
    }
    case 0xA3 { // OP_LOG3
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
        dynamicGas := add(dynamicGas, 1125)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {
            let topic1, topic2, topic3
            topic1, sp := popStackItem(sp)
            topic2, sp := popStackItem(sp)
            topic3, sp := popStackItem(sp)
            log3(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3)
        }
    }
    case 0xA4 { // OP_LOG4
        evmGasLeft := chargeGas(evmGasLeft, 375)

        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
        dynamicGas := add(dynamicGas, 1500)
        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

        {
            let topic1, topic2, topic3, topic4
            topic1, sp := popStackItem(sp)
            topic2, sp := popStackItem(sp)
            topic3, sp := popStackItem(sp)
            topic4, sp := popStackItem(sp)
            log4(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3, topic4)
        }

    }
    case 0xF0 { // OP_CREATE
        evmGasLeft := chargeGas(evmGasLeft, 32000)

        if isStatic {
            revert(0, 0)
        }

        let value, offset, size

        value, sp := popStackItem(sp)
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
        result, evmGasLeft := genericCreate(addr, offset, size, sp, value, evmGasLeft) //code_deposit_cost missing

        switch result
            case 0 { sp := pushStackItem(sp, 0) }
            default { sp := pushStackItem(sp, addr) }
    }
    case 0xF1 { // OP_CALL
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let gasUsed

        // A function was implemented in order to avoid stack depth errors.
        gasUsed, sp := performCall(sp, evmGasLeft, isStatic)

        // Check if the following is ok
        evmGasLeft := chargeGas(evmGasLeft, gasUsed)
    }
    case 0xF3 { // OP_RETURN
        let offset,size

        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        ensureAcceptableMemLocation(offset)
        ensureAcceptableMemLocation(size)
        evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))

        returnLen := size
        returnOffset := add(MEM_OFFSET_INNER(), offset)
        break
    }
    case 0xF4 { // OP_DELEGATECALL
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let gasUsed
        sp, isStatic, gasUsed := delegateCall(sp, isStatic, evmGasLeft)

        evmGasLeft := chargeGas(evmGasLeft, gasUsed)
    }
    case 0xF5 { // OP_CREATE2
        evmGasLeft := chargeGas(evmGasLeft, 32000)

        if isStatic {
            revert(0, 0)
        }

        let value, offset, size, salt

        value, sp := popStackItem(sp)
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

        let addr := and(
            keccak256(0, 0x55),
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        )

        let result
        result, evmGasLeft := genericCreate(addr, offset, size, sp, value, evmGasLeft) //code_deposit_cost missing

        switch result
            case 0 { sp := pushStackItem(sp, 0) }
            default { sp := pushStackItem(sp, addr) }
    }
    case 0xFA { // OP_STATICCALL
        evmGasLeft := chargeGas(evmGasLeft, 100)

        let gasUsed
        gasUsed, sp := performStaticCall(sp,evmGasLeft)
        evmGasLeft := chargeGas(evmGasLeft,gasUsed)
    }
    case 0xFD { // OP_REVERT
        let offset,size

        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        ensureAcceptableMemLocation(offset)
        ensureAcceptableMemLocation(size)
        evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))

        offset := add(offset, MEM_OFFSET_INNER())
        offset,size := addGasIfEvmRevert(isCallerEVM,offset,size,evmGasLeft)

        revert(offset,size)
    }
    case 0xFE { // OP_INVALID
        evmGasLeft := 0

        invalid()
    }
    default {
        printString("INVALID OPCODE")
        printHex(opcode)
        revert(0, 0)
    }
}
