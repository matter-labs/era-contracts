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
                for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                    let next_byte := readIP(add(start, i))

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
                case 0x17 { // OP_OR
                    let a, b

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)

                    sp := pushStackItem(sp, or(a,b))
                }
                case 0x0A { // OP_EXP
                    let a, exponent

                    a, sp := popStackItem(sp)
                    exponent, sp := popStackItem(sp)

                    sp := pushStackItem(sp, exp(a, exponent))
                }
                case 0x0B { // OP_SIGNEXTEND
                    let b, x

                    b, sp := popStackItem(sp)
                    x, sp := popStackItem(sp)

                    sp := pushStackItem(sp, signextend(b, x))
                }
                case 0x08 { // OP_ADDMOD
                    let a, b, N

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)
                    N, sp := popStackItem(sp)

                    sp := pushStackItem(sp, addmod(a, b, N))
                }
                case 0x09 { // OP_MULMOD
                    let a, b, N

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)
                    N, sp := popStackItem(sp)

                    sp := pushStackItem(sp, mulmod(a, b, N))
                }
                case 0x55 { // OP_SSTORE
                    let key, value

                    key, sp := popStackItem(sp)
                    value, sp := popStackItem(sp)

                    sstore(key, value)
                    // TODO: Handle cold/warm slots and updates, etc for gas costs.
                    evmGasLeft := chargeGas(evmGasLeft, 100)
                }
                case 0x5F { // OP_PUSH0
                    let value := 0

                    sp := pushStackItem(sp, value)
                }
                case 0x60 { // OP_PUSH1
                    let value := readBytes(ip,1)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 1)
                }
                case 0x61 { // OP_PUSH2
                    let value := readBytes(ip,2)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 2)
                }     
                case 0x62 { // OP_PUSH3
                    let value := readBytes(ip,3)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 3)
                }
                case 0x63 { // OP_PUSH4
                    let value := readBytes(ip,4)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 4)
                }
                case 0x64 { // OP_PUSH5
                    let value := readBytes(ip,5)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 5)
                }
                case 0x65 { // OP_PUSH6
                    let value := readBytes(ip,6)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 6)
                }
                case 0x66 { // OP_PUSH7
                    let value := readBytes(ip,7)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 7)
                }
                case 0x67 { // OP_PUSH8
                    let value := readBytes(ip,8)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 8)
                }
                case 0x68 { // OP_PUSH9
                    let value := readBytes(ip,9)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 9)
                }
                case 0x69 { // OP_PUSH10
                    let value := readBytes(ip,10)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 10)
                }
                case 0x6A { // OP_PUSH11
                    let value := readBytes(ip,11)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 11)
                }
                case 0x6B { // OP_PUSH12
                    let value := readBytes(ip,12)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 12)
                }
                case 0x6C { // OP_PUSH13
                    let value := readBytes(ip,13)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 13)
                }
                case 0x6D { // OP_PUSH14
                    let value := readBytes(ip,14)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 14)
                }
                case 0x6E { // OP_PUSH15
                    let value := readBytes(ip,15)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 15)
                }
                case 0x6F { // OP_PUSH16
                    let value := readBytes(ip,16)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 16)
                }
                case 0x70 { // OP_PUSH17
                    let value := readBytes(ip,17)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 17)
                }
                case 0x71 { // OP_PUSH18
                    let value := readBytes(ip,18)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 18)
                }
                case 0x72 { // OP_PUSH19
                    let value := readBytes(ip,19)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 19)
                }
                case 0x73 { // OP_PUSH20
                    let value := readBytes(ip,20)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 20)
                }
                case 0x74 { // OP_PUSH21
                    let value := readBytes(ip,21)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 21)
                }
                case 0x75 { // OP_PUSH22
                    let value := readBytes(ip,22)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 22)
                }
                case 0x76 { // OP_PUSH23
                    let value := readBytes(ip,23)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 23)
                }
                case 0x77 { // OP_PUSH24
                    let value := readBytes(ip,24)
                
                    sp := pushStackItem(sp, value)
                    ip := add(ip, 24)
                }
                case 0x78 { // OP_PUSH25
                    let value := readBytes(ip,25)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 25)
                }
                case 0x79 { // OP_PUSH26
                    let value := readBytes(ip,26)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 26)
                }
                case 0x7A { // OP_PUSH27
                    let value := readBytes(ip,27)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 27)
                }
                case 0x7B { // OP_PUSH28
                    let value := readBytes(ip,28)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 28)
                }
                case 0x7C { // OP_PUSH29
                    let value := readBytes(ip,29)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 29)
                }
                case 0x7D { // OP_PUSH30
                    let value := readBytes(ip,30)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 30)
                }
                case 0x7E { // OP_PUSH31
                    let value := readBytes(ip,31)

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 31)
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
