object "EvmEmulator" {
    code {
        function MAX_POSSIBLE_ACTIVE_BYTECODE() -> max {
            max := MAX_POSSIBLE_INIT_BYTECODE_LEN()
        }

        /// @dev This function is used to get the initCode.
        /// @dev It assumes that the initCode has been passed via the calldata and so we use the pointer
        /// to obtain the bytecode.
        function getConstructorBytecode() {
            loadCalldataIntoActivePtr()

            let size := getActivePtrDataSize()

            if gt(size, MAX_POSSIBLE_INIT_BYTECODE_LEN()) {
                panic()
            }

            mstore(BYTECODE_LEN_OFFSET(), size)
            mstore(EMPTY_CODE_OFFSET(), 0)
            copyActivePtrData(BYTECODE_OFFSET(), 0, size)
        }

        function padBytecode(offset, len) -> blobOffset, blobLen {
            blobOffset := sub(offset, 32)
            let trueLastByte := add(offset, len)

            mstore(blobOffset, len)
            // clearing out additional bytes
            mstore(trueLastByte, 0)
            mstore(add(trueLastByte, 32), 0)

            blobLen := add(len, 32)

            if iszero(eq(mod(blobLen, 32), 0)) {
                blobLen := add(blobLen, sub(32, mod(blobLen, 32)))
            }

            // Now it is divisible by 32, but we must make sure that the number of 32 byte words is odd
            if iszero(eq(mod(blobLen, 64), 32)) {
                blobLen := add(blobLen, 32)
            }
        }

        function validateBytecodeAndChargeGas(offset, deployedCodeLen, gasToReturn) -> returnGas {
            if deployedCodeLen {
                // EIP-3860
                if gt(deployedCodeLen, MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()) {
                    panic()
                }

                // EIP-3541
                let firstByte := shr(248, mload(offset))
                if eq(firstByte, 0xEF) {
                    panic()
                }
            }

            let gasForCode := mul(deployedCodeLen, 200)
            returnGas := chargeGas(gasToReturn, gasForCode)
        }

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
        
        function BYTECODE_LEN_OFFSET() -> offset {
            offset := add(STACK_OFFSET(), mul(1024, 32))
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
        // The cost to increase the memory to 4 MB is close to 30M gas
        function MAX_POSSIBLE_MEM_LEN() -> max {
            max := 0x400000 // 4MB
        }
        
        function MAX_MEMORY_SLOT() -> max {
            max := add(MEM_OFFSET(), MAX_POSSIBLE_MEM_LEN())
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
        
        // From precompiles/CodeOracle
        function DECOMMIT_COST_PER_WORD() -> cost { cost := 4 }
        
        function UINT32_MAX() -> ret { ret := 4294967295 } // 2^32 - 1
        
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
        
        function checkMemIsAccessible(index, offset) {
            checkOverflow(index, offset)
        
            if gt(add(index, offset), MAX_MEMORY_SLOT()) {
                panic()
            }
        }
        
        function checkOverflow(data1, data2) {
            if lt(add(data1, data2), data2) {
                panic()
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
        
        // Basically performs an extcodecopy, while returning the length of the copied bytecode.
        function fetchDeployedCode(addr, dstOffset, srcOffset, len) -> copiedLen {
            let codeHash := getRawCodeHash(addr)
            mstore(0, codeHash)
            // The first word of returndata is the true length of the bytecode
            let codeLen := fetchFromSystemContract(CODE_ORACLE_SYSTEM_CONTRACT(), 32)
        
            if gt(len, codeLen) {
                len := codeLen
            }
        
            let shiftedSrcOffset := add(32, srcOffset) // first 32 bits is length
        
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
        
        function performSystemCall(to, dataLength) {
            let success := performSystemCallRevertable(to, dataLength)
        
            if iszero(success) {
                // This error should never happen
                abortEvmEnvironment()
            }
        }
        
        function performSystemCallRevertable(to, dataLength) -> success {
            let farCallAbi := shl(248, 1) // system call
            // dataOffset is 0
            // dataStart is 0
            farCallAbi :=  or(farCallAbi, shl(96, dataLength))
            farCallAbi :=  or(farCallAbi, shl(192, gas()))
            // shardId is 0
            // forwardingMode is 0
            // not constructor call
        
            success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        }
        
        ////////////////////////////////////////////////////////////////
        //                     STACK OPERATIONS
        ////////////////////////////////////////////////////////////////
        
        function dupStackItem(sp, evmGas, position, oldStackHead) -> newSp, evmGasLeft, stackHead {
            evmGasLeft := chargeGas(evmGas, 3)
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
            if iszero(lt(sp, BYTECODE_LEN_OFFSET())) {
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
        
        function pushStackCheck(sp, numInputs) {
            if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_LEN_OFFSET())) {
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
        
        function performCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
            let gasToPass, addr, value, argsOffset, argsSize, retOffset, retSize
        
            popStackCheck(oldSp, 7)
            gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
            addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            checkMemIsAccessible(argsOffset, argsSize)
            checkMemIsAccessible(retOffset, retSize)
        
            // static_gas = 0
            // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
            // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
            // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
            // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called.
            // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.
        
            let gasUsed := 100 // warm address access cost
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                gasUsed := 2600 // cold address access cost
            }
        
            // memory_expansion_cost
            gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
        
            if gt(value, 0) {
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
                false
            )
        
            newGasLeft := add(evmGasLeft, frameGasLeft)
            stackHead := success
        }
        
        function performStaticCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
            let gasToPass,addr, argsOffset, argsSize, retOffset, retSize
        
            popStackCheck(oldSp, 6)
            gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
            addr, sp, stackHead  := popStackItemWithoutCheck(sp, stackHead)
            argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            checkMemIsAccessible(argsOffset, argsSize)
            checkMemIsAccessible(retOffset, retSize)
        
            let gasUsed := 100 // warm address access cost
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                gasUsed := 2600 // cold address access cost
            }
        
            // memory_expansion_cost
            gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
        
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
            let addr, gasToPass, argsOffset, argsSize, retOffset, retSize
        
            popStackCheck(oldSp, 6)
            gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
            addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            checkMemIsAccessible(argsOffset, argsSize)
            checkMemIsAccessible(retOffset, retSize)
        
            let gasUsed := 100 // warm address access cost
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                gasUsed := 2600 // cold address access cost
            }
        
            // memory_expansion_cost
            gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
        
            evmGasLeft := chargeGas(evmGasLeft, gasUsed)
        
            // it is also not possible to delegatecall precompiles
            if iszero(isEvmContract(addr)) {
                revertWithGas(evmGasLeft)
            }
        
            gasToPass := capGasForCall(evmGasLeft, gasToPass)
            evmGasLeft := sub(evmGasLeft, gasToPass)
        
            pushEvmFrame(gasToPass, isStatic)
            let success := delegatecall(
                gas(), // pass all remaining native gas
                addr,
                add(MEM_OFFSET(), argsOffset),
                argsSize,
                0,
                0
            )
        
            let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET(), retOffset), retSize)
            if iszero(success) {
                resetEvmFrame()
            }
        
            newGasLeft := add(evmGasLeft, frameGasLeft)
            stackHead := success
        }
        
        function _genericCall(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
            switch isEvmContract(addr)
            case 0 {
                // zkEVM native call
                let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
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
                pushEvmFrame(gasToPass, isStatic)
                // pass all remaining native gas
                success := call(gas(), addr, value, argsOffset, argsSize, 0, 0)
                frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
                if iszero(success) {
                    resetEvmFrame()
                }
            }
        }
        
        function callPrecompile(addr, precompileCost, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
            let zkVmGasToPass := gas() // pass all remaining gas, precompiles should not call any contracts
            if lt(gasToPass, precompileCost) {
                zkVmGasToPass := 0  // in EVM precompile should revert consuming all gas in that case
            }
        
            switch isStatic
            case 0 {
                success := call(zkVmGasToPass, addr, value, argsOffset, argsSize, retOffset, retSize)
            }
            default {
                success := staticcall(zkVmGasToPass, addr, argsOffset, argsSize, retOffset, retSize)
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
            let decommitZkVmGasCost := decommitmentCost(addr)
        
            // we are going to charge decommit cost even if address is already warm
            // decommit cost is subtracted from the callee frame
            switch gt(decommitZkVmGasCost, zkEvmGasToPass)
            case 0 {
                zkEvmGasToPass := sub(zkEvmGasToPass, decommitZkVmGasCost)
            }
            default {
                zkEvmGasToPass := 0
            }
        
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
        
        function decommitmentCost(addr) -> cost {
            // charge for contract decommitment
            let byteSize := extcodesize(addr)
            cost := mul(
                div(add(byteSize, 31), 32), // rounding up
                DECOMMIT_COST_PER_WORD()
            ) 
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
        // Take into account MEM_OFFSET() when passing the argsOffset
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
        
            let err := 0
            if value {
                if gt(value, selfbalance()) {
                    err := 1
                }
            }
        
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
            let farCallAbi := shl(248, 1) // system call
            // dataOffset is 0
            farCallAbi :=  or(farCallAbi, shl(64, bytecodeStart))
            farCallAbi :=  or(farCallAbi, shl(96, bytecodeLen))
            farCallAbi :=  or(farCallAbi, shl(192, gas()))
            // shardId is 0
            // forwardingMode is 0
            // not constructor call (ContractDeployer will call constructor)
        
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

        function simulate(
            isCallerEVM,
            evmGasLeft,
            isStatic,
        ) -> returnOffset, returnLen, retGasLeft {

            returnOffset := MEM_OFFSET()
            returnLen := 0

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
            
                    stackHead := calldataload(accessStackHead(sp, stackHead))
            
                    ip := add(ip, 1)
                }
                case 0x36 { // OP_CALLDATASIZE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp, stackHead := pushStackItem(sp, calldatasize(), stackHead)
                    ip := add(ip, 1)
                }
                case 0x37 { // OP_CALLDATACOPY
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let destOffset, offset, size
            
                    popStackCheck(sp, 3)
                    destOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                    offset, sp, stackHead:= popStackItemWithoutCheck(sp, stackHead)
                    size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
            
                    checkMemIsAccessible(destOffset, size)
            
                    if gt(offset, MAX_UINT64()) {
                        offset := MAX_UINT64()
                    } 
            
                    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                    // minimum_word_size = (size + 31) / 32
                    let dynamicGas := add(mul(3, shr(5, add(size, 31))), expandMemory(destOffset, size))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    calldatacopy(add(destOffset, MEM_OFFSET()), offset, size)
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
            
                    sp, stackHead := pushStackItem(sp, sub(ip, BYTECODE_OFFSET()), stackHead)
            
                    ip := add(ip, 1)
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
                case 0x0C { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x0D { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x0E { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x0F { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x1E { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x1F { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x21 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x22 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x23 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x24 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x25 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x26 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x27 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x28 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x29 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2A { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2B { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2C { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2D { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2E { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x2F { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x49 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4A { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4B { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4C { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4D { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4E { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0x4F { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xA5 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xA6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xA7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xA8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xA9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAA { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAD { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAE { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xAF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB0 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB1 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB2 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB3 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB4 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB5 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xB9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBA { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBD { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBE { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xBF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC0 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC1 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC2 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC3 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC4 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC5 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xC9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCA { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCD { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCE { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xCF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD0 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD1 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD2 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD3 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD4 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD5 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xD9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDA { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDD { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDE { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xDF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE0 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE1 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE2 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE3 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE4 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE5 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xE9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xEA { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xEB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xEC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xED { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xEE { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xEF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xF2 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xF6 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xF7 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xF8 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xF9 { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xFB { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xFC { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                case 0xFF { // Unused opcode
                    $llvm_NoInline_llvm$_panic()
                }
                default {
                    $llvm_NoInline_llvm$_panic()
                }
            }
            

            retGasLeft := evmGasLeft
        }

        ////////////////////////////////////////////////////////////////
        //                      FALLBACK
        ////////////////////////////////////////////////////////////////

        pop($llvm_AlwaysInline_llvm$_warmAddress(address()))
        
        let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

        if isStatic {
            abortEvmEnvironment() // should never happen
        }

        getConstructorBytecode()

        if iszero(isCallerEVM) {
            evmGasLeft := getEvmGasFromContext()
        }

        let offset, len, gasToReturn := simulate(isCallerEVM, evmGasLeft, false)

        gasToReturn := validateBytecodeAndChargeGas(offset, len, gasToReturn)

        offset, len := padBytecode(offset, len)

        mstore(add(offset, len), gasToReturn)

        verbatim_2i_0o("return_deployed", offset, add(len, 32))
    }
    object "EvmEmulator_deployed" {
        code {
            function MAX_POSSIBLE_ACTIVE_BYTECODE() -> max {
                max := MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()
            }

            function getDeployedBytecode() {
                let codeLen := fetchDeployedCode(
                    getCodeAddress(), 
                    BYTECODE_OFFSET(), // destination offset
                    0, // source offset
                    MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()
                )
            
                mstore(EMPTY_CODE_OFFSET(), 0)
                mstore(BYTECODE_LEN_OFFSET(), codeLen)
            }

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
            
            function BYTECODE_LEN_OFFSET() -> offset {
                offset := add(STACK_OFFSET(), mul(1024, 32))
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
            // The cost to increase the memory to 4 MB is close to 30M gas
            function MAX_POSSIBLE_MEM_LEN() -> max {
                max := 0x400000 // 4MB
            }
            
            function MAX_MEMORY_SLOT() -> max {
                max := add(MEM_OFFSET(), MAX_POSSIBLE_MEM_LEN())
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
            
            // From precompiles/CodeOracle
            function DECOMMIT_COST_PER_WORD() -> cost { cost := 4 }
            
            function UINT32_MAX() -> ret { ret := 4294967295 } // 2^32 - 1
            
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
            
            function checkMemIsAccessible(index, offset) {
                checkOverflow(index, offset)
            
                if gt(add(index, offset), MAX_MEMORY_SLOT()) {
                    panic()
                }
            }
            
            function checkOverflow(data1, data2) {
                if lt(add(data1, data2), data2) {
                    panic()
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
            
            // Basically performs an extcodecopy, while returning the length of the copied bytecode.
            function fetchDeployedCode(addr, dstOffset, srcOffset, len) -> copiedLen {
                let codeHash := getRawCodeHash(addr)
                mstore(0, codeHash)
                // The first word of returndata is the true length of the bytecode
                let codeLen := fetchFromSystemContract(CODE_ORACLE_SYSTEM_CONTRACT(), 32)
            
                if gt(len, codeLen) {
                    len := codeLen
                }
            
                let shiftedSrcOffset := add(32, srcOffset) // first 32 bits is length
            
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
            
            function performSystemCall(to, dataLength) {
                let success := performSystemCallRevertable(to, dataLength)
            
                if iszero(success) {
                    // This error should never happen
                    abortEvmEnvironment()
                }
            }
            
            function performSystemCallRevertable(to, dataLength) -> success {
                let farCallAbi := shl(248, 1) // system call
                // dataOffset is 0
                // dataStart is 0
                farCallAbi :=  or(farCallAbi, shl(96, dataLength))
                farCallAbi :=  or(farCallAbi, shl(192, gas()))
                // shardId is 0
                // forwardingMode is 0
                // not constructor call
            
                success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            }
            
            ////////////////////////////////////////////////////////////////
            //                     STACK OPERATIONS
            ////////////////////////////////////////////////////////////////
            
            function dupStackItem(sp, evmGas, position, oldStackHead) -> newSp, evmGasLeft, stackHead {
                evmGasLeft := chargeGas(evmGas, 3)
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
                if iszero(lt(sp, BYTECODE_LEN_OFFSET())) {
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
            
            function pushStackCheck(sp, numInputs) {
                if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_LEN_OFFSET())) {
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
            
            function performCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
                let gasToPass, addr, value, argsOffset, argsSize, retOffset, retSize
            
                popStackCheck(oldSp, 7)
                gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
                addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                checkMemIsAccessible(argsOffset, argsSize)
                checkMemIsAccessible(retOffset, retSize)
            
                // static_gas = 0
                // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
                // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
                // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
                // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called.
                // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.
            
                let gasUsed := 100 // warm address access cost
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                    gasUsed := 2600 // cold address access cost
                }
            
                // memory_expansion_cost
                gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
            
                if gt(value, 0) {
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
                    false
                )
            
                newGasLeft := add(evmGasLeft, frameGasLeft)
                stackHead := success
            }
            
            function performStaticCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
                let gasToPass,addr, argsOffset, argsSize, retOffset, retSize
            
                popStackCheck(oldSp, 6)
                gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
                addr, sp, stackHead  := popStackItemWithoutCheck(sp, stackHead)
                argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                checkMemIsAccessible(argsOffset, argsSize)
                checkMemIsAccessible(retOffset, retSize)
            
                let gasUsed := 100 // warm address access cost
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                    gasUsed := 2600 // cold address access cost
                }
            
                // memory_expansion_cost
                gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
            
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
                let addr, gasToPass, argsOffset, argsSize, retOffset, retSize
            
                popStackCheck(oldSp, 6)
                gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
                addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                checkMemIsAccessible(argsOffset, argsSize)
                checkMemIsAccessible(retOffset, retSize)
            
                let gasUsed := 100 // warm address access cost
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                    gasUsed := 2600 // cold address access cost
                }
            
                // memory_expansion_cost
                gasUsed := add(gasUsed, expandMemory2(retOffset, retSize, argsOffset, argsSize))
            
                evmGasLeft := chargeGas(evmGasLeft, gasUsed)
            
                // it is also not possible to delegatecall precompiles
                if iszero(isEvmContract(addr)) {
                    revertWithGas(evmGasLeft)
                }
            
                gasToPass := capGasForCall(evmGasLeft, gasToPass)
                evmGasLeft := sub(evmGasLeft, gasToPass)
            
                pushEvmFrame(gasToPass, isStatic)
                let success := delegatecall(
                    gas(), // pass all remaining native gas
                    addr,
                    add(MEM_OFFSET(), argsOffset),
                    argsSize,
                    0,
                    0
                )
            
                let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET(), retOffset), retSize)
                if iszero(success) {
                    resetEvmFrame()
                }
            
                newGasLeft := add(evmGasLeft, frameGasLeft)
                stackHead := success
            }
            
            function _genericCall(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
                switch isEvmContract(addr)
                case 0 {
                    // zkEVM native call
                    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
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
                    pushEvmFrame(gasToPass, isStatic)
                    // pass all remaining native gas
                    success := call(gas(), addr, value, argsOffset, argsSize, 0, 0)
                    frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
                    if iszero(success) {
                        resetEvmFrame()
                    }
                }
            }
            
            function callPrecompile(addr, precompileCost, gasToPass, value, argsOffset, argsSize, retOffset, retSize, isStatic) -> success, frameGasLeft {
                let zkVmGasToPass := gas() // pass all remaining gas, precompiles should not call any contracts
                if lt(gasToPass, precompileCost) {
                    zkVmGasToPass := 0  // in EVM precompile should revert consuming all gas in that case
                }
            
                switch isStatic
                case 0 {
                    success := call(zkVmGasToPass, addr, value, argsOffset, argsSize, retOffset, retSize)
                }
                default {
                    success := staticcall(zkVmGasToPass, addr, argsOffset, argsSize, retOffset, retSize)
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
                let decommitZkVmGasCost := decommitmentCost(addr)
            
                // we are going to charge decommit cost even if address is already warm
                // decommit cost is subtracted from the callee frame
                switch gt(decommitZkVmGasCost, zkEvmGasToPass)
                case 0 {
                    zkEvmGasToPass := sub(zkEvmGasToPass, decommitZkVmGasCost)
                }
                default {
                    zkEvmGasToPass := 0
                }
            
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
            
            function decommitmentCost(addr) -> cost {
                // charge for contract decommitment
                let byteSize := extcodesize(addr)
                cost := mul(
                    div(add(byteSize, 31), 32), // rounding up
                    DECOMMIT_COST_PER_WORD()
                ) 
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
            // Take into account MEM_OFFSET() when passing the argsOffset
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
            
                let err := 0
                if value {
                    if gt(value, selfbalance()) {
                        err := 1
                    }
                }
            
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
                let farCallAbi := shl(248, 1) // system call
                // dataOffset is 0
                farCallAbi :=  or(farCallAbi, shl(64, bytecodeStart))
                farCallAbi :=  or(farCallAbi, shl(96, bytecodeLen))
                farCallAbi :=  or(farCallAbi, shl(192, gas()))
                // shardId is 0
                // forwardingMode is 0
                // not constructor call (ContractDeployer will call constructor)
            
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

            function $llvm_NoInline_llvm$_simulate(
                isCallerEVM,
                evmGasLeft,
                isStatic,
            ) -> returnOffset, returnLen {

                returnOffset := MEM_OFFSET()
                returnLen := 0

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
                
                        stackHead := calldataload(accessStackHead(sp, stackHead))
                
                        ip := add(ip, 1)
                    }
                    case 0x36 { // OP_CALLDATASIZE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp, stackHead := pushStackItem(sp, calldatasize(), stackHead)
                        ip := add(ip, 1)
                    }
                    case 0x37 { // OP_CALLDATACOPY
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let destOffset, offset, size
                
                        popStackCheck(sp, 3)
                        destOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                        offset, sp, stackHead:= popStackItemWithoutCheck(sp, stackHead)
                        size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
                
                        checkMemIsAccessible(destOffset, size)
                
                        if gt(offset, MAX_UINT64()) {
                            offset := MAX_UINT64()
                        } 
                
                        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                        // minimum_word_size = (size + 31) / 32
                        let dynamicGas := add(mul(3, shr(5, add(size, 31))), expandMemory(destOffset, size))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        calldatacopy(add(destOffset, MEM_OFFSET()), offset, size)
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
                
                        sp, stackHead := pushStackItem(sp, sub(ip, BYTECODE_OFFSET()), stackHead)
                
                        ip := add(ip, 1)
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
                    case 0x0C { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x0D { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x0E { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x0F { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x1E { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x1F { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x21 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x22 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x23 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x24 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x25 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x26 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x27 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x28 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x29 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2A { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2B { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2C { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2D { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2E { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x2F { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x49 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4A { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4B { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4C { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4D { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4E { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0x4F { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xA5 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xA6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xA7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xA8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xA9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAA { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAD { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAE { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xAF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB0 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB1 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB2 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB3 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB4 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB5 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xB9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBA { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBD { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBE { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xBF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC0 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC1 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC2 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC3 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC4 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC5 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xC9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCA { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCD { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCE { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xCF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD0 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD1 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD2 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD3 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD4 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD5 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xD9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDA { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDD { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDE { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xDF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE0 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE1 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE2 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE3 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE4 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE5 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xE9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xEA { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xEB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xEC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xED { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xEE { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xEF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xF2 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xF6 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xF7 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xF8 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xF9 { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xFB { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xFC { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    case 0xFF { // Unused opcode
                        $llvm_NoInline_llvm$_panic()
                    }
                    default {
                        $llvm_NoInline_llvm$_panic()
                    }
                }
                

                if eq(isCallerEVM, 1) {
                    // Includes gas
                    returnOffset := sub(returnOffset, 32)
                    checkOverflow(returnLen, 32)
                    returnLen := add(returnLen, 32)

                    mstore(returnOffset, evmGasLeft)
                }
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            if iszero(isCallerEVM) {
                evmGasLeft := getEvmGasFromContext()
                isStatic := getIsStaticFromCallFlags()
            }

            // First, copy the contract's bytecode to be executed into the `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

            let returnOffset, returnLen := $llvm_NoInline_llvm$_simulate(isCallerEVM, evmGasLeft, isStatic)
            return(returnOffset, returnLen)
        }
    }
}
