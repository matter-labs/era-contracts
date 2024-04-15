object "EVMInterpreter" {
    code { }
    object "EVMInterpreter_deployed" {
        code {
            function SYSTEM_CONTRACTS_OFFSET() -> offset {
                offset := 0x8000
            }

            function ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT() -> addr {
                addr := 0x0000000000000000000000000000000000008002
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
    
            // It is the responsibility of the caller to ensure that ip >= BYTECODE_OFFSET + 32
            function readIP(ip) -> opcode {
                // TODO: Why not do this at the beginning once instead of every time?
                let bytecodeLen := mload(BYTECODE_OFFSET())

                let maxAcceptablePos := add(add(BYTECODE_OFFSET(), bytecodeLen), 31)
                if gt(ip, maxAcceptablePos) {
                    revert(0, 0)
                }

                opcode := and(mload(sub(ip, 31)), 0xff)
            }

            function readBytes(start, length) -> value {
                let max := add(start, length)
                for {} lt(start, max) { start := add(start, 1) } {
                    let next_byte := readIP(start)

                    value := or(shl(8, value), next_byte)
                }
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

            function checkMemOverflow(location) {
                if gt(location, MAX_MEMORY_FRAME()) {
                    revert(0, 0)
                }
            }

            // Note, that this function can overflow. It's up to the caller to ensure that it does not.
            function memCost(memSizeWords) -> gasCost {
                // The first term of the sum is the quadratic cost, the second one the linear one.
                gasCost := add(div(mul(memSizeWords, memSizeWords), 512), mul(3, memSizeWords))
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
                    // TODO: Check this, it feels like there might be a more optimized way
                    // of doing this cost calculation.
                    let oldCost := memCost(oldSizeInWords)
                    let newCost := memCost(newSizeInWords)

                    gasCost := sub(newCost, oldCost)
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

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // TALK ABOUT THE DIFFERENCE BETWEEN VERBATIM AND DOING A STATIC CALL.
            // IN SOLIDITY A STATIC CALL IS REPLACED BY A VERBATIM IF THE ADDRES IS ONE
            // OF THE ONES IN THE SYSTEM CONTRACT LIST WHATEVER.
            // IN YUL NO SUCH REPLACEMENTE TAKES PLACE, YOU NEED TO DO THE VERBATIM CALL
            // MANUALLY.

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            // TODO: Check if caller is not EVM and override evmGasLeft and isStatic with their
            // appropriate values if so.

            // First, copy the contract's bytecode to be executed into the `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

            // stack pointer - index to first stack element; empty stack = -1
            let sp := sub(STACK_OFFSET(), 32)
            // instruction pointer - index to next instruction. Not called pc because it's an
            // actual yul/evm instruction.
            let ip := add(BYTECODE_OFFSET(), 32)
            let opcode

            let returnOffset := MEM_OFFSET_INNER()
            let returnLen := 0

            pop(warmAddress(address()))

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
                    if not(iszero(exponent)) {
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

                    // TODO: Handle cold/warm slots and updates, etc for gas costs.
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

                    // basically BYTECODE_OFFSET + 32 - 31, since
                    // we always need to read one byte
                    let bytecodeOffsetInner := add(BYTECODE_OFFSET(), 1)

                    // TODO: optimize?
                    for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                        switch lt(add(offset, i), bytecodeLen)
                            case true {
                                mstore8(
                                    add(add(MEM_OFFSET_INNER(), offset), i),
                                    and(mload(add(add(bytecodeOffsetInner, offset), i)), 0xFF)
                                )
                            }
                            default {
                                mstore8(add(add(MEM_OFFSET_INNER(), offset), i), 0)
                            }
                    }
                }
                case 0x3A { // OP_GASPRICE
                    sp := pushStackItem(sp, gasprice())
                    evmGasLeft := chargeGas(evmGasLeft, 2)
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
                // TODO: REST OF OPCODES
                default {
                    // TODO: Revert properly here and report the unrecognized opcode
                    sstore(0, opcode)
                    return(0, 64)
                }
            }

            if eq(isCallerEVM, 1) {
                // Includes gas
                returnOffset := sub(returnOffset, 32)
                returnLen := add(returnLen, 32)
            }

            return(returnOffset, returnLen)
        }
    }
}
