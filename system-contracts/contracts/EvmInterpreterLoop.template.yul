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
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, add(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x02 { // OP_MUL
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, mul(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x03 { // OP_SUB
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sub(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x04 { // OP_DIV
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, div(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x05 { // OP_SDIV
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sdiv(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x06 { // OP_MOD
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, mod(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x07 { // OP_SMOD
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, smod(a, b))
        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x16 { // OP_AND
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, and(a,b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x17 { // OP_OR
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, or(a,b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x0A { // OP_EXP
        let a, exponent

        a, sp := popStackItem(sp)
        exponent, sp := popStackItem(sp)

        sp := pushStackItem(sp, exp(a, exponent))

        let expSizeByte := 0
        if exponent {
            expSizeByte := div(add(exponent, 256), 256)
        }

        evmGasLeft := chargeGas(evmGasLeft, add(10, mul(50, expSizeByte)))
    }
    case 0x0B { // OP_SIGNEXTEND
        let b, x

        b, sp := popStackItem(sp)
        x, sp := popStackItem(sp)

        sp := pushStackItem(sp, signextend(b, x))

        evmGasLeft := chargeGas(evmGasLeft, 5)
    }
    case 0x08 { // OP_ADDMOD
        let a, b, N

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)
        N, sp := popStackItem(sp)

        sp := pushStackItem(sp, addmod(a, b, N))

        evmGasLeft := chargeGas(evmGasLeft, 8)
    }
    case 0x09 { // OP_MULMOD
        let a, b, N

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)
        N, sp := popStackItem(sp)

        sp := pushStackItem(sp, mulmod(a, b, N))

        evmGasLeft := chargeGas(evmGasLeft, 8)
    }
    case 0x10 { // OP_LT
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, lt(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x11 { // OP_GT
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, gt(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x12 { // OP_SLT
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, slt(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x13 { // OP_SGT
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, sgt(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x14 { // OP_EQ
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, eq(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x15 { // OP_ISZERO
        let a

        a, sp := popStackItem(sp)

        sp := pushStackItem(sp, iszero(a))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x18 { // OP_XOR
        let a, b

        a, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        sp := pushStackItem(sp, xor(a, b))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x19 { // OP_NOT
        let a

        a, sp := popStackItem(sp)

        sp := pushStackItem(sp, not(a))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x1A { // OP_BYTE
        let i, x

        i, sp := popStackItem(sp)
        x, sp := popStackItem(sp)

        sp := pushStackItem(sp, byte(i, x))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x1B { // OP_SHL
        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, shl(shift, value))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x1C { // OP_SHR
        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, shr(shift, value))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x1D { // OP_SAR
        let shift, value

        shift, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        sp := pushStackItem(sp, sar(shift, value))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }

    case 0x20 { // OP_KECCAK256
        let offset, size

        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        sp := pushStackItem(sp, keccak256(add(MEM_OFFSET_INNER(), offset), size))

        // When an offset is first accessed (either read or write), memory may trigger 
        // an expansion, which costs gas.
        // dynamic_gas = 6 * minimum_word_size + memory_expansion_cost
        // minimum_word_size = (size + 31) / 32
        let minWordSize := shr(add(size, 31), 5)
        let dynamicGas := add(mul(6, minWordSize), expandMemory(add(offset, size)))
        let usedGas := add(30, dynamicGas)
        evmGasLeft := chargeGas(evmGasLeft, usedGas)
    }
    case 0x30 { // OP_ADDRESS
        sp := pushStackItem(sp, address())

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x31 { // OP_BALANCE
        let addr

        addr, sp := popStackItem(sp)

        let wasWarm := warmAddress(addr)

        sp := pushStackItem(sp, balance(addr))

        switch wasWarm
        case 0 { evmGasLeft := chargeGas(evmGasLeft, 2600) }
        default { evmGasLeft := chargeGas(evmGasLeft, 100) }
    }
    case 0x32 { // OP_ORIGIN
        sp := pushStackItem(sp, origin())

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x33 { // OP_CALLER
        sp := pushStackItem(sp, caller())

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x34 { // OP_CALLVALUE
        sp := pushStackItem(sp, callvalue())

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x35 { // OP_CALLDATALOAD
        let i

        i, sp := popStackItem(sp)

        sp := pushStackItem(sp, calldataload(i))

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x36 { // OP_CALLDATASIZE
        sp := pushStackItem(sp, calldatasize())

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x37 { // OP_CALLDATACOPY
        let destOffset, offset, size

        destOffset, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        let dest := add(destOffset, MEM_OFFSET_INNER())
        let end := sub(add(dest, size), 1)
        evmGasLeft := chargeGas(evmGasLeft, 3)

        checkMemOverflow(end)

        if or(gt(end, mload(MEM_OFFSET())), eq(end, mload(MEM_OFFSET()))) {
            evmGasLeft := chargeGas(evmGasLeft, expandMemory(end))
        }

        calldatacopy(add(MEM_OFFSET_INNER(), destOffset), offset, size)
    }
    case 0x38 { // OP_CODESIZE
        let bytecodeLen := mload(BYTECODE_OFFSET())
        sp := pushStackItem(sp, bytecodeLen)
        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x39 { // OP_CODECOPY
        let bytecodeLen := mload(BYTECODE_OFFSET())
        let dst, offset, len

        dst, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        len, sp := popStackItem(sp)

        // dynamic_gas = 3 * minimum_word_size + memory_expansion_cost
        // let minWordSize := div(add(len, 31), 32) Used inside the mul
        let dynamicGas := add(mul(3, div(add(len, 31), 32)), expandMemory(add(offset, len)))
        evmGasLeft := chargeGas(evmGasLeft, add(3, dynamicGas))

        let end := len
        if lt(bytecodeLen, len) {
            end := bytecodeLen
        }

        for { let i := 0 } lt(i, end) { i := add(i, 1) } {
            mstore8(
                add(MEM_OFFSET_INNER(), add(dst, i)),
                shr(248, mload(add(BYTECODE_OFFSET(), add(32, add(offset, i)))))
            )
        }
        for { let i := end } lt(i, len) { i := add(i, 1) } {
            mstore8(add(MEM_OFFSET_INNER(), add(dst, i)), 0)
        }
    }
    case 0x3A { // OP_GASPRICE
        sp := pushStackItem(sp, gasprice())
        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x3B { // OP_EXTCODESIZE
        let addr
        addr, sp := popStackItem(sp)

        // Check if its warm or cold
        switch warmAddress(addr)
            case true {
                evmGasLeft := chargeGas(evmGasLeft, 100)
            }
            default {
                evmGasLeft := chargeGas(evmGasLeft, 2600)
            }

        // TODO: check, the .sol uses extcodesize directly, but it doesnt seem to work
        // if a contract is created it works, but if the address is a zkSync's contract
        // what happens?
        switch _isEVM(addr) 
            case 0  { sp := pushStackItem(sp, extcodesize(addr)) }
            default { sp := pushStackItem(sp, _fetchDeployedCodeLen(addr)) }
    }
    case 0x3C { // OP_EXTCODECOPY
        let addr, dest, offset, len
        addr, sp := popStackItem(sp)
        dest, sp := popStackItem(sp)
        offset, sp := popStackItem(sp)
        len, sp := popStackItem(sp)

        // Check if its warm or cold
        // minimum_word_size = (size + 31) / 32
        // static_gas = 0
        // dynamic_gas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
        let dynamicGas
        switch warmAddress(addr)
            case true {
                dynamicGas := 100
            }
            default {
                dynamicGas := 2600
            }

        dynamicGas := add(dynamicGas, add(mul(3, shr(5, add(len, 31))), expandMemory(add(offset, len))))
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
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), len))

        // minimum_word_size = (size + 31) / 32
        // dynamic_gas = 6 * minimum_word_size + memory_expansion_cost
        // static_gas = 0
        let dynamicGas := add(mul(6, shr(add(len, 31), 5)), expandMemory(add(offset, len)))
        evmGasLeft := chargeGas(evmGasLeft, add(3, dynamicGas))

        copyActivePtrData(add(MEM_OFFSET_INNER(), dest), offset, len)
    }
    case 0x3F { // OP_EXTCODEHASH
        let addr
        addr, sp := popStackItem(sp)


        switch warmAddress(addr)
            case 0 { 
                evmGasLeft := chargeGas(evmGasLeft,2600) 
            }
            default { 
                evmGasLeft := chargeGas(evmGasLeft,100) 
            }

        sp := pushStackItem(sp, extcodehash(addr))
    }
    case 0x40 { // OP_BLOCKHASH
        let blockNumber
        blockNumber, sp := popStackItem(sp)

        evmGasLeft := chargeGas(evmGasLeft, 20)
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
        let _y

        _y, sp := popStackItem(sp)

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x51 { // OP_MLOAD
        let offset

        offset, sp := popStackItem(sp)

        let expansionGas := expandMemory(add(offset, 32))

        let memValue := mload(add(MEM_OFFSET_INNER(), offset))
        sp := pushStackItem(sp, memValue)
        evmGasLeft := chargeGas(evmGasLeft, add(3, expansionGas))
    }
    case 0x52 { // OP_MSTORE
        let offset, value

        offset, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        let expansionGas := expandMemory(add(offset, 32))

        mstore(add(MEM_OFFSET_INNER(), offset), value)
        evmGasLeft := chargeGas(evmGasLeft, add(3, expansionGas))
    }
    case 0x53 { // OP_MSTORE8
        let offset, value

        offset, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        let expansionGas := expandMemory(add(offset, 1))

        mstore8(add(MEM_OFFSET_INNER(), offset), value)
        evmGasLeft := chargeGas(evmGasLeft, add(3, expansionGas))
    }
    // NOTE: We don't currently do full jumpdest validation
    // (i.e. validating a jumpdest isn't in PUSH data)
    case 0x56 { // OP_JUMP
        let counter

        counter, sp := popStackItem(sp)

        ip := add(add(BYTECODE_OFFSET(), 32), counter)

        evmGasLeft := chargeGas(evmGasLeft, 8)

        // Check next opcode is JUMPDEST
        let nextOpcode := readIP(ip)
        if iszero(eq(nextOpcode, 0x5B)) {
            revert(0, 0)
        }
    }
    case 0x57 { // OP_JUMPI
        let counter, b

        counter, sp := popStackItem(sp)
        b, sp := popStackItem(sp)

        evmGasLeft := chargeGas(evmGasLeft, 10)

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
    case 0x54 { // OP_SLOAD
        let key,value,isWarm

        key, sp := popStackItem(sp)

        isWarm := isSlotWarm(key)
        switch isWarm
        case 0 { evmGasLeft := chargeGas(evmGasLeft,2100) }
        default { evmGasLeft := chargeGas(evmGasLeft,100) }

        value := sload(key)

        sp := pushStackItem(sp,value)
    }
    case 0x55 { // OP_SSTORE
        if isStatic {
            revert(0, 0)
        }

        let key, value,gasSpent

        key, sp := popStackItem(sp)
        value, sp := popStackItem(sp)

        {
            // Here it is okay to read before we charge since we known anyway that
            // the context has enough funds to compensate at least for the read.
            // Im not sure if we need this before: require(gasLeft > GAS_CALL_STIPEND);
            let currentValue := sload(key)
            let wasWarm,originalValue := warmSlot(key,currentValue)
            gasSpent := 100
            if and(not(eq(value,currentValue)),eq(originalValue,currentValue)) {
                switch originalValue
                case 0 { gasSpent := 20000}
                default { gasSpent := 2900}
            }
            if iszero(wasWarm) {
                gasSpent := add(gasSpent,2100)
            }
        }

        evmGasLeft := chargeGas(evmGasLeft, gasSpent) //gasSpent
        sstore(key, value)
    }
    case 0x59 { // OP_MSIZE
        let size
        evmGasLeft := chargeGas(evmGasLeft,2)

        size := mload(MEM_OFFSET())
        size := shl(5,size)
        sp := pushStackItem(sp,size)

    }
    case 0x58 { // OP_PC
        // PC = ip - 32 (bytecode size) - 1 (current instruction)
        sp := pushStackItem(sp, sub(sub(ip, BYTECODE_OFFSET()), 33))

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x5A { // OP_GAS
        evmGasLeft := chargeGas(evmGasLeft, 2)

        sp := pushStackItem(sp, evmGasLeft)
    }
    case 0x5B { // OP_JUMPDEST
        evmGasLeft := chargeGas(evmGasLeft, 1)
    }
    case 0x5F { // OP_PUSH0
        let value := 0

        sp := pushStackItem(sp, value)

        evmGasLeft := chargeGas(evmGasLeft, 2)
    }
    case 0x60 { // OP_PUSH1
        let value := readBytes(ip,1)

        sp := pushStackItem(sp, value)
        ip := add(ip, 1)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x61 { // OP_PUSH2
        let value := readBytes(ip,2)

        sp := pushStackItem(sp, value)
        ip := add(ip, 2)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }     
    case 0x62 { // OP_PUSH3
        let value := readBytes(ip,3)

        sp := pushStackItem(sp, value)
        ip := add(ip, 3)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x63 { // OP_PUSH4
        let value := readBytes(ip,4)

        sp := pushStackItem(sp, value)
        ip := add(ip, 4)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x64 { // OP_PUSH5
        let value := readBytes(ip,5)

        sp := pushStackItem(sp, value)
        ip := add(ip, 5)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x65 { // OP_PUSH6
        let value := readBytes(ip,6)

        sp := pushStackItem(sp, value)
        ip := add(ip, 6)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x66 { // OP_PUSH7
        let value := readBytes(ip,7)

        sp := pushStackItem(sp, value)
        ip := add(ip, 7)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x67 { // OP_PUSH8
        let value := readBytes(ip,8)

        sp := pushStackItem(sp, value)
        ip := add(ip, 8)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x68 { // OP_PUSH9
        let value := readBytes(ip,9)

        sp := pushStackItem(sp, value)
        ip := add(ip, 9)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x69 { // OP_PUSH10
        let value := readBytes(ip,10)

        sp := pushStackItem(sp, value)
        ip := add(ip, 10)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6A { // OP_PUSH11
        let value := readBytes(ip,11)

        sp := pushStackItem(sp, value)
        ip := add(ip, 11)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6B { // OP_PUSH12
        let value := readBytes(ip,12)

        sp := pushStackItem(sp, value)
        ip := add(ip, 12)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6C { // OP_PUSH13
        let value := readBytes(ip,13)

        sp := pushStackItem(sp, value)
        ip := add(ip, 13)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6D { // OP_PUSH14
        let value := readBytes(ip,14)

        sp := pushStackItem(sp, value)
        ip := add(ip, 14)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6E { // OP_PUSH15
        let value := readBytes(ip,15)

        sp := pushStackItem(sp, value)
        ip := add(ip, 15)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x6F { // OP_PUSH16
        let value := readBytes(ip,16)

        sp := pushStackItem(sp, value)
        ip := add(ip, 16)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x70 { // OP_PUSH17
        let value := readBytes(ip,17)

        sp := pushStackItem(sp, value)
        ip := add(ip, 17)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x71 { // OP_PUSH18
        let value := readBytes(ip,18)

        sp := pushStackItem(sp, value)
        ip := add(ip, 18)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x72 { // OP_PUSH19
        let value := readBytes(ip,19)

        sp := pushStackItem(sp, value)
        ip := add(ip, 19)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x73 { // OP_PUSH20
        let value := readBytes(ip,20)

        sp := pushStackItem(sp, value)
        ip := add(ip, 20)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x74 { // OP_PUSH21
        let value := readBytes(ip,21)

        sp := pushStackItem(sp, value)
        ip := add(ip, 21)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x75 { // OP_PUSH22
        let value := readBytes(ip,22)

        sp := pushStackItem(sp, value)
        ip := add(ip, 22)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x76 { // OP_PUSH23
        let value := readBytes(ip,23)

        sp := pushStackItem(sp, value)
        ip := add(ip, 23)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x77 { // OP_PUSH24
        let value := readBytes(ip,24)

        sp := pushStackItem(sp, value)
        ip := add(ip, 24)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x78 { // OP_PUSH25
        let value := readBytes(ip,25)

        sp := pushStackItem(sp, value)
        ip := add(ip, 25)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x79 { // OP_PUSH26
        let value := readBytes(ip,26)

        sp := pushStackItem(sp, value)
        ip := add(ip, 26)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7A { // OP_PUSH27
        let value := readBytes(ip,27)

        sp := pushStackItem(sp, value)
        ip := add(ip, 27)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7B { // OP_PUSH28
        let value := readBytes(ip,28)

        sp := pushStackItem(sp, value)
        ip := add(ip, 28)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7C { // OP_PUSH29
        let value := readBytes(ip,29)

        sp := pushStackItem(sp, value)
        ip := add(ip, 29)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7D { // OP_PUSH30
        let value := readBytes(ip,30)

        sp := pushStackItem(sp, value)
        ip := add(ip, 30)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7E { // OP_PUSH31
        let value := readBytes(ip,31)

        sp := pushStackItem(sp, value)
        ip := add(ip, 31)

        evmGasLeft := chargeGas(evmGasLeft, 3)
    }
    case 0x7F { // OP_PUSH32
        let value := readBytes(ip,32)

        sp := pushStackItem(sp, value)
        ip := add(ip, 32)

        evmGasLeft := chargeGas(evmGasLeft, 3)
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
        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(offset, MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        {
            let gasUsed := add(add(375, mul(8, size)), expandMemory(add(offset, size)))
            evmGasLeft := chargeGas(evmGasLeft, gasUsed)
        }

        log0(add(offset, MEM_OFFSET_INNER()), size)
    }
    case 0xA1 { // OP_LOG1
        if isStatic {
            revert(0, 0)
        }

        let offset, size, topic1
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)
        topic1, sp := popStackItem(sp)

        checkMemOverflow(add(offset, MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        let gasUsed := add(add(750, mul(8, size)), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, gasUsed)

        log1(add(offset, MEM_OFFSET_INNER()), size, topic1)
    }
    case 0xA2 { // OP_LOG2
        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(offset, MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        let gasUsed := add(add(1125, mul(8, size)), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, gasUsed)

        {
            let topic1, topic2
            topic1, sp := popStackItem(sp)
            topic2, sp := popStackItem(sp)
            log2(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2)
        }
    }
    case 0xA3 { // OP_LOG3
        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(offset, MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        let gasUsed := add(add(1500, mul(8, size)), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, gasUsed)

        {
            let topic1, topic2, topic3
            topic1, sp := popStackItem(sp)
            topic2, sp := popStackItem(sp)
            topic3, sp := popStackItem(sp)
            log3(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3)
        }
    }
    case 0xA4 { // OP_LOG4
        if isStatic {
            revert(0, 0)
        }

        let offset, size
        offset, sp := popStackItem(sp)
        size, sp := popStackItem(sp)

        checkMemOverflow(add(offset, MEM_OFFSET_INNER()))
        checkMemOverflow(add(add(offset, MEM_OFFSET_INNER()), size))

        let gasUsed := add(add(1875, mul(8, size)), expandMemory(add(offset, size)))
        evmGasLeft := chargeGas(evmGasLeft, gasUsed)

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

        evmGasLeft := chargeGas(evmGasLeft, add(
            32000, add(
            expandMemory(add(offset, size)),
            mul(2, div(add(size, 31), 32))
            )
        ))

        let addr := getNewAddress(address())

        let result := genericCreate(addr, offset, size, sp)

        switch result
            case 0 { sp := pushStackItem(sp, 0) }
            default { sp := pushStackItem(sp, addr) }
    }
    case 0xF5 { // OP_CREATE2
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

        evmGasLeft := chargeGas(evmGasLeft, add(
            32000, add(
            expandMemory(add(offset, size)),
            mul(2, div(add(size, 31), 32))
            )
        ))

        let hashedBytecode := keccak256(add(MEM_OFFSET_INNER(), offset), size)
        mstore8(0, 0xFF)
        mstore(0x01, shl(0x60, address()))
        mstore(0x15, salt)
        mstore(0x35, hashedBytecode)

        let addr := and(
            keccak256(0, 0x55),
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        )

        let result := genericCreate(addr, offset, size, sp)

        switch result
            case 0 { sp := pushStackItem(sp, 0) }
            default { sp := pushStackItem(sp, addr) }
    }
    case 0xF1 { // OP_CALL
        let dynamicGas, frameGasLeft, gasToPay

        // A function was implemented in order to avoid stack depth errors.
        frameGasLeft, gasToPay, sp := performCall(sp, evmGasLeft, isStatic)
        
        // Check if the following is ok
        evmGasLeft := chargeGas(evmGasLeft, gasToPay)
        evmGasLeft := add(evmGasLeft, frameGasLeft)
    }
    case 0xFA { // OP_STATICCALL
        let addr, argsOffset, argsSize, retOffset, retSize

        addr, sp := popStackItem(sp)
        addr, sp := popStackItem(sp)
        argsOffset, sp := popStackItem(sp)
        argsSize, sp := popStackItem(sp)
        retOffset, sp := popStackItem(sp)
        retSize, sp := popStackItem(sp)

        let success
        if _isEVM(addr) {
            _pushEVMFrame(gas(), true)
            // TODO Check the following comment from zkSync .sol.
            // We can not just pass all gas here to prevert overflow of zkEVM gas counter
            success := staticcall(gas(), addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, 0, 0)

            pop(_saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize))
            _popEVMFrame()
        }

        // zkEVM native
        if iszero(_isEVM(addr)) {
            // _calleeGas := _getZkEVMGas(_calleeGas)
            // let zkevmGasBefore := gas()
            success := staticcall(gas(), addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, add(MEM_OFFSET_INNER(), retOffset), retSize)

            _saveReturndataAfterZkEVMCall()

            // let gasUsed := _calcEVMGas(sub(zkevmGasBefore, gas()))

            // _gasLeft := 0
            // if gt(_calleeGas, gasUsed) {
            //     _gasLeft := sub(_calleeGas, gasUsed)
            // }
        }

        sp := pushStackItem(sp, success)
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
        sp, isStatic := delegateCall(sp, isStatic, evmGasLeft)
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
