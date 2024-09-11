object "EVMInterpreter" {
    code {
        /// @dev This function is used to get the initCode.
        /// @dev It assumes that the initCode has been passed via the calldata and so we use the pointer
        /// to obtain the bytecode.
        function getConstructorBytecode() {
            let bytecodeLengthOffset := BYTECODE_OFFSET()
            let bytecodeOffset := add(BYTECODE_OFFSET(), 32)

            loadCalldataIntoActivePtr()

            let size := getActivePtrDataSize()
            mstore(bytecodeLengthOffset, size)

            copyActivePtrData(bytecodeOffset, 0, size)
        }

        // Note that this function modifies EVM memory and does not restore it. It is expected that
        // it is the last called function during execution.
        function setDeployedCode(gasLeft, offset, len) {
            // This error should never be triggered
            // require(offset > 100, "Offset too small");

            mstore(sub(offset, 100), 0xD9EB76B200000000000000000000000000000000000000000000000000000000)
            mstore(sub(offset, 96), gasLeft)
            mstore(sub(offset, 64), 0x40)
            mstore(sub(offset, 32), len)

            let farCallAbi := getFarCallABI(
                0,
                0,
                sub(offset, 100),
                add(len, 100),
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
            let to := DEPLOYER_SYSTEM_CONTRACT()
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
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

        function validateCorrectBytecode(offset, len, gasToReturn) -> returnGas {
            if len {
                let firstByte := shr(248, mload(offset))
                if eq(firstByte, 0xEF) {
                    revert(0, 0)
                }
            }

            let gasForCode := mul(len, 200)
            returnGas := chargeGas(gasToReturn, gasForCode)
        }

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
                revertWithGas(evmGasLeft)
            }
        
            if lt(tempSp, STACK_OFFSET()) {
                revertWithGas(evmGasLeft)
            }
        
            let dup := mload(tempSp)                    
        
            newSp := add(sp, 0x20)
            mstore(newSp, dup)
        }
        
        function swapStackItem(sp, evmGas, position) ->  evmGasLeft {
            evmGasLeft := chargeGas(evmGas, 3)
            let tempSp := sub(sp, mul(0x20, position))
        
            if or(gt(tempSp, BYTECODE_OFFSET()), eq(tempSp, BYTECODE_OFFSET())) {
                revertWithGas(evmGasLeft)
            }
        
            if lt(tempSp, STACK_OFFSET()) {
                revertWithGas(evmGasLeft)
            }
        
        
            let s2 := mload(sp)
            let s1 := mload(tempSp)                    
        
            mstore(sp, s1)
            mstore(tempSp, s2)
        }
        
        function popStackItem(sp, evmGasLeft) -> a, newSp {
            // We can not return any error here, because it would break compatibility
            if lt(sp, STACK_OFFSET()) {
                revertWithGas(evmGasLeft)
            }
        
            a := mload(sp)
            newSp := sub(sp, 0x20)
        }
        
        function pushStackItem(sp, item, evmGasLeft) -> newSp {
            if or(gt(sp, BYTECODE_OFFSET()), eq(sp, BYTECODE_OFFSET())) {
                revertWithGas(evmGasLeft)
            }
        
            newSp := add(sp, 0x20)
            mstore(newSp, item)
        }
        
        function popStackItemWithoutCheck(sp) -> a, newSp {
            a := mload(sp)
            newSp := sub(sp, 0x20)
        }
        
        function pushStackItemWithoutCheck(sp, item) -> newSp {
            newSp := add(sp, 0x20)
            mstore(newSp, item)
        }
        
        function popStackCheck(sp, evmGasLeft, numInputs) {
            if lt(sub(sp, mul(0x20, sub(numInputs, 1))), STACK_OFFSET()) {
                revertWithGas(evmGasLeft)
            }
        }
        
        function pushStackCheck(sp, evmGasLeft, numInputs) {
            if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_OFFSET())) {
                revertWithGas(evmGasLeft)
            }
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
            mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
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
            mstore(0, 0xE03FE17700000000000000000000000000000000000000000000000000000000)
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
            isStatic := iszero(iszero(and(isStatic, 0x04)))
        }
        
        // Basically performs an extcodecopy, while returning the length of the bytecode.
        function _fetchDeployedCode(addr, _offset, _len) -> codeLen {
            codeLen := _fetchDeployedCodeWithDest(addr, 0, _len, _offset)
        }
        
        // Basically performs an extcodecopy, while returning the length of the bytecode.
        function _fetchDeployedCodeWithDest(addr, _offset, _len, dest) -> codeLen {
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
        
            returndatacopy(dest, add(32,_offset), _len)
        }
        
        // Returns the length of the bytecode.
        function _fetchDeployedCodeLen(addr) -> codeLen {
            let codeHash := _getRawCodeHash(addr)
        
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
            mstore(0, 0x04C14E9E00000000000000000000000000000000000000000000000000000000)
        
            let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                4,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
            let to := EVM_GAS_MANAGER_CONTRACT()
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        
            if iszero(success) {
                // Should never happen
                revert(0, 0)
            }
        
            returndatacopy(0,0,64)
        
            passGas := mload(0)
            isStatic := mload(32)
        
            if iszero(eq(passGas, INF_PASS_GAS())) {
                callerEVM := true
            }
        }
        
        function chargeGas(prevGas, toCharge) -> gasRemaining {
            if lt(prevGas, toCharge) {
                revertWithGas(0)
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
        // Take into account MEM_OFFSET_INNER() when passing the argsOffset
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
        
        function checkMemOverflowByOffset(offset, evmGasLeft) {
            if gt(offset, MAX_POSSIBLE_MEM()) {
                mstore(0, evmGasLeft)
                revert(0, 32)
            }
        }
        
        function checkMemOverflow(location, evmGasLeft) {
            if gt(location, MAX_MEMORY_FRAME()) {
                mstore(0, evmGasLeft)
                revert(0, 32)
            }
        }
        
        function checkMultipleOverflow(data1, data2, data3, evmGasLeft) {
            checkOverflow(data1, data2, evmGasLeft)
            checkOverflow(data1, data3, evmGasLeft)
            checkOverflow(data2, data3, evmGasLeft)
            checkOverflow(add(data1, data2), data3, evmGasLeft)
        }
        
        function checkOverflow(data1, data2, evmGasLeft) {
            if lt(add(data1, data2), data2) {
                revertWithGas(evmGasLeft)
            }
        }
        
        function revertWithGas(evmGasLeft) {
            mstore(0, evmGasLeft)
            revert(0, 32)
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
            mstore(0, 0x482D2E7400000000000000000000000000000000000000000000000000000000)
            mstore(4, key)
        
            let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 36, 0, 32)
        
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        
            isWarm := mload(0)
        }
        
        function warmSlot(key,currentValue) -> isWarm, originalValue {
            mstore(0, 0xBDF7816000000000000000000000000000000000000000000000000000000000)
            mstore(4, key)
            mstore(36,currentValue)
        
            let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                68,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
            let to := EVM_GAS_MANAGER_CONTRACT()
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        
            returndatacopy(0, 0, 64)
        
            isWarm := mload(0)
            originalValue := mload(32)
        }
        
        function MAX_SYSTEM_CONTRACT_ADDR() -> ret {
            ret := 0x000000000000000000000000000000000000ffff
        }
        
        /// @dev Checks whether an address is an EOA (i.e. has not code deployed on it)
        /// @param addr The address to check
        function isEOA(addr) -> ret {
            ret := 0
            if gt(addr, MAX_SYSTEM_CONTRACT_ADDR()) {
                ret := iszero(_getRawCodeHash(addr))
            }
        }
        
        function incrementNonce(addr) {
            mstore(0, 0x306395C600000000000000000000000000000000000000000000000000000000)
            mstore(4, addr)
        
            let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                36,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
            let to := NONCE_HOLDER_SYSTEM_CONTRACT()
            let result := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        
            if iszero(result) {
                revert(0, 0)
            }
        } 
        
        function getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        ) -> ret {
            let farCallAbi := 0
            farCallAbi :=  or(farCallAbi, dataOffset)
            farCallAbi :=  or(farCallAbi, shl(64, dataStart))
            farCallAbi :=  or(farCallAbi, shl(96, dataLength))
            farCallAbi :=  or(farCallAbi, shl(192, gasPassed))
            farCallAbi :=  or(farCallAbi, shl(224, shardId))
            farCallAbi :=  or(farCallAbi, shl(232, forwardingMode))
            farCallAbi :=  or(farCallAbi, shl(248, 1))
            ret := farCallAbi
        }
        
        function ensureAcceptableMemLocation(location) {
            if gt(location,MAX_POSSIBLE_MEM()) {
                revert(0,0) // Check if this is what's needed
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
        
        function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
            mstore(0, 0x8DB2BA7800000000000000000000000000000000000000000000000000000000)
            mstore(4, addr)
        
            let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                36,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
            let to := EVM_GAS_MANAGER_CONTRACT()
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        
            returndatacopy(0, 0, 32)
            isWarm := mload(0)
        }
        
        function getRawNonce(addr) -> nonce {
            mstore(0, 0x5AA9B6B500000000000000000000000000000000000000000000000000000000)
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
        
            mstore(0, 0x8C04047700000000000000000000000000000000000000000000000000000000)
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
        
            mstore(0, 0xEAD7715600000000000000000000000000000000000000000000000000000000)
            mstore(4, _passGas)
            mstore(36, _isStatic)
        
            let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                68,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
        
            let to := EVM_GAS_MANAGER_CONTRACT()
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
        
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
        
        function _popEVMFrame() {
            // function popEVMFrame() external
        
             let farCallAbi := getFarCallABI(
                0,
                0,
                0,
                4,
                gas(),
                // Only rollup is supported for now
                0,
                0,
                0,
                1
            )
        
            let to := EVM_GAS_MANAGER_CONTRACT()
        
            mstore(0, 0xE467D2F000000000000000000000000000000000000000000000000000000000)
        
            let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
        
        // Each evm gas is 5 zkEVM one
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
        
            switch lt(_gas, requiredGas)
            case 1 {
                evmGas := 0
            }
            default {
                evmGas := div(sub(_gas, requiredGas), GAS_DIVISOR())
            }
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
        
                    // We copy as much returndata as possible without going over the 
                    // returndata size.
                    switch lt(sub(rtsz, 32), _outputLen)
                        case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                        default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }
        
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
        
            popStackCheck(oldSp, evmGasLeft, 6)
            gasToPass, sp := popStackItemWithoutCheck(oldSp)
            addr, sp := popStackItemWithoutCheck(sp)
            argsOffset, sp := popStackItemWithoutCheck(sp)
            argsSize, sp := popStackItemWithoutCheck(sp)
            retOffset, sp := popStackItemWithoutCheck(sp)
            retSize, sp := popStackItemWithoutCheck(sp)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            checkOverflow(argsOffset,argsSize, evmGasLeft)
            checkOverflow(retOffset, retSize, evmGasLeft)
        
            checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
            checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)
        
            extraCost := 0
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
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
            switch _isEVM(addr)
            case 0 {
                // zkEVM native
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
            default {
                _pushEVMFrame(gasToPass, true)
                success := staticcall(gasToPass, addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, 0, 0)
        
                frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
                _popEVMFrame()
            }
        
            let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
            switch iszero(precompileCost)
            case 1 {
                extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
            }
            default {
                extraCost := add(extraCost, precompileCost)
            }
        
            sp := pushStackItem(sp, success, evmGasLeft)
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
        
            switch isStatic
            case 0 {
                switch is_evm
                case 0 {
                    // zkEVM native
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
                default {
                    _pushEVMFrame(gasToPassNew, isStatic)
                    success := call(EVM_GAS_STIPEND(), addr, value, argsOffset, argsSize, 0, 0)
                    frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
                    _popEVMFrame()
                }
            }
            default {
                if value {
                    revertWithGas(gasToPassNew)
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
        }
        
        function performCall(oldSp, evmGasLeft, isStatic) -> extraCost, sp {
            let gasToPass,addr,value,argsOffset,argsSize,retOffset,retSize
        
            popStackCheck(oldSp, evmGasLeft, 7)
            gasToPass, sp := popStackItemWithoutCheck(oldSp)
            addr, sp := popStackItemWithoutCheck(sp)
            value, sp := popStackItemWithoutCheck(sp)
            argsOffset, sp := popStackItemWithoutCheck(sp)
            argsSize, sp := popStackItemWithoutCheck(sp)
            retOffset, sp := popStackItemWithoutCheck(sp)
            retSize, sp := popStackItemWithoutCheck(sp)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            // static_gas = 0
            // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
            // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
            // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
            // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called. 2300 is thus removed from the cost, and also added to the gas input.
            // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.
        
            extraCost := 0
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
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
        
            checkOverflow(argsOffset,argsSize, evmGasLeft)
            checkOverflow(retOffset,retSize, evmGasLeft)
        
            checkMemOverflow(add(argsOffset, argsSize), evmGasLeft)
            checkMemOverflow(add(retOffset, retSize), evmGasLeft)
        
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
        
            let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
            switch iszero(precompileCost)
            case 1 {
                extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
            }
            default {
                extraCost := add(extraCost, precompileCost)
            }
            sp := pushStackItem(sp,success, evmGasLeft) 
        }
        
        function delegateCall(oldSp, oldIsStatic, evmGasLeft) -> sp, isStatic, extraCost {
            let addr, gasToPass, argsOffset, argsSize, retOffset, retSize
        
            sp := oldSp
            isStatic := oldIsStatic
        
            popStackCheck(sp, evmGasLeft, 6)
            gasToPass, sp := popStackItemWithoutCheck(sp)
            addr, sp := popStackItemWithoutCheck(sp)
            argsOffset, sp := popStackItemWithoutCheck(sp)
            argsSize, sp := popStackItemWithoutCheck(sp)
            retOffset, sp := popStackItemWithoutCheck(sp)
            retSize, sp := popStackItemWithoutCheck(sp)
        
            addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
        
            checkOverflow(argsOffset, argsSize, evmGasLeft)
            checkOverflow(retOffset, retSize, evmGasLeft)
        
            checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
            checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)
        
            if iszero(_isEVM(addr)) {
                revertWithGas(evmGasLeft)
            }
        
            extraCost := 0
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                extraCost := 2500
            }
        
            {
                let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
                extraCost := add(extraCost,maxExpand)
            }
            gasToPass := capGas(evmGasLeft,gasToPass)
        
            _pushEVMFrame(gasToPass, isStatic)
            let success := delegatecall(
                // We can not just pass all gas here to prevent overflow of zkEVM gas counter
                EVM_GAS_STIPEND(),
                addr,
                add(MEM_OFFSET_INNER(), argsOffset),
                argsSize,
                0,
                0
            )
        
            let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
        
            _popEVMFrame()
        
            let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
            switch iszero(precompileCost)
            case 1 {
                extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
            }
            default {
                extraCost := add(extraCost, precompileCost)
            }
            sp := pushStackItem(sp, success, evmGasLeft)
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
            switch _calleeIsEVM
            case 0 {
                // zkEVM native
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
            default {
                _pushEVMFrame(_calleeGas, true)
                success := staticcall(EVM_GAS_STIPEND(), _callee, _inputOffset, _inputLen, 0, 0)
        
                _gasLeft := _saveReturndataAfterEVMCall(_outputOffset, _outputLen)
                _popEVMFrame()
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
            mstore(0, 0x24E5AB4A00000000000000000000000000000000000000000000000000000000)
        
            let success := staticcall(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, 4, 0, 32)
        
            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        
            gasLeft := mload(0)
        }
        
        function $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeftOld, isCreate2, salt) -> result, evmGasLeft, addr {
            pop($llvm_AlwaysInline_llvm$_warmAddress(addr))
        
            _eraseReturndataPointer()
        
            let gasForTheCall := capGas(evmGasLeftOld,INF_PASS_GAS())
        
            if lt(selfbalance(),value) {
                revertWithGas(evmGasLeftOld)
            }
        
            offset := add(MEM_OFFSET_INNER(), offset)
        
            pushStackCheck(sp, evmGasLeftOld, 4)
            sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x80)))
            sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x60)))
            sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x40)))
            sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x20)))
        
            _pushEVMFrame(gasForTheCall, false)
        
            if isCreate2 {
                // Create2EVM selector
                mstore(sub(offset, 0x80), 0x4e96f4c0)
                // salt
                mstore(sub(offset, 0x60), salt)
                // Where the arg starts (third word)
                mstore(sub(offset, 0x40), 0x40)
                // Length of the init code
                mstore(sub(offset, 0x20), size)
        
        
                result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x64), add(size, 0x64), 0, 32)
            }
        
        
            if iszero(isCreate2) {
                // CreateEVM selector
                mstore(sub(offset, 0x60), 0xff311601)
                // Where the arg starts (second word)
                mstore(sub(offset, 0x40), 0x20)
                // Length of the init code
                mstore(sub(offset, 0x20), size)
        
        
                result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x44), add(size, 0x44), 0, 32)
            }
        
            addr := mload(0)
        
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
        
            let back
        
            // skipping check since we pushed exactly 4 items earlier
            back, sp := popStackItemWithoutCheck(sp)
            mstore(sub(offset, 0x20), back)
            back, sp := popStackItemWithoutCheck(sp)
            mstore(sub(offset, 0x40), back)
            back, sp := popStackItemWithoutCheck(sp)
            mstore(sub(offset, 0x60), back)
            back, sp := popStackItemWithoutCheck(sp)
            mstore(sub(offset, 0x80), back)
        }
        
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
        
        function performExtCodeCopy(evmGas,oldSp) -> evmGasLeft, sp {
            evmGasLeft := chargeGas(evmGas, 100)
        
            let addr, dest, offset, len
            popStackCheck(oldSp, evmGasLeft, 4)
            addr, sp := popStackItemWithoutCheck(oldSp)
            dest, sp := popStackItemWithoutCheck(sp)
            offset, sp := popStackItemWithoutCheck(sp)
            len, sp := popStackItemWithoutCheck(sp)
        
            // dynamicGas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
            // minimum_word_size = (size + 31) / 32
        
            let dynamicGas := add(
                mul(3, shr(5, add(len, 31))),
                expandMemory(add(dest, len))
            )
            if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                dynamicGas := add(dynamicGas, 2500)
            }
            evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
        
            $llvm_AlwaysInline_llvm$_memsetToZero(dest, len)
        
            // Gets the code from the addr
            if and(iszero(iszero(_getRawCodeHash(addr))),gt(len,0)) {
                pop(_fetchDeployedCodeWithDest(addr, offset, len,add(dest,MEM_OFFSET_INNER())))  
            }
        }
        
        function performCreate(evmGas,oldSp,isStatic) -> evmGasLeft, sp {
            evmGasLeft := chargeGas(evmGas, 32000)
        
            if isStatic {
                revertWithGas(evmGasLeft)
            }
        
            let value, offset, size
        
            popStackCheck(oldSp, evmGasLeft, 3)
            value, sp := popStackItemWithoutCheck(oldSp)
            offset, sp := popStackItemWithoutCheck(sp)
            size, sp := popStackItemWithoutCheck(sp)
        
            checkOverflow(offset, size, evmGasLeft)
            checkMemOverflowByOffset(add(offset, size), evmGasLeft)
        
            if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
                revertWithGas(evmGasLeft)
            }
        
            if gt(value, balance(address())) {
                revertWithGas(evmGasLeft)
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
        
            let result, addr
            result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft, false, 0)
        
            switch result
                case 0 { sp := pushStackItem(sp, 0, evmGasLeft) }
                default { sp := pushStackItem(sp, addr, evmGasLeft) }
        }
        
        function performCreate2(evmGas, oldSp, isStatic) -> evmGasLeft, sp, result, addr{
            evmGasLeft := chargeGas(evmGas, 32000)
        
            if isStatic {
                revertWithGas(evmGasLeft)
            }
        
            let value, offset, size, salt
        
            popStackCheck(oldSp, evmGasLeft, 4)
            value, sp := popStackItemWithoutCheck(oldSp)
            offset, sp := popStackItemWithoutCheck(sp)
            size, sp := popStackItemWithoutCheck(sp)
            salt, sp := popStackItemWithoutCheck(sp)
        
            checkOverflow(offset, size, evmGasLeft)
            checkMemOverflowByOffset(add(offset, size), evmGasLeft)
        
            if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
                revertWithGas(evmGasLeft)
            }
        
            if gt(value, balance(address())) {
                revertWithGas(evmGasLeft)
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
        
            result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft,true,salt)
        }
        

        function simulate(
            isCallerEVM,
            evmGasLeft,
            isStatic,
        ) -> returnOffset, returnLen, retGasLeft {

            returnOffset := MEM_OFFSET_INNER()
            returnLen := 0

            // stack pointer - index to first stack element; empty stack = -1
            let sp := sub(STACK_OFFSET(), 32)
            // instruction pointer - index to next instruction. Not called pc because it's an
            // actual yul/evm instruction.
            let ip := add(BYTECODE_OFFSET(), 32)
            let opcode
            
            let maxAcceptablePos := add(add(BYTECODE_OFFSET(), mload(BYTECODE_OFFSET())), 31)
            
            for { } true { } {
                opcode := readIP(ip,maxAcceptablePos)
            
                switch opcode
                case 0x00 { // OP_STOP
                    break
                }
                case 0x01 { // OP_ADD
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, add(a, b))
                    ip := add(ip, 1)
                }
                case 0x02 { // OP_MUL
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, mul(a, b))
                    ip := add(ip, 1)
                }
                case 0x03 { // OP_SUB
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, sub(a, b))
                    ip := add(ip, 1)
                }
                case 0x04 { // OP_DIV
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, div(a, b))
                    ip := add(ip, 1)
                }
                case 0x05 { // OP_SDIV
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, sdiv(a, b))
                    ip := add(ip, 1)
                }
                case 0x06 { // OP_MOD
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, mod(a, b))
                    ip := add(ip, 1)
                }
                case 0x07 { // OP_SMOD
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, smod(a, b))
                    ip := add(ip, 1)
                }
                case 0x08 { // OP_ADDMOD
                    evmGasLeft := chargeGas(evmGasLeft, 8)
            
                    let a, b, N
            
                    popStackCheck(sp, evmGasLeft, 3)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
                    N, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, addmod(a, b, N))
                    ip := add(ip, 1)
                }
                case 0x09 { // OP_MULMOD
                    evmGasLeft := chargeGas(evmGasLeft, 8)
            
                    let a, b, N
            
                    popStackCheck(sp, evmGasLeft, 3)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
                    N, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItem(sp, mulmod(a, b, N), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x0A { // OP_EXP
                    evmGasLeft := chargeGas(evmGasLeft, 10)
            
                    let a, exponent
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    exponent, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, exp(a, exponent))
            
                    let to_charge := 0
                    for {} gt(exponent,0) {} { // while exponent > 0
                        to_charge := add(to_charge, 50)
                        exponent := shr(8, exponent)
                    } 
                    evmGasLeft := chargeGas(evmGasLeft, to_charge)
                    ip := add(ip, 1)
                }
                case 0x0B { // OP_SIGNEXTEND
                    evmGasLeft := chargeGas(evmGasLeft, 5)
            
                    let b, x
            
                    popStackCheck(sp, evmGasLeft, 2)
                    b, sp := popStackItemWithoutCheck(sp)
                    x, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, signextend(b, x))
                    ip := add(ip, 1)
                }
                case 0x10 { // OP_LT
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, lt(a, b))
                    ip := add(ip, 1)
                }
                case 0x11 { // OP_GT
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, gt(a, b))
                    ip := add(ip, 1)
                }
                case 0x12 { // OP_SLT
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, slt(a, b))
                    ip := add(ip, 1)
                }
                case 0x13 { // OP_SGT
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, sgt(a, b))
                    ip := add(ip, 1)
                }
                case 0x14 { // OP_EQ
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, eq(a, b))
                    ip := add(ip, 1)
                }
                case 0x15 { // OP_ISZERO
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a
            
                    popStackCheck(sp, evmGasLeft, 1)
                    a, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, iszero(a))
                    ip := add(ip, 1)
                }
                case 0x16 { // OP_AND
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, and(a,b))
                    ip := add(ip, 1)
                }
                case 0x17 { // OP_OR
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, or(a,b))
                    ip := add(ip, 1)
                }
                case 0x18 { // OP_XOR
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    a, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, xor(a, b))
                    ip := add(ip, 1)
                }
                case 0x19 { // OP_NOT
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let a
            
                    popStackCheck(sp, evmGasLeft, 1)
                    a, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, not(a))
                    ip := add(ip, 1)
                }
                case 0x1A { // OP_BYTE
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let i, x
            
                    popStackCheck(sp, evmGasLeft, 2)
                    i, sp := popStackItemWithoutCheck(sp)
                    x, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, byte(i, x))
                    ip := add(ip, 1)
                }
                case 0x1B { // OP_SHL
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let shift, value
            
                    popStackCheck(sp, evmGasLeft, 2)
                    shift, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, shl(shift, value))
                    ip := add(ip, 1)
                }
                case 0x1C { // OP_SHR
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let shift, value
            
                    popStackCheck(sp, evmGasLeft, 2)
                    shift, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, shr(shift, value))
                    ip := add(ip, 1)
                }
                case 0x1D { // OP_SAR
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let shift, value
            
                    popStackCheck(sp, evmGasLeft, 2)
                    shift, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, sar(shift, value))
                    ip := add(ip, 1)
                }
                case 0x20 { // OP_KECCAK256
                    evmGasLeft := chargeGas(evmGasLeft, 30)
            
                    let offset, size
            
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                    let keccak := keccak256(add(MEM_OFFSET_INNER(), offset), size)
            
                    // When an offset is first accessed (either read or write), memory may trigger 
                    // an expansion, which costs gas.
                    // dynamicGas = 6 * minimum_word_size + memory_expansion_cost
                    // minimum_word_size = (size + 31) / 32
                    let dynamicGas := add(mul(6, shr(5, add(size, 31))), expandMemory(add(offset, size)))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    sp := pushStackItem(sp, keccak, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x30 { // OP_ADDRESS
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, address(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x31 { // OP_BALANCE
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let addr
            
                    addr, sp := popStackItem(sp, evmGasLeft)
                    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                        evmGasLeft := chargeGas(evmGasLeft, 2500)
                    }
            
                    sp := pushStackItemWithoutCheck(sp, balance(addr))
                    ip := add(ip, 1)
                }
                case 0x32 { // OP_ORIGIN
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, origin(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x33 { // OP_CALLER
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, caller(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x34 { // OP_CALLVALUE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, callvalue(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x35 { // OP_CALLDATALOAD
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let i
            
                    popStackCheck(sp, evmGasLeft, 1)
                    i, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, calldataload(i))
                    ip := add(ip, 1)
                }
                case 0x36 { // OP_CALLDATASIZE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, calldatasize(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x37 { // OP_CALLDATACOPY
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let destOffset, offset, size
            
                    popStackCheck(sp, evmGasLeft, 3)
                    destOffset, sp := popStackItemWithoutCheck(sp)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkMultipleOverflow(offset,size,MEM_OFFSET_INNER(), evmGasLeft)
                    checkMultipleOverflow(destOffset,size,MEM_OFFSET_INNER(), evmGasLeft)
            
                    // TODO invalid?
                    if or(gt(add(add(offset, size), MEM_OFFSET_INNER()), MAX_POSSIBLE_MEM()), gt(add(add(destOffset, size), MEM_OFFSET_INNER()), MAX_POSSIBLE_MEM())) {
                        $llvm_AlwaysInline_llvm$_memsetToZero(add(destOffset, MEM_OFFSET_INNER()), size)
                    }
            
                    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                    // minimum_word_size = (size + 31) / 32
                    let dynamicGas := add(mul(3, shr(5, add(size, 31))), expandMemory(add(destOffset, size)))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    calldatacopy(add(destOffset, MEM_OFFSET_INNER()), offset, size)
                    ip := add(ip, 1)
                    
                }
                case 0x38 { // OP_CODESIZE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    let bytecodeLen := mload(BYTECODE_OFFSET())
                    sp := pushStackItem(sp, bytecodeLen, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x39 { // OP_CODECOPY
                
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let dst, offset, len
            
                    popStackCheck(sp, evmGasLeft, 3)
                    dst, sp := popStackItemWithoutCheck(sp)
                    offset, sp := popStackItemWithoutCheck(sp)
                    len, sp := popStackItemWithoutCheck(sp)
            
                    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                    // minimum_word_size = (size + 31) / 32
                    let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(add(dst, len)))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    dst := add(dst, MEM_OFFSET_INNER())
                    offset := add(add(offset, BYTECODE_OFFSET()), 32)
            
                    checkOverflow(dst,len, evmGasLeft)
                    checkMemOverflow(add(dst, len), evmGasLeft)
                    // Check bytecode overflow
                    if gt(add(offset, len), sub(MEM_OFFSET(), 1)) {
                        revertWithGas(evmGasLeft)
                    }
            
                    $llvm_AlwaysInline_llvm$_memcpy(dst, offset, len)
                    ip := add(ip, 1)
                }
                case 0x3A { // OP_GASPRICE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, gasprice(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x3B { // OP_EXTCODESIZE
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let addr
                    addr, sp := popStackItem(sp, evmGasLeft)
            
                    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
                    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                        evmGasLeft := chargeGas(evmGasLeft, 2500)
                    }
            
                    switch _isEVM(addr) 
                        case 0  { sp := pushStackItemWithoutCheck(sp, extcodesize(addr)) }
                        default { sp := pushStackItemWithoutCheck(sp, _fetchDeployedCodeLen(addr)) }
                    ip := add(ip, 1)
                }
                case 0x3C { // OP_EXTCODECOPY
                    evmGasLeft, sp := performExtCodeCopy(evmGasLeft, sp)
                    ip := add(ip, 1)
                }
                case 0x3D { // OP_RETURNDATASIZE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    let rdz := mload(LAST_RETURNDATA_SIZE_OFFSET())
                    sp := pushStackItem(sp, rdz, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x3E { // OP_RETURNDATACOPY
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let dest, offset, len
                    popStackCheck(sp, evmGasLeft, 3)
                    dest, sp := popStackItemWithoutCheck(sp)
                    offset, sp := popStackItemWithoutCheck(sp)
                    len, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset,len, evmGasLeft)
                    if gt(add(offset, len), mload(LAST_RETURNDATA_SIZE_OFFSET())) {
                        revertWithGas(evmGasLeft)
                    }
            
                    // minimum_word_size = (size + 31) / 32
                    // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                    checkMemOverflowByOffset(offset, evmGasLeft)
                    let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(add(dest, len)))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    copyActivePtrData(add(MEM_OFFSET_INNER(), dest), offset, len)
                    ip := add(ip, 1)
                }
                case 0x3F { // OP_EXTCODEHASH
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let addr
                    addr, sp := popStackItem(sp, evmGasLeft)
                    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                        evmGasLeft := chargeGas(evmGasLeft, 2500) 
                    }
            
                    ip := add(ip, 1)
                    if iszero(addr) {
                        sp := pushStackItemWithoutCheck(sp, 0)
                        continue
                    }
                    sp := pushStackItemWithoutCheck(sp, extcodehash(addr))
                }
                case 0x40 { // OP_BLOCKHASH
                    evmGasLeft := chargeGas(evmGasLeft, 20)
            
                    let blockNumber
                    popStackCheck(sp, evmGasLeft, 1)
                    blockNumber, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, blockhash(blockNumber))
                    ip := add(ip, 1)
                }
                case 0x41 { // OP_COINBASE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, coinbase(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x42 { // OP_TIMESTAMP
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, timestamp(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x43 { // OP_NUMBER
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, number(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x44 { // OP_PREVRANDAO
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, prevrandao(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x45 { // OP_GASLIMIT
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, gaslimit(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x46 { // OP_CHAINID
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, chainid(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x47 { // OP_SELFBALANCE
                    evmGasLeft := chargeGas(evmGasLeft, 5)
                    sp := pushStackItem(sp, selfbalance(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x48 { // OP_BASEFEE
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    sp := pushStackItem(sp, basefee(), evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x50 { // OP_POP
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    let _y
            
                    _y, sp := popStackItem(sp, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x51 { // OP_MLOAD
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let offset
            
                    offset, sp := popStackItem(sp, evmGasLeft)
            
                    checkMemOverflowByOffset(offset, evmGasLeft)
                    let expansionGas := expandMemory(add(offset, 32))
                    evmGasLeft := chargeGas(evmGasLeft, expansionGas)
            
                    let memValue := mload(add(MEM_OFFSET_INNER(), offset))
                    sp := pushStackItemWithoutCheck(sp, memValue)
                    ip := add(ip, 1)
                }
                case 0x52 { // OP_MSTORE
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let offset, value
            
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    checkMemOverflowByOffset(offset, evmGasLeft)
                    let expansionGas := expandMemory(add(offset, 32))
                    evmGasLeft := chargeGas(evmGasLeft, expansionGas)
            
                    mstore(add(MEM_OFFSET_INNER(), offset), value)
                    ip := add(ip, 1)
                }
                case 0x53 { // OP_MSTORE8
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    let offset, value
            
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    checkMemOverflowByOffset(offset, evmGasLeft)
                    let expansionGas := expandMemory(add(offset, 1))
                    evmGasLeft := chargeGas(evmGasLeft, expansionGas)
            
                    mstore8(add(MEM_OFFSET_INNER(), offset), value)
                    ip := add(ip, 1)
                }
                case 0x54 { // OP_SLOAD
                
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let key, value, isWarm
            
                    key, sp := popStackItem(sp, evmGasLeft)
            
                    let wasWarm := isSlotWarm(key)
            
                    if iszero(wasWarm) {
                        evmGasLeft := chargeGas(evmGasLeft, 2000)
                    }
            
                    value := sload(key)
            
                    if iszero(wasWarm) {
                        let _wasW, _orgV := warmSlot(key, value)
                    }
            
                    sp := pushStackItemWithoutCheck(sp,value)
                    ip := add(ip, 1)
                }
                case 0x55 { // OP_SSTORE
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let key, value, gasSpent
            
                    popStackCheck(sp, evmGasLeft, 2)
                    key, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    ip := add(ip, 1)
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
            
                    counter, sp := popStackItem(sp, evmGasLeft)
            
                    ip := add(add(BYTECODE_OFFSET(), 32), counter)
            
                    // Check next opcode is JUMPDEST
                    let nextOpcode := readIP(ip,maxAcceptablePos)
                    if iszero(eq(nextOpcode, 0x5B)) {
                        revertWithGas(evmGasLeft)
                    }
            
                    // execute JUMPDEST immediately
                    evmGasLeft := chargeGas(evmGasLeft, 1)
                    ip := add(ip, 1)
                }
                case 0x57 { // OP_JUMPI
                    evmGasLeft := chargeGas(evmGasLeft, 10)
            
                    let counter, b
            
                    popStackCheck(sp, evmGasLeft, 2)
                    counter, sp := popStackItemWithoutCheck(sp)
                    b, sp := popStackItemWithoutCheck(sp)
            
                    if iszero(b) {
                        ip := add(ip, 1)
                        continue
                    }
            
                    ip := add(add(BYTECODE_OFFSET(), 32), counter)
            
                    // Check next opcode is JUMPDEST
                    let nextOpcode := readIP(ip,maxAcceptablePos)
                    if iszero(eq(nextOpcode, 0x5B)) {
                        revertWithGas(evmGasLeft)
                    }
            
                    // execute JUMPDEST immediately
                    evmGasLeft := chargeGas(evmGasLeft, 1)
                    ip := add(ip, 1)
                }
                case 0x58 { // OP_PC
                    evmGasLeft := chargeGas(evmGasLeft, 2)
                    ip := add(ip, 1)
            
                    // PC = ip - 32 (bytecode size) - 1 (current instruction)
                    sp := pushStackItem(sp, sub(sub(ip, BYTECODE_OFFSET()), 33), evmGasLeft)
                }
                case 0x59 { // OP_MSIZE
                    evmGasLeft := chargeGas(evmGasLeft,2)
            
                    let size
            
                    size := mload(MEM_OFFSET())
                    size := shl(5,size)
                    sp := pushStackItem(sp,size, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x5A { // OP_GAS
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    sp := pushStackItem(sp, evmGasLeft, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x5B { // OP_JUMPDEST
                    evmGasLeft := chargeGas(evmGasLeft, 1)
                    ip := add(ip, 1)
                }
                case 0x5C { // OP_TLOAD
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let key
                    popStackCheck(sp, evmGasLeft, 1)
                    key, sp := popStackItemWithoutCheck(sp)
            
                    sp := pushStackItemWithoutCheck(sp, tload(key))
                    ip := add(ip, 1)
                }
                case 0x5D { // OP_TSTORE
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let key, value
                    popStackCheck(sp, evmGasLeft, 2)
                    key, sp := popStackItemWithoutCheck(sp)
                    value, sp := popStackItemWithoutCheck(sp)
            
                    tstore(key, value)
                    ip := add(ip, 1)
                }
                case 0x5E { // OP_MCOPY
                    let destOffset, offset, size
                    popStackCheck(sp, evmGasLeft, 3)
                    destOffset, sp := popStackItemWithoutCheck(sp)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    // TODO overflow checks
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                    checkMemOverflowByOffset(add(destOffset, size), evmGasLeft)
            
                    expandMemory(add(destOffset, size))
                    expandMemory(add(offset, size))
            
                    mcopy(add(destOffset, MEM_OFFSET_INNER()), add(offset, MEM_OFFSET_INNER()), size)
                    ip := add(ip, 1)
                }
                case 0x5F { // OP_PUSH0
                    evmGasLeft := chargeGas(evmGasLeft, 2)
            
                    let value := 0
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x60 { // OP_PUSH1
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,1)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 1)
                }
                case 0x61 { // OP_PUSH2
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,2)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 2)
                }     
                case 0x62 { // OP_PUSH3
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,3)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 3)
                }
                case 0x63 { // OP_PUSH4
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,4)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 4)
                }
                case 0x64 { // OP_PUSH5
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,5)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 5)
                }
                case 0x65 { // OP_PUSH6
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,6)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 6)
                }
                case 0x66 { // OP_PUSH7
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,7)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 7)
                }
                case 0x67 { // OP_PUSH8
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,8)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 8)
                }
                case 0x68 { // OP_PUSH9
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,9)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 9)
                }
                case 0x69 { // OP_PUSH10
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,10)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 10)
                }
                case 0x6A { // OP_PUSH11
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,11)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 11)
                }
                case 0x6B { // OP_PUSH12
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,12)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 12)
                }
                case 0x6C { // OP_PUSH13
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,13)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 13)
                }
                case 0x6D { // OP_PUSH14
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,14)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 14)
                }
                case 0x6E { // OP_PUSH15
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,15)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 15)
                }
                case 0x6F { // OP_PUSH16
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,16)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 16)
                }
                case 0x70 { // OP_PUSH17
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,17)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 17)
                }
                case 0x71 { // OP_PUSH18
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,18)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 18)
                }
                case 0x72 { // OP_PUSH19
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,19)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 19)
                }
                case 0x73 { // OP_PUSH20
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,20)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 20)
                }
                case 0x74 { // OP_PUSH21
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,21)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 21)
                }
                case 0x75 { // OP_PUSH22
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,22)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 22)
                }
                case 0x76 { // OP_PUSH23
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,23)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 23)
                }
                case 0x77 { // OP_PUSH24
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,24)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 24)
                }
                case 0x78 { // OP_PUSH25
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,25)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 25)
                }
                case 0x79 { // OP_PUSH26
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,26)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 26)
                }
                case 0x7A { // OP_PUSH27
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,27)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 27)
                }
                case 0x7B { // OP_PUSH28
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,28)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 28)
                }
                case 0x7C { // OP_PUSH29
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,29)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 29)
                }
                case 0x7D { // OP_PUSH30
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,30)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 30)
                }
                case 0x7E { // OP_PUSH31
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,31)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 31)
                }
                case 0x7F { // OP_PUSH32
                    evmGasLeft := chargeGas(evmGasLeft, 3)
            
                    ip := add(ip, 1)
                    let value := readBytes(ip,maxAcceptablePos,32)
            
                    sp := pushStackItem(sp, value, evmGasLeft)
                    ip := add(ip, 32)
                }
                case 0x80 { // OP_DUP1 
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 1)
                    ip := add(ip, 1)
                }
                case 0x81 { // OP_DUP2
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 2)
                    ip := add(ip, 1)
                }
                case 0x82 { // OP_DUP3
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 3)
                    ip := add(ip, 1)
                }
                case 0x83 { // OP_DUP4    
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 4)
                    ip := add(ip, 1)
                }
                case 0x84 { // OP_DUP5
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 5)
                    ip := add(ip, 1)
                }
                case 0x85 { // OP_DUP6
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 6)
                    ip := add(ip, 1)
                }
                case 0x86 { // OP_DUP7    
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 7)
                    ip := add(ip, 1)
                }
                case 0x87 { // OP_DUP8
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 8)
                    ip := add(ip, 1)
                }
                case 0x88 { // OP_DUP9
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 9)
                    ip := add(ip, 1)
                }
                case 0x89 { // OP_DUP10   
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 10)
                    ip := add(ip, 1)
                }
                case 0x8A { // OP_DUP11
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 11)
                    ip := add(ip, 1)
                }
                case 0x8B { // OP_DUP12
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 12)
                    ip := add(ip, 1)
                }
                case 0x8C { // OP_DUP13
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 13)
                    ip := add(ip, 1)
                }
                case 0x8D { // OP_DUP14
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 14)
                    ip := add(ip, 1)
                }
                case 0x8E { // OP_DUP15
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 15)
                    ip := add(ip, 1)
                }
                case 0x8F { // OP_DUP16
                    sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 16)
                    ip := add(ip, 1)
                }
                case 0x90 { // OP_SWAP1 
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 1)
                    ip := add(ip, 1)
                }
                case 0x91 { // OP_SWAP2
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 2)
                    ip := add(ip, 1)
                }
                case 0x92 { // OP_SWAP3
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 3)
                    ip := add(ip, 1)
                }
                case 0x93 { // OP_SWAP4    
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 4)
                    ip := add(ip, 1)
                }
                case 0x94 { // OP_SWAP5
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 5)
                    ip := add(ip, 1)
                }
                case 0x95 { // OP_SWAP6
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 6)
                    ip := add(ip, 1)
                }
                case 0x96 { // OP_SWAP7    
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 7)
                    ip := add(ip, 1)
                }
                case 0x97 { // OP_SWAP8
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 8)
                    ip := add(ip, 1)
                }
                case 0x98 { // OP_SWAP9
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 9)
                    ip := add(ip, 1)
                }
                case 0x99 { // OP_SWAP10   
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 10)
                    ip := add(ip, 1)
                }
                case 0x9A { // OP_SWAP11
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 11)
                    ip := add(ip, 1)
                }
                case 0x9B { // OP_SWAP12
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 12)
                    ip := add(ip, 1)
                }
                case 0x9C { // OP_SWAP13
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 13)
                    ip := add(ip, 1)
                }
                case 0x9D { // OP_SWAP14
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 14)
                    ip := add(ip, 1)
                }
                case 0x9E { // OP_SWAP15
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 15)
                    ip := add(ip, 1)
                }
                case 0x9F { // OP_SWAP16
                    evmGasLeft := swapStackItem(sp, evmGasLeft, 16)
                    ip := add(ip, 1)
                }
                case 0xA0 { // OP_LOG0
                    evmGasLeft := chargeGas(evmGasLeft, 375)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let offset, size
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                    let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    log0(add(offset, MEM_OFFSET_INNER()), size)
                    ip := add(ip, 1)
                }
                case 0xA1 { // OP_LOG1
                    evmGasLeft := chargeGas(evmGasLeft, 375)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let offset, size, topic1
                    popStackCheck(sp, evmGasLeft, 3)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
                    topic1, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                    let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                    dynamicGas := add(dynamicGas, 375)
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    log1(add(offset, MEM_OFFSET_INNER()), size, topic1)
                    ip := add(ip, 1)
                }
                case 0xA2 { // OP_LOG2
                    evmGasLeft := chargeGas(evmGasLeft, 375)
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let offset, size
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                    let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                    dynamicGas := add(dynamicGas, 750)
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    {
                        let topic1, topic2
                        popStackCheck(sp, evmGasLeft, 2)
                        topic1, sp := popStackItemWithoutCheck(sp)
                        topic2, sp := popStackItemWithoutCheck(sp)
                        log2(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2)
                    }
                    ip := add(ip, 1)
                }
                case 0xA3 { // OP_LOG3
                    evmGasLeft := chargeGas(evmGasLeft, 375)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let offset, size
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                    let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                    dynamicGas := add(dynamicGas, 1125)
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    {
                        let topic1, topic2, topic3
                        popStackCheck(sp, evmGasLeft, 3)
                        topic1, sp := popStackItemWithoutCheck(sp)
                        topic2, sp := popStackItemWithoutCheck(sp)
                        topic3, sp := popStackItemWithoutCheck(sp)
                        log3(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3)
                    }     
                    ip := add(ip, 1)
                }
                case 0xA4 { // OP_LOG4
                    evmGasLeft := chargeGas(evmGasLeft, 375)
            
                    if isStatic {
                        revertWithGas(evmGasLeft)
                    }
            
                    let offset, size
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset, size, evmGasLeft)
                    checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                    // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                    let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                    dynamicGas := add(dynamicGas, 1500)
                    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                    {
                        let topic1, topic2, topic3, topic4
                        popStackCheck(sp, evmGasLeft, 4)
                        topic1, sp := popStackItemWithoutCheck(sp)
                        topic2, sp := popStackItemWithoutCheck(sp)
                        topic3, sp := popStackItemWithoutCheck(sp)
                        topic4, sp := popStackItemWithoutCheck(sp)
                        log4(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3, topic4)
                    }     
                    ip := add(ip, 1)
                }
                case 0xF0 { // OP_CREATE
                    evmGasLeft, sp := performCreate(evmGasLeft, sp, isStatic)
                    ip := add(ip, 1)
                }
                case 0xF1 { // OP_CALL
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let gasUsed
            
                    // A function was implemented in order to avoid stack depth errors.
                    gasUsed, sp := performCall(sp, evmGasLeft, isStatic)
            
                    // Check if the following is ok
                    evmGasLeft := chargeGas(evmGasLeft, gasUsed)
                    ip := add(ip, 1)
                }
                case 0xF3 { // OP_RETURN
                    let offset,size
            
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    checkOverflow(offset,size, evmGasLeft)
                    evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))
            
                    returnLen := size
                    checkOverflow(offset,MEM_OFFSET_INNER(), evmGasLeft)
                    returnOffset := add(MEM_OFFSET_INNER(), offset)
                    break
                }
                case 0xF4 { // OP_DELEGATECALL
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let gasUsed
                    sp, isStatic, gasUsed := delegateCall(sp, isStatic, evmGasLeft)
            
                    evmGasLeft := chargeGas(evmGasLeft, gasUsed)
                    ip := add(ip, 1)
                }
                case 0xF5 { // OP_CREATE2
                    let result, addr
                    evmGasLeft, sp, result, addr := performCreate2(evmGasLeft, sp, isStatic)
                    switch result
                    case 0 { sp := pushStackItem(sp, 0, evmGasLeft) }
                    default { sp := pushStackItem(sp, addr, evmGasLeft) }
                    ip := add(ip, 1)
                }
                case 0xFA { // OP_STATICCALL
                    evmGasLeft := chargeGas(evmGasLeft, 100)
            
                    let gasUsed
                    gasUsed, sp := performStaticCall(sp,evmGasLeft)
                    evmGasLeft := chargeGas(evmGasLeft,gasUsed)
                    ip := add(ip, 1)
                }
                case 0xFD { // OP_REVERT
                    let offset,size
            
                    popStackCheck(sp, evmGasLeft, 2)
                    offset, sp := popStackItemWithoutCheck(sp)
                    size, sp := popStackItemWithoutCheck(sp)
            
                    // TODO invalid?
                    ensureAcceptableMemLocation(offset)
                    ensureAcceptableMemLocation(size)
                    evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))
            
                    offset := add(offset, MEM_OFFSET_INNER())
                    offset,size := addGasIfEvmRevert(isCallerEVM,offset,size,evmGasLeft)
            
                    revert(offset,size)
                }
                case 0xFE { // OP_INVALID
                    evmGasLeft := 0
            
                    revertWithGas(evmGasLeft)
                }
                default {
                    printString("INVALID OPCODE")
                    printHex(opcode)
                    revert(0, 0)
                }
            }
            

            retGasLeft := evmGasLeft
        }

        ////////////////////////////////////////////////////////////////
        //                      FALLBACK
        ////////////////////////////////////////////////////////////////

        let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

        if isStatic {
            revert(0, 0)
        }

        getConstructorBytecode()

        if iszero(isCallerEVM) {
            evmGasLeft := getEVMGas()
        }

        let offset, len, gasToReturn := simulate(isCallerEVM, evmGasLeft, false)

        gasToReturn := validateCorrectBytecode(offset, len, gasToReturn)

        offset, len := padBytecode(offset, len)

        setDeployedCode(gasToReturn, offset, len)
    }
    object "EVMInterpreter_deployed" {
        code {
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
                    revertWithGas(evmGasLeft)
                }
            
                if lt(tempSp, STACK_OFFSET()) {
                    revertWithGas(evmGasLeft)
                }
            
                let dup := mload(tempSp)                    
            
                newSp := add(sp, 0x20)
                mstore(newSp, dup)
            }
            
            function swapStackItem(sp, evmGas, position) ->  evmGasLeft {
                evmGasLeft := chargeGas(evmGas, 3)
                let tempSp := sub(sp, mul(0x20, position))
            
                if or(gt(tempSp, BYTECODE_OFFSET()), eq(tempSp, BYTECODE_OFFSET())) {
                    revertWithGas(evmGasLeft)
                }
            
                if lt(tempSp, STACK_OFFSET()) {
                    revertWithGas(evmGasLeft)
                }
            
            
                let s2 := mload(sp)
                let s1 := mload(tempSp)                    
            
                mstore(sp, s1)
                mstore(tempSp, s2)
            }
            
            function popStackItem(sp, evmGasLeft) -> a, newSp {
                // We can not return any error here, because it would break compatibility
                if lt(sp, STACK_OFFSET()) {
                    revertWithGas(evmGasLeft)
                }
            
                a := mload(sp)
                newSp := sub(sp, 0x20)
            }
            
            function pushStackItem(sp, item, evmGasLeft) -> newSp {
                if or(gt(sp, BYTECODE_OFFSET()), eq(sp, BYTECODE_OFFSET())) {
                    revertWithGas(evmGasLeft)
                }
            
                newSp := add(sp, 0x20)
                mstore(newSp, item)
            }
            
            function popStackItemWithoutCheck(sp) -> a, newSp {
                a := mload(sp)
                newSp := sub(sp, 0x20)
            }
            
            function pushStackItemWithoutCheck(sp, item) -> newSp {
                newSp := add(sp, 0x20)
                mstore(newSp, item)
            }
            
            function popStackCheck(sp, evmGasLeft, numInputs) {
                if lt(sub(sp, mul(0x20, sub(numInputs, 1))), STACK_OFFSET()) {
                    revertWithGas(evmGasLeft)
                }
            }
            
            function pushStackCheck(sp, evmGasLeft, numInputs) {
                if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_OFFSET())) {
                    revertWithGas(evmGasLeft)
                }
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
                mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
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
                mstore(0, 0xE03FE17700000000000000000000000000000000000000000000000000000000)
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
                isStatic := iszero(iszero(and(isStatic, 0x04)))
            }
            
            // Basically performs an extcodecopy, while returning the length of the bytecode.
            function _fetchDeployedCode(addr, _offset, _len) -> codeLen {
                codeLen := _fetchDeployedCodeWithDest(addr, 0, _len, _offset)
            }
            
            // Basically performs an extcodecopy, while returning the length of the bytecode.
            function _fetchDeployedCodeWithDest(addr, _offset, _len, dest) -> codeLen {
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
            
                returndatacopy(dest, add(32,_offset), _len)
            }
            
            // Returns the length of the bytecode.
            function _fetchDeployedCodeLen(addr) -> codeLen {
                let codeHash := _getRawCodeHash(addr)
            
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
                mstore(0, 0x04C14E9E00000000000000000000000000000000000000000000000000000000)
            
                let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    4,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
                let to := EVM_GAS_MANAGER_CONTRACT()
                let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            
                if iszero(success) {
                    // Should never happen
                    revert(0, 0)
                }
            
                returndatacopy(0,0,64)
            
                passGas := mload(0)
                isStatic := mload(32)
            
                if iszero(eq(passGas, INF_PASS_GAS())) {
                    callerEVM := true
                }
            }
            
            function chargeGas(prevGas, toCharge) -> gasRemaining {
                if lt(prevGas, toCharge) {
                    revertWithGas(0)
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
            // Take into account MEM_OFFSET_INNER() when passing the argsOffset
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
            
            function checkMemOverflowByOffset(offset, evmGasLeft) {
                if gt(offset, MAX_POSSIBLE_MEM()) {
                    mstore(0, evmGasLeft)
                    revert(0, 32)
                }
            }
            
            function checkMemOverflow(location, evmGasLeft) {
                if gt(location, MAX_MEMORY_FRAME()) {
                    mstore(0, evmGasLeft)
                    revert(0, 32)
                }
            }
            
            function checkMultipleOverflow(data1, data2, data3, evmGasLeft) {
                checkOverflow(data1, data2, evmGasLeft)
                checkOverflow(data1, data3, evmGasLeft)
                checkOverflow(data2, data3, evmGasLeft)
                checkOverflow(add(data1, data2), data3, evmGasLeft)
            }
            
            function checkOverflow(data1, data2, evmGasLeft) {
                if lt(add(data1, data2), data2) {
                    revertWithGas(evmGasLeft)
                }
            }
            
            function revertWithGas(evmGasLeft) {
                mstore(0, evmGasLeft)
                revert(0, 32)
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
                mstore(0, 0x482D2E7400000000000000000000000000000000000000000000000000000000)
                mstore(4, key)
            
                let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 36, 0, 32)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            
                isWarm := mload(0)
            }
            
            function warmSlot(key,currentValue) -> isWarm, originalValue {
                mstore(0, 0xBDF7816000000000000000000000000000000000000000000000000000000000)
                mstore(4, key)
                mstore(36,currentValue)
            
                let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    68,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
                let to := EVM_GAS_MANAGER_CONTRACT()
                let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            
                returndatacopy(0, 0, 64)
            
                isWarm := mload(0)
                originalValue := mload(32)
            }
            
            function MAX_SYSTEM_CONTRACT_ADDR() -> ret {
                ret := 0x000000000000000000000000000000000000ffff
            }
            
            /// @dev Checks whether an address is an EOA (i.e. has not code deployed on it)
            /// @param addr The address to check
            function isEOA(addr) -> ret {
                ret := 0
                if gt(addr, MAX_SYSTEM_CONTRACT_ADDR()) {
                    ret := iszero(_getRawCodeHash(addr))
                }
            }
            
            function incrementNonce(addr) {
                mstore(0, 0x306395C600000000000000000000000000000000000000000000000000000000)
                mstore(4, addr)
            
                let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    36,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
                let to := NONCE_HOLDER_SYSTEM_CONTRACT()
                let result := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            
                if iszero(result) {
                    revert(0, 0)
                }
            } 
            
            function getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            ) -> ret {
                let farCallAbi := 0
                farCallAbi :=  or(farCallAbi, dataOffset)
                farCallAbi :=  or(farCallAbi, shl(64, dataStart))
                farCallAbi :=  or(farCallAbi, shl(96, dataLength))
                farCallAbi :=  or(farCallAbi, shl(192, gasPassed))
                farCallAbi :=  or(farCallAbi, shl(224, shardId))
                farCallAbi :=  or(farCallAbi, shl(232, forwardingMode))
                farCallAbi :=  or(farCallAbi, shl(248, 1))
                ret := farCallAbi
            }
            
            function ensureAcceptableMemLocation(location) {
                if gt(location,MAX_POSSIBLE_MEM()) {
                    revert(0,0) // Check if this is what's needed
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
            
            function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
                mstore(0, 0x8DB2BA7800000000000000000000000000000000000000000000000000000000)
                mstore(4, addr)
            
                let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    36,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
                let to := EVM_GAS_MANAGER_CONTRACT()
                let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            
                returndatacopy(0, 0, 32)
                isWarm := mload(0)
            }
            
            function getRawNonce(addr) -> nonce {
                mstore(0, 0x5AA9B6B500000000000000000000000000000000000000000000000000000000)
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
            
                mstore(0, 0x8C04047700000000000000000000000000000000000000000000000000000000)
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
            
                mstore(0, 0xEAD7715600000000000000000000000000000000000000000000000000000000)
                mstore(4, _passGas)
                mstore(36, _isStatic)
            
                let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    68,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
            
                let to := EVM_GAS_MANAGER_CONTRACT()
                let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            }
            
            function _popEVMFrame() {
                // function popEVMFrame() external
            
                 let farCallAbi := getFarCallABI(
                    0,
                    0,
                    0,
                    4,
                    gas(),
                    // Only rollup is supported for now
                    0,
                    0,
                    0,
                    1
                )
            
                let to := EVM_GAS_MANAGER_CONTRACT()
            
                mstore(0, 0xE467D2F000000000000000000000000000000000000000000000000000000000)
            
                let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            }
            
            // Each evm gas is 5 zkEVM one
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
            
                switch lt(_gas, requiredGas)
                case 1 {
                    evmGas := 0
                }
                default {
                    evmGas := div(sub(_gas, requiredGas), GAS_DIVISOR())
                }
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
            
                        // We copy as much returndata as possible without going over the 
                        // returndata size.
                        switch lt(sub(rtsz, 32), _outputLen)
                            case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                            default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }
            
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
            
                popStackCheck(oldSp, evmGasLeft, 6)
                gasToPass, sp := popStackItemWithoutCheck(oldSp)
                addr, sp := popStackItemWithoutCheck(sp)
                argsOffset, sp := popStackItemWithoutCheck(sp)
                argsSize, sp := popStackItemWithoutCheck(sp)
                retOffset, sp := popStackItemWithoutCheck(sp)
                retSize, sp := popStackItemWithoutCheck(sp)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                checkOverflow(argsOffset,argsSize, evmGasLeft)
                checkOverflow(retOffset, retSize, evmGasLeft)
            
                checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
                checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)
            
                extraCost := 0
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
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
                switch _isEVM(addr)
                case 0 {
                    // zkEVM native
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
                default {
                    _pushEVMFrame(gasToPass, true)
                    success := staticcall(gasToPass, addr, add(MEM_OFFSET_INNER(), argsOffset), argsSize, 0, 0)
            
                    frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
                    _popEVMFrame()
                }
            
                let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
                switch iszero(precompileCost)
                case 1 {
                    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
                }
                default {
                    extraCost := add(extraCost, precompileCost)
                }
            
                sp := pushStackItem(sp, success, evmGasLeft)
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
            
                switch isStatic
                case 0 {
                    switch is_evm
                    case 0 {
                        // zkEVM native
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
                    default {
                        _pushEVMFrame(gasToPassNew, isStatic)
                        success := call(EVM_GAS_STIPEND(), addr, value, argsOffset, argsSize, 0, 0)
                        frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
                        _popEVMFrame()
                    }
                }
                default {
                    if value {
                        revertWithGas(gasToPassNew)
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
            }
            
            function performCall(oldSp, evmGasLeft, isStatic) -> extraCost, sp {
                let gasToPass,addr,value,argsOffset,argsSize,retOffset,retSize
            
                popStackCheck(oldSp, evmGasLeft, 7)
                gasToPass, sp := popStackItemWithoutCheck(oldSp)
                addr, sp := popStackItemWithoutCheck(sp)
                value, sp := popStackItemWithoutCheck(sp)
                argsOffset, sp := popStackItemWithoutCheck(sp)
                argsSize, sp := popStackItemWithoutCheck(sp)
                retOffset, sp := popStackItemWithoutCheck(sp)
                retSize, sp := popStackItemWithoutCheck(sp)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                // static_gas = 0
                // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
                // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
                // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
                // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called. 2300 is thus removed from the cost, and also added to the gas input.
                // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.
            
                extraCost := 0
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
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
            
                checkOverflow(argsOffset,argsSize, evmGasLeft)
                checkOverflow(retOffset,retSize, evmGasLeft)
            
                checkMemOverflow(add(argsOffset, argsSize), evmGasLeft)
                checkMemOverflow(add(retOffset, retSize), evmGasLeft)
            
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
            
                let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
                switch iszero(precompileCost)
                case 1 {
                    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
                }
                default {
                    extraCost := add(extraCost, precompileCost)
                }
                sp := pushStackItem(sp,success, evmGasLeft) 
            }
            
            function delegateCall(oldSp, oldIsStatic, evmGasLeft) -> sp, isStatic, extraCost {
                let addr, gasToPass, argsOffset, argsSize, retOffset, retSize
            
                sp := oldSp
                isStatic := oldIsStatic
            
                popStackCheck(sp, evmGasLeft, 6)
                gasToPass, sp := popStackItemWithoutCheck(sp)
                addr, sp := popStackItemWithoutCheck(sp)
                argsOffset, sp := popStackItemWithoutCheck(sp)
                argsSize, sp := popStackItemWithoutCheck(sp)
                retOffset, sp := popStackItemWithoutCheck(sp)
                retSize, sp := popStackItemWithoutCheck(sp)
            
                addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
            
                checkOverflow(argsOffset, argsSize, evmGasLeft)
                checkOverflow(retOffset, retSize, evmGasLeft)
            
                checkMemOverflowByOffset(add(argsOffset, argsSize), evmGasLeft)
                checkMemOverflowByOffset(add(retOffset, retSize), evmGasLeft)
            
                if iszero(_isEVM(addr)) {
                    revertWithGas(evmGasLeft)
                }
            
                extraCost := 0
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                    extraCost := 2500
                }
            
                {
                    let maxExpand := getMaxExpansionMemory(retOffset,retSize,argsOffset,argsSize)
                    extraCost := add(extraCost,maxExpand)
                }
                gasToPass := capGas(evmGasLeft,gasToPass)
            
                _pushEVMFrame(gasToPass, isStatic)
                let success := delegatecall(
                    // We can not just pass all gas here to prevent overflow of zkEVM gas counter
                    EVM_GAS_STIPEND(),
                    addr,
                    add(MEM_OFFSET_INNER(), argsOffset),
                    argsSize,
                    0,
                    0
                )
            
                let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
            
                _popEVMFrame()
            
                let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
                switch iszero(precompileCost)
                case 1 {
                    extraCost := add(extraCost,sub(gasToPass,frameGasLeft))
                }
                default {
                    extraCost := add(extraCost, precompileCost)
                }
                sp := pushStackItem(sp, success, evmGasLeft)
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
                switch _calleeIsEVM
                case 0 {
                    // zkEVM native
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
                default {
                    _pushEVMFrame(_calleeGas, true)
                    success := staticcall(EVM_GAS_STIPEND(), _callee, _inputOffset, _inputLen, 0, 0)
            
                    _gasLeft := _saveReturndataAfterEVMCall(_outputOffset, _outputLen)
                    _popEVMFrame()
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
                mstore(0, 0x24E5AB4A00000000000000000000000000000000000000000000000000000000)
            
                let success := staticcall(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, 4, 0, 32)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
            
                gasLeft := mload(0)
            }
            
            function $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeftOld, isCreate2, salt) -> result, evmGasLeft, addr {
                pop($llvm_AlwaysInline_llvm$_warmAddress(addr))
            
                _eraseReturndataPointer()
            
                let gasForTheCall := capGas(evmGasLeftOld,INF_PASS_GAS())
            
                if lt(selfbalance(),value) {
                    revertWithGas(evmGasLeftOld)
                }
            
                offset := add(MEM_OFFSET_INNER(), offset)
            
                pushStackCheck(sp, evmGasLeftOld, 4)
                sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x80)))
                sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x60)))
                sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x40)))
                sp := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x20)))
            
                _pushEVMFrame(gasForTheCall, false)
            
                if isCreate2 {
                    // Create2EVM selector
                    mstore(sub(offset, 0x80), 0x4e96f4c0)
                    // salt
                    mstore(sub(offset, 0x60), salt)
                    // Where the arg starts (third word)
                    mstore(sub(offset, 0x40), 0x40)
                    // Length of the init code
                    mstore(sub(offset, 0x20), size)
            
            
                    result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x64), add(size, 0x64), 0, 32)
                }
            
            
                if iszero(isCreate2) {
                    // CreateEVM selector
                    mstore(sub(offset, 0x60), 0xff311601)
                    // Where the arg starts (second word)
                    mstore(sub(offset, 0x40), 0x20)
                    // Length of the init code
                    mstore(sub(offset, 0x20), size)
            
            
                    result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x44), add(size, 0x44), 0, 32)
                }
            
                addr := mload(0)
            
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
            
                let back
            
                // skipping check since we pushed exactly 4 items earlier
                back, sp := popStackItemWithoutCheck(sp)
                mstore(sub(offset, 0x20), back)
                back, sp := popStackItemWithoutCheck(sp)
                mstore(sub(offset, 0x40), back)
                back, sp := popStackItemWithoutCheck(sp)
                mstore(sub(offset, 0x60), back)
                back, sp := popStackItemWithoutCheck(sp)
                mstore(sub(offset, 0x80), back)
            }
            
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
            
            function performExtCodeCopy(evmGas,oldSp) -> evmGasLeft, sp {
                evmGasLeft := chargeGas(evmGas, 100)
            
                let addr, dest, offset, len
                popStackCheck(oldSp, evmGasLeft, 4)
                addr, sp := popStackItemWithoutCheck(oldSp)
                dest, sp := popStackItemWithoutCheck(sp)
                offset, sp := popStackItemWithoutCheck(sp)
                len, sp := popStackItemWithoutCheck(sp)
            
                // dynamicGas = 3 * minimum_word_size + memory_expansion_cost + address_access_cost
                // minimum_word_size = (size + 31) / 32
            
                let dynamicGas := add(
                    mul(3, shr(5, add(len, 31))),
                    expandMemory(add(dest, len))
                )
                if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                    dynamicGas := add(dynamicGas, 2500)
                }
                evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
            
                $llvm_AlwaysInline_llvm$_memsetToZero(dest, len)
            
                // Gets the code from the addr
                if and(iszero(iszero(_getRawCodeHash(addr))),gt(len,0)) {
                    pop(_fetchDeployedCodeWithDest(addr, offset, len,add(dest,MEM_OFFSET_INNER())))  
                }
            }
            
            function performCreate(evmGas,oldSp,isStatic) -> evmGasLeft, sp {
                evmGasLeft := chargeGas(evmGas, 32000)
            
                if isStatic {
                    revertWithGas(evmGasLeft)
                }
            
                let value, offset, size
            
                popStackCheck(oldSp, evmGasLeft, 3)
                value, sp := popStackItemWithoutCheck(oldSp)
                offset, sp := popStackItemWithoutCheck(sp)
                size, sp := popStackItemWithoutCheck(sp)
            
                checkOverflow(offset, size, evmGasLeft)
                checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
                    revertWithGas(evmGasLeft)
                }
            
                if gt(value, balance(address())) {
                    revertWithGas(evmGasLeft)
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
            
                let result, addr
                result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft, false, 0)
            
                switch result
                    case 0 { sp := pushStackItem(sp, 0, evmGasLeft) }
                    default { sp := pushStackItem(sp, addr, evmGasLeft) }
            }
            
            function performCreate2(evmGas, oldSp, isStatic) -> evmGasLeft, sp, result, addr{
                evmGasLeft := chargeGas(evmGas, 32000)
            
                if isStatic {
                    revertWithGas(evmGasLeft)
                }
            
                let value, offset, size, salt
            
                popStackCheck(oldSp, evmGasLeft, 4)
                value, sp := popStackItemWithoutCheck(oldSp)
                offset, sp := popStackItemWithoutCheck(sp)
                size, sp := popStackItemWithoutCheck(sp)
                salt, sp := popStackItemWithoutCheck(sp)
            
                checkOverflow(offset, size, evmGasLeft)
                checkMemOverflowByOffset(add(offset, size), evmGasLeft)
            
                if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
                    revertWithGas(evmGasLeft)
                }
            
                if gt(value, balance(address())) {
                    revertWithGas(evmGasLeft)
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
            
                result, evmGasLeft, addr := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft,true,salt)
            }
            

            function $llvm_NoInline_llvm$_simulate(
                isCallerEVM,
                evmGasLeft,
                isStatic,
            ) -> returnOffset, returnLen {

                returnOffset := MEM_OFFSET_INNER()
                returnLen := 0

                // stack pointer - index to first stack element; empty stack = -1
                let sp := sub(STACK_OFFSET(), 32)
                // instruction pointer - index to next instruction. Not called pc because it's an
                // actual yul/evm instruction.
                let ip := add(BYTECODE_OFFSET(), 32)
                let opcode
                
                let maxAcceptablePos := add(add(BYTECODE_OFFSET(), mload(BYTECODE_OFFSET())), 31)
                
                for { } true { } {
                    opcode := readIP(ip,maxAcceptablePos)
                
                    switch opcode
                    case 0x00 { // OP_STOP
                        break
                    }
                    case 0x01 { // OP_ADD
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, add(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x02 { // OP_MUL
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, mul(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x03 { // OP_SUB
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, sub(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x04 { // OP_DIV
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, div(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x05 { // OP_SDIV
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, sdiv(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x06 { // OP_MOD
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, mod(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x07 { // OP_SMOD
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, smod(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x08 { // OP_ADDMOD
                        evmGasLeft := chargeGas(evmGasLeft, 8)
                
                        let a, b, N
                
                        popStackCheck(sp, evmGasLeft, 3)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                        N, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, addmod(a, b, N))
                        ip := add(ip, 1)
                    }
                    case 0x09 { // OP_MULMOD
                        evmGasLeft := chargeGas(evmGasLeft, 8)
                
                        let a, b, N
                
                        popStackCheck(sp, evmGasLeft, 3)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                        N, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItem(sp, mulmod(a, b, N), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x0A { // OP_EXP
                        evmGasLeft := chargeGas(evmGasLeft, 10)
                
                        let a, exponent
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        exponent, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, exp(a, exponent))
                
                        let to_charge := 0
                        for {} gt(exponent,0) {} { // while exponent > 0
                            to_charge := add(to_charge, 50)
                            exponent := shr(8, exponent)
                        } 
                        evmGasLeft := chargeGas(evmGasLeft, to_charge)
                        ip := add(ip, 1)
                    }
                    case 0x0B { // OP_SIGNEXTEND
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                
                        let b, x
                
                        popStackCheck(sp, evmGasLeft, 2)
                        b, sp := popStackItemWithoutCheck(sp)
                        x, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, signextend(b, x))
                        ip := add(ip, 1)
                    }
                    case 0x10 { // OP_LT
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, lt(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x11 { // OP_GT
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, gt(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x12 { // OP_SLT
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, slt(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x13 { // OP_SGT
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, sgt(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x14 { // OP_EQ
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, eq(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x15 { // OP_ISZERO
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a
                
                        popStackCheck(sp, evmGasLeft, 1)
                        a, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, iszero(a))
                        ip := add(ip, 1)
                    }
                    case 0x16 { // OP_AND
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, and(a,b))
                        ip := add(ip, 1)
                    }
                    case 0x17 { // OP_OR
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, or(a,b))
                        ip := add(ip, 1)
                    }
                    case 0x18 { // OP_XOR
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        a, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, xor(a, b))
                        ip := add(ip, 1)
                    }
                    case 0x19 { // OP_NOT
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let a
                
                        popStackCheck(sp, evmGasLeft, 1)
                        a, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, not(a))
                        ip := add(ip, 1)
                    }
                    case 0x1A { // OP_BYTE
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let i, x
                
                        popStackCheck(sp, evmGasLeft, 2)
                        i, sp := popStackItemWithoutCheck(sp)
                        x, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, byte(i, x))
                        ip := add(ip, 1)
                    }
                    case 0x1B { // OP_SHL
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let shift, value
                
                        popStackCheck(sp, evmGasLeft, 2)
                        shift, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, shl(shift, value))
                        ip := add(ip, 1)
                    }
                    case 0x1C { // OP_SHR
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let shift, value
                
                        popStackCheck(sp, evmGasLeft, 2)
                        shift, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, shr(shift, value))
                        ip := add(ip, 1)
                    }
                    case 0x1D { // OP_SAR
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let shift, value
                
                        popStackCheck(sp, evmGasLeft, 2)
                        shift, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, sar(shift, value))
                        ip := add(ip, 1)
                    }
                    case 0x20 { // OP_KECCAK256
                        evmGasLeft := chargeGas(evmGasLeft, 30)
                
                        let offset, size
                
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                        let keccak := keccak256(add(MEM_OFFSET_INNER(), offset), size)
                
                        // When an offset is first accessed (either read or write), memory may trigger 
                        // an expansion, which costs gas.
                        // dynamicGas = 6 * minimum_word_size + memory_expansion_cost
                        // minimum_word_size = (size + 31) / 32
                        let dynamicGas := add(mul(6, shr(5, add(size, 31))), expandMemory(add(offset, size)))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        sp := pushStackItem(sp, keccak, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x30 { // OP_ADDRESS
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, address(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x31 { // OP_BALANCE
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let addr
                
                        addr, sp := popStackItem(sp, evmGasLeft)
                        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
                
                        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                            evmGasLeft := chargeGas(evmGasLeft, 2500)
                        }
                
                        sp := pushStackItemWithoutCheck(sp, balance(addr))
                        ip := add(ip, 1)
                    }
                    case 0x32 { // OP_ORIGIN
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, origin(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x33 { // OP_CALLER
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, caller(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x34 { // OP_CALLVALUE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, callvalue(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x35 { // OP_CALLDATALOAD
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let i
                
                        popStackCheck(sp, evmGasLeft, 1)
                        i, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, calldataload(i))
                        ip := add(ip, 1)
                    }
                    case 0x36 { // OP_CALLDATASIZE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, calldatasize(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x37 { // OP_CALLDATACOPY
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let destOffset, offset, size
                
                        popStackCheck(sp, evmGasLeft, 3)
                        destOffset, sp := popStackItemWithoutCheck(sp)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkMultipleOverflow(offset,size,MEM_OFFSET_INNER(), evmGasLeft)
                        checkMultipleOverflow(destOffset,size,MEM_OFFSET_INNER(), evmGasLeft)
                
                        // TODO invalid?
                        if or(gt(add(add(offset, size), MEM_OFFSET_INNER()), MAX_POSSIBLE_MEM()), gt(add(add(destOffset, size), MEM_OFFSET_INNER()), MAX_POSSIBLE_MEM())) {
                            $llvm_AlwaysInline_llvm$_memsetToZero(add(destOffset, MEM_OFFSET_INNER()), size)
                        }
                
                        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                        // minimum_word_size = (size + 31) / 32
                        let dynamicGas := add(mul(3, shr(5, add(size, 31))), expandMemory(add(destOffset, size)))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        calldatacopy(add(destOffset, MEM_OFFSET_INNER()), offset, size)
                        ip := add(ip, 1)
                        
                    }
                    case 0x38 { // OP_CODESIZE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        let bytecodeLen := mload(BYTECODE_OFFSET())
                        sp := pushStackItem(sp, bytecodeLen, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x39 { // OP_CODECOPY
                    
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let dst, offset, len
                
                        popStackCheck(sp, evmGasLeft, 3)
                        dst, sp := popStackItemWithoutCheck(sp)
                        offset, sp := popStackItemWithoutCheck(sp)
                        len, sp := popStackItemWithoutCheck(sp)
                
                        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                        // minimum_word_size = (size + 31) / 32
                        let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(add(dst, len)))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        dst := add(dst, MEM_OFFSET_INNER())
                        offset := add(add(offset, BYTECODE_OFFSET()), 32)
                
                        checkOverflow(dst,len, evmGasLeft)
                        checkMemOverflow(add(dst, len), evmGasLeft)
                        // Check bytecode overflow
                        if gt(add(offset, len), sub(MEM_OFFSET(), 1)) {
                            revertWithGas(evmGasLeft)
                        }
                
                        $llvm_AlwaysInline_llvm$_memcpy(dst, offset, len)
                        ip := add(ip, 1)
                    }
                    case 0x3A { // OP_GASPRICE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, gasprice(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x3B { // OP_EXTCODESIZE
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let addr
                        addr, sp := popStackItem(sp, evmGasLeft)
                
                        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
                        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                            evmGasLeft := chargeGas(evmGasLeft, 2500)
                        }
                
                        switch _isEVM(addr) 
                            case 0  { sp := pushStackItemWithoutCheck(sp, extcodesize(addr)) }
                            default { sp := pushStackItemWithoutCheck(sp, _fetchDeployedCodeLen(addr)) }
                        ip := add(ip, 1)
                    }
                    case 0x3C { // OP_EXTCODECOPY
                        evmGasLeft, sp := performExtCodeCopy(evmGasLeft, sp)
                        ip := add(ip, 1)
                    }
                    case 0x3D { // OP_RETURNDATASIZE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        let rdz := mload(LAST_RETURNDATA_SIZE_OFFSET())
                        sp := pushStackItem(sp, rdz, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x3E { // OP_RETURNDATACOPY
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let dest, offset, len
                        popStackCheck(sp, evmGasLeft, 3)
                        dest, sp := popStackItemWithoutCheck(sp)
                        offset, sp := popStackItemWithoutCheck(sp)
                        len, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset,len, evmGasLeft)
                        if gt(add(offset, len), mload(LAST_RETURNDATA_SIZE_OFFSET())) {
                            revertWithGas(evmGasLeft)
                        }
                
                        // minimum_word_size = (size + 31) / 32
                        // dynamicGas = 3 * minimum_word_size + memory_expansion_cost
                        checkMemOverflowByOffset(offset, evmGasLeft)
                        let dynamicGas := add(mul(3, shr(5, add(len, 31))), expandMemory(add(dest, len)))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        copyActivePtrData(add(MEM_OFFSET_INNER(), dest), offset, len)
                        ip := add(ip, 1)
                    }
                    case 0x3F { // OP_EXTCODEHASH
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let addr
                        addr, sp := popStackItem(sp, evmGasLeft)
                        addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)
                
                        if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
                            evmGasLeft := chargeGas(evmGasLeft, 2500) 
                        }
                
                        ip := add(ip, 1)
                        if iszero(addr) {
                            sp := pushStackItemWithoutCheck(sp, 0)
                            continue
                        }
                        sp := pushStackItemWithoutCheck(sp, extcodehash(addr))
                    }
                    case 0x40 { // OP_BLOCKHASH
                        evmGasLeft := chargeGas(evmGasLeft, 20)
                
                        let blockNumber
                        popStackCheck(sp, evmGasLeft, 1)
                        blockNumber, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, blockhash(blockNumber))
                        ip := add(ip, 1)
                    }
                    case 0x41 { // OP_COINBASE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, coinbase(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x42 { // OP_TIMESTAMP
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, timestamp(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x43 { // OP_NUMBER
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, number(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x44 { // OP_PREVRANDAO
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, prevrandao(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x45 { // OP_GASLIMIT
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, gaslimit(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x46 { // OP_CHAINID
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, chainid(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x47 { // OP_SELFBALANCE
                        evmGasLeft := chargeGas(evmGasLeft, 5)
                        sp := pushStackItem(sp, selfbalance(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x48 { // OP_BASEFEE
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        sp := pushStackItem(sp, basefee(), evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x50 { // OP_POP
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        let _y
                
                        _y, sp := popStackItem(sp, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x51 { // OP_MLOAD
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let offset
                
                        offset, sp := popStackItem(sp, evmGasLeft)
                
                        checkMemOverflowByOffset(offset, evmGasLeft)
                        let expansionGas := expandMemory(add(offset, 32))
                        evmGasLeft := chargeGas(evmGasLeft, expansionGas)
                
                        let memValue := mload(add(MEM_OFFSET_INNER(), offset))
                        sp := pushStackItemWithoutCheck(sp, memValue)
                        ip := add(ip, 1)
                    }
                    case 0x52 { // OP_MSTORE
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let offset, value
                
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        checkMemOverflowByOffset(offset, evmGasLeft)
                        let expansionGas := expandMemory(add(offset, 32))
                        evmGasLeft := chargeGas(evmGasLeft, expansionGas)
                
                        mstore(add(MEM_OFFSET_INNER(), offset), value)
                        ip := add(ip, 1)
                    }
                    case 0x53 { // OP_MSTORE8
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        let offset, value
                
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        checkMemOverflowByOffset(offset, evmGasLeft)
                        let expansionGas := expandMemory(add(offset, 1))
                        evmGasLeft := chargeGas(evmGasLeft, expansionGas)
                
                        mstore8(add(MEM_OFFSET_INNER(), offset), value)
                        ip := add(ip, 1)
                    }
                    case 0x54 { // OP_SLOAD
                    
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let key, value, isWarm
                
                        key, sp := popStackItem(sp, evmGasLeft)
                
                        let wasWarm := isSlotWarm(key)
                
                        if iszero(wasWarm) {
                            evmGasLeft := chargeGas(evmGasLeft, 2000)
                        }
                
                        value := sload(key)
                
                        if iszero(wasWarm) {
                            let _wasW, _orgV := warmSlot(key, value)
                        }
                
                        sp := pushStackItemWithoutCheck(sp,value)
                        ip := add(ip, 1)
                    }
                    case 0x55 { // OP_SSTORE
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let key, value, gasSpent
                
                        popStackCheck(sp, evmGasLeft, 2)
                        key, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        ip := add(ip, 1)
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
                
                        counter, sp := popStackItem(sp, evmGasLeft)
                
                        ip := add(add(BYTECODE_OFFSET(), 32), counter)
                
                        // Check next opcode is JUMPDEST
                        let nextOpcode := readIP(ip,maxAcceptablePos)
                        if iszero(eq(nextOpcode, 0x5B)) {
                            revertWithGas(evmGasLeft)
                        }
                
                        // execute JUMPDEST immediately
                        evmGasLeft := chargeGas(evmGasLeft, 1)
                        ip := add(ip, 1)
                    }
                    case 0x57 { // OP_JUMPI
                        evmGasLeft := chargeGas(evmGasLeft, 10)
                
                        let counter, b
                
                        popStackCheck(sp, evmGasLeft, 2)
                        counter, sp := popStackItemWithoutCheck(sp)
                        b, sp := popStackItemWithoutCheck(sp)
                
                        if iszero(b) {
                            ip := add(ip, 1)
                            continue
                        }
                
                        ip := add(add(BYTECODE_OFFSET(), 32), counter)
                
                        // Check next opcode is JUMPDEST
                        let nextOpcode := readIP(ip,maxAcceptablePos)
                        if iszero(eq(nextOpcode, 0x5B)) {
                            revertWithGas(evmGasLeft)
                        }
                
                        // execute JUMPDEST immediately
                        evmGasLeft := chargeGas(evmGasLeft, 1)
                        ip := add(ip, 1)
                    }
                    case 0x58 { // OP_PC
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                        ip := add(ip, 1)
                
                        // PC = ip - 32 (bytecode size) - 1 (current instruction)
                        sp := pushStackItem(sp, sub(sub(ip, BYTECODE_OFFSET()), 33), evmGasLeft)
                    }
                    case 0x59 { // OP_MSIZE
                        evmGasLeft := chargeGas(evmGasLeft,2)
                
                        let size
                
                        size := mload(MEM_OFFSET())
                        size := shl(5,size)
                        sp := pushStackItem(sp,size, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x5A { // OP_GAS
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        sp := pushStackItem(sp, evmGasLeft, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x5B { // OP_JUMPDEST
                        evmGasLeft := chargeGas(evmGasLeft, 1)
                        ip := add(ip, 1)
                    }
                    case 0x5C { // OP_TLOAD
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let key
                        popStackCheck(sp, evmGasLeft, 1)
                        key, sp := popStackItemWithoutCheck(sp)
                
                        sp := pushStackItemWithoutCheck(sp, tload(key))
                        ip := add(ip, 1)
                    }
                    case 0x5D { // OP_TSTORE
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let key, value
                        popStackCheck(sp, evmGasLeft, 2)
                        key, sp := popStackItemWithoutCheck(sp)
                        value, sp := popStackItemWithoutCheck(sp)
                
                        tstore(key, value)
                        ip := add(ip, 1)
                    }
                    case 0x5E { // OP_MCOPY
                        let destOffset, offset, size
                        popStackCheck(sp, evmGasLeft, 3)
                        destOffset, sp := popStackItemWithoutCheck(sp)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        // TODO overflow checks
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                        checkMemOverflowByOffset(add(destOffset, size), evmGasLeft)
                
                        expandMemory(add(destOffset, size))
                        expandMemory(add(offset, size))
                
                        mcopy(add(destOffset, MEM_OFFSET_INNER()), add(offset, MEM_OFFSET_INNER()), size)
                        ip := add(ip, 1)
                    }
                    case 0x5F { // OP_PUSH0
                        evmGasLeft := chargeGas(evmGasLeft, 2)
                
                        let value := 0
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x60 { // OP_PUSH1
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,1)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 1)
                    }
                    case 0x61 { // OP_PUSH2
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,2)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 2)
                    }     
                    case 0x62 { // OP_PUSH3
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,3)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 3)
                    }
                    case 0x63 { // OP_PUSH4
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,4)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 4)
                    }
                    case 0x64 { // OP_PUSH5
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,5)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 5)
                    }
                    case 0x65 { // OP_PUSH6
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,6)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 6)
                    }
                    case 0x66 { // OP_PUSH7
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,7)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 7)
                    }
                    case 0x67 { // OP_PUSH8
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,8)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 8)
                    }
                    case 0x68 { // OP_PUSH9
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,9)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 9)
                    }
                    case 0x69 { // OP_PUSH10
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,10)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 10)
                    }
                    case 0x6A { // OP_PUSH11
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,11)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 11)
                    }
                    case 0x6B { // OP_PUSH12
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,12)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 12)
                    }
                    case 0x6C { // OP_PUSH13
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,13)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 13)
                    }
                    case 0x6D { // OP_PUSH14
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,14)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 14)
                    }
                    case 0x6E { // OP_PUSH15
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,15)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 15)
                    }
                    case 0x6F { // OP_PUSH16
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,16)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 16)
                    }
                    case 0x70 { // OP_PUSH17
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,17)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 17)
                    }
                    case 0x71 { // OP_PUSH18
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,18)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 18)
                    }
                    case 0x72 { // OP_PUSH19
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,19)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 19)
                    }
                    case 0x73 { // OP_PUSH20
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,20)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 20)
                    }
                    case 0x74 { // OP_PUSH21
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,21)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 21)
                    }
                    case 0x75 { // OP_PUSH22
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,22)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 22)
                    }
                    case 0x76 { // OP_PUSH23
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,23)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 23)
                    }
                    case 0x77 { // OP_PUSH24
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,24)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 24)
                    }
                    case 0x78 { // OP_PUSH25
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,25)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 25)
                    }
                    case 0x79 { // OP_PUSH26
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,26)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 26)
                    }
                    case 0x7A { // OP_PUSH27
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,27)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 27)
                    }
                    case 0x7B { // OP_PUSH28
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,28)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 28)
                    }
                    case 0x7C { // OP_PUSH29
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,29)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 29)
                    }
                    case 0x7D { // OP_PUSH30
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,30)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 30)
                    }
                    case 0x7E { // OP_PUSH31
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,31)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 31)
                    }
                    case 0x7F { // OP_PUSH32
                        evmGasLeft := chargeGas(evmGasLeft, 3)
                
                        ip := add(ip, 1)
                        let value := readBytes(ip,maxAcceptablePos,32)
                
                        sp := pushStackItem(sp, value, evmGasLeft)
                        ip := add(ip, 32)
                    }
                    case 0x80 { // OP_DUP1 
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 1)
                        ip := add(ip, 1)
                    }
                    case 0x81 { // OP_DUP2
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 2)
                        ip := add(ip, 1)
                    }
                    case 0x82 { // OP_DUP3
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 3)
                        ip := add(ip, 1)
                    }
                    case 0x83 { // OP_DUP4    
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 4)
                        ip := add(ip, 1)
                    }
                    case 0x84 { // OP_DUP5
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 5)
                        ip := add(ip, 1)
                    }
                    case 0x85 { // OP_DUP6
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 6)
                        ip := add(ip, 1)
                    }
                    case 0x86 { // OP_DUP7    
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 7)
                        ip := add(ip, 1)
                    }
                    case 0x87 { // OP_DUP8
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 8)
                        ip := add(ip, 1)
                    }
                    case 0x88 { // OP_DUP9
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 9)
                        ip := add(ip, 1)
                    }
                    case 0x89 { // OP_DUP10   
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 10)
                        ip := add(ip, 1)
                    }
                    case 0x8A { // OP_DUP11
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 11)
                        ip := add(ip, 1)
                    }
                    case 0x8B { // OP_DUP12
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 12)
                        ip := add(ip, 1)
                    }
                    case 0x8C { // OP_DUP13
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 13)
                        ip := add(ip, 1)
                    }
                    case 0x8D { // OP_DUP14
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 14)
                        ip := add(ip, 1)
                    }
                    case 0x8E { // OP_DUP15
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 15)
                        ip := add(ip, 1)
                    }
                    case 0x8F { // OP_DUP16
                        sp, evmGasLeft := dupStackItem(sp, evmGasLeft, 16)
                        ip := add(ip, 1)
                    }
                    case 0x90 { // OP_SWAP1 
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 1)
                        ip := add(ip, 1)
                    }
                    case 0x91 { // OP_SWAP2
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 2)
                        ip := add(ip, 1)
                    }
                    case 0x92 { // OP_SWAP3
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 3)
                        ip := add(ip, 1)
                    }
                    case 0x93 { // OP_SWAP4    
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 4)
                        ip := add(ip, 1)
                    }
                    case 0x94 { // OP_SWAP5
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 5)
                        ip := add(ip, 1)
                    }
                    case 0x95 { // OP_SWAP6
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 6)
                        ip := add(ip, 1)
                    }
                    case 0x96 { // OP_SWAP7    
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 7)
                        ip := add(ip, 1)
                    }
                    case 0x97 { // OP_SWAP8
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 8)
                        ip := add(ip, 1)
                    }
                    case 0x98 { // OP_SWAP9
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 9)
                        ip := add(ip, 1)
                    }
                    case 0x99 { // OP_SWAP10   
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 10)
                        ip := add(ip, 1)
                    }
                    case 0x9A { // OP_SWAP11
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 11)
                        ip := add(ip, 1)
                    }
                    case 0x9B { // OP_SWAP12
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 12)
                        ip := add(ip, 1)
                    }
                    case 0x9C { // OP_SWAP13
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 13)
                        ip := add(ip, 1)
                    }
                    case 0x9D { // OP_SWAP14
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 14)
                        ip := add(ip, 1)
                    }
                    case 0x9E { // OP_SWAP15
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 15)
                        ip := add(ip, 1)
                    }
                    case 0x9F { // OP_SWAP16
                        evmGasLeft := swapStackItem(sp, evmGasLeft, 16)
                        ip := add(ip, 1)
                    }
                    case 0xA0 { // OP_LOG0
                        evmGasLeft := chargeGas(evmGasLeft, 375)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let offset, size
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                
                        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        log0(add(offset, MEM_OFFSET_INNER()), size)
                        ip := add(ip, 1)
                    }
                    case 0xA1 { // OP_LOG1
                        evmGasLeft := chargeGas(evmGasLeft, 375)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let offset, size, topic1
                        popStackCheck(sp, evmGasLeft, 3)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                        topic1, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                
                        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                        dynamicGas := add(dynamicGas, 375)
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        log1(add(offset, MEM_OFFSET_INNER()), size, topic1)
                        ip := add(ip, 1)
                    }
                    case 0xA2 { // OP_LOG2
                        evmGasLeft := chargeGas(evmGasLeft, 375)
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let offset, size
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                
                        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                        dynamicGas := add(dynamicGas, 750)
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        {
                            let topic1, topic2
                            popStackCheck(sp, evmGasLeft, 2)
                            topic1, sp := popStackItemWithoutCheck(sp)
                            topic2, sp := popStackItemWithoutCheck(sp)
                            log2(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2)
                        }
                        ip := add(ip, 1)
                    }
                    case 0xA3 { // OP_LOG3
                        evmGasLeft := chargeGas(evmGasLeft, 375)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let offset, size
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                
                        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                        dynamicGas := add(dynamicGas, 1125)
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        {
                            let topic1, topic2, topic3
                            popStackCheck(sp, evmGasLeft, 3)
                            topic1, sp := popStackItemWithoutCheck(sp)
                            topic2, sp := popStackItemWithoutCheck(sp)
                            topic3, sp := popStackItemWithoutCheck(sp)
                            log3(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3)
                        }     
                        ip := add(ip, 1)
                    }
                    case 0xA4 { // OP_LOG4
                        evmGasLeft := chargeGas(evmGasLeft, 375)
                
                        if isStatic {
                            revertWithGas(evmGasLeft)
                        }
                
                        let offset, size
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset, size, evmGasLeft)
                        checkMemOverflowByOffset(add(offset, size), evmGasLeft)
                
                        // dynamicGas = 375 * topic_count + 8 * size + memory_expansion_cost
                        let dynamicGas := add(shl(3, size), expandMemory(add(offset, size)))
                        dynamicGas := add(dynamicGas, 1500)
                        evmGasLeft := chargeGas(evmGasLeft, dynamicGas)
                
                        {
                            let topic1, topic2, topic3, topic4
                            popStackCheck(sp, evmGasLeft, 4)
                            topic1, sp := popStackItemWithoutCheck(sp)
                            topic2, sp := popStackItemWithoutCheck(sp)
                            topic3, sp := popStackItemWithoutCheck(sp)
                            topic4, sp := popStackItemWithoutCheck(sp)
                            log4(add(offset, MEM_OFFSET_INNER()), size, topic1, topic2, topic3, topic4)
                        }     
                        ip := add(ip, 1)
                    }
                    case 0xF0 { // OP_CREATE
                        evmGasLeft, sp := performCreate(evmGasLeft, sp, isStatic)
                        ip := add(ip, 1)
                    }
                    case 0xF1 { // OP_CALL
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let gasUsed
                
                        // A function was implemented in order to avoid stack depth errors.
                        gasUsed, sp := performCall(sp, evmGasLeft, isStatic)
                
                        // Check if the following is ok
                        evmGasLeft := chargeGas(evmGasLeft, gasUsed)
                        ip := add(ip, 1)
                    }
                    case 0xF3 { // OP_RETURN
                        let offset,size
                
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        checkOverflow(offset,size, evmGasLeft)
                        evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))
                
                        returnLen := size
                        checkOverflow(offset,MEM_OFFSET_INNER(), evmGasLeft)
                        returnOffset := add(MEM_OFFSET_INNER(), offset)
                        break
                    }
                    case 0xF4 { // OP_DELEGATECALL
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let gasUsed
                        sp, isStatic, gasUsed := delegateCall(sp, isStatic, evmGasLeft)
                
                        evmGasLeft := chargeGas(evmGasLeft, gasUsed)
                        ip := add(ip, 1)
                    }
                    case 0xF5 { // OP_CREATE2
                        let result, addr
                        evmGasLeft, sp, result, addr := performCreate2(evmGasLeft, sp, isStatic)
                        switch result
                        case 0 { sp := pushStackItem(sp, 0, evmGasLeft) }
                        default { sp := pushStackItem(sp, addr, evmGasLeft) }
                        ip := add(ip, 1)
                    }
                    case 0xFA { // OP_STATICCALL
                        evmGasLeft := chargeGas(evmGasLeft, 100)
                
                        let gasUsed
                        gasUsed, sp := performStaticCall(sp,evmGasLeft)
                        evmGasLeft := chargeGas(evmGasLeft,gasUsed)
                        ip := add(ip, 1)
                    }
                    case 0xFD { // OP_REVERT
                        let offset,size
                
                        popStackCheck(sp, evmGasLeft, 2)
                        offset, sp := popStackItemWithoutCheck(sp)
                        size, sp := popStackItemWithoutCheck(sp)
                
                        // TODO invalid?
                        ensureAcceptableMemLocation(offset)
                        ensureAcceptableMemLocation(size)
                        evmGasLeft := chargeGas(evmGasLeft,expandMemory(add(offset,size)))
                
                        offset := add(offset, MEM_OFFSET_INNER())
                        offset,size := addGasIfEvmRevert(isCallerEVM,offset,size,evmGasLeft)
                
                        revert(offset,size)
                    }
                    case 0xFE { // OP_INVALID
                        evmGasLeft := 0
                
                        revertWithGas(evmGasLeft)
                    }
                    default {
                        printString("INVALID OPCODE")
                        printHex(opcode)
                        revert(0, 0)
                    }
                }
                

                if eq(isCallerEVM, 1) {
                    // Includes gas
                    returnOffset := sub(returnOffset, 32)
                    checkOverflow(returnLen, 32, evmGasLeft)
                    returnLen := add(returnLen, 32)

                    mstore(returnOffset, evmGasLeft)
                }
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            if iszero(isCallerEVM) {
                evmGasLeft := getEVMGas()
                isStatic := getIsStaticFromCallFlags()
            }

            // First, copy the contract's bytecode to be executed into tEdhe `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

            pop($llvm_AlwaysInline_llvm$_warmAddress(address()))

            let returnOffset, returnLen := $llvm_NoInline_llvm$_simulate(isCallerEVM, evmGasLeft, isStatic)
            return(returnOffset, returnLen)
        }
    }
}
