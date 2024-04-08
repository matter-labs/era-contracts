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

            function CODE_ORACLE_SYSTEM_CONTRACT() -> offset {
                offset := 0x0000000000000000000000000000000000008012
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

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////


            // TALK ABOUT THE DIFFERENCE BETWEEN VERBATIM AND DOING A STATIC CALL.
            // IN SOLIDITY A STATIC CALL IS REPLACED BY A VERBATIM IF THE ADDRES IS ONE
            // OF THE ONES IN THE SYSTEM CONTRACT LIST WHATEVER.
            // IN YUL NO SUCH REPLACEMENTE TAKES PLACE, YOU NEED TO DO THE VERBATIM CALL
            // MANUALLY.

            // First, copy the contract's bytecode to be executed into the `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

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
                    // TODO: This is not actually what stop does
                }
                case 0x01 { // OP_ADD
                    let a, b

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)

                    sp := pushStackItem(sp, add(a, b))
                    // TODO: Charge for gas
                }
                case 0x02 { // OP_MUL
                    let a, b

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)

                    sp := pushStackItem(sp, mul(a, b))
                }
                case 0x03 { // OP_SUB
                    let a, b

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)

                    sp := pushStackItem(sp, sub(a, b))
                }
                case 0x08 { // OP_ADDMOD
                    let a, b, N

                    a, sp := popStackItem(sp)
                    b, sp := popStackItem(sp)
                    N, sp := popStackItem(sp)

                    sp := pushStackItem(sp, addmod(a, b, N))
                }
                case 0x55 { // OP_SSTORE
                    let key, value

                    key, sp := popStackItem(sp)
                    value, sp := popStackItem(sp)

                    sstore(key, value)
                    return(0, 64)
                }
                case 0x7F { // OP_PUSH32
                    let value
                    for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                        let next_byte := readIP(add(ip, i))

                        value := or(shl(8, value), next_byte)
                    }

                    sp := pushStackItem(sp, value)
                    ip := add(ip, 32)
                }
                // TODO: REST OF OPCODES
                default {
                    // TODO: Revert properly here and report the unrecognized opcode
                    sstore(0, opcode)
                    return(0, 64)
                }
            }

            return(0, 64)
        }
    }
}
