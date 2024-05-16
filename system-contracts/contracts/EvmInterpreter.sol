// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./EvmConstants.sol";
import "./EvmGasManager.sol";
import "./ContractDeployer.sol";
import "./EvmOpcodes.sol";
import "./libraries/SystemContractHelper.sol";

// TODO: move to Constants.sol (need to make contract interfaces)

function _words(uint256 n) pure returns (uint256) {
    // TODO: double check that it is correct
    return (n + 31) >> 5;
}

function max(uint256 a, uint256 b) pure returns (uint256) {
    return a > b ? a : b;
}

uint256 constant MAX_ALLOWED_EVM_CODE_SIZE = 0x6000;
uint256 constant GAS_CALL_STIPEND = 2300;
uint256 constant GAS_COLD_SLOAD = 2100;
uint256 constant GAS_STORAGE_SET = 20000;
uint256 constant GAS_STORAGE_UPDATE = 5000;
uint256 constant GAS_WARM_ACCESS = 100;
uint256 constant GAS_COLD_ACCOUNT_ACCESS = 2600;
uint256 constant GAS_NEW_ACCOUNT = 25000;
uint256 constant GAS_CALL_VALUE = 9000;
uint256 constant GAS_INIT_CODE_WORD_COST = 2;

contract EvmInterpreter {
    /*
        Memory layout:
        - 32 words scratch space
        - 5 words for debugging purposes
        - 1 word for the last returndata size
        - 1024 words stack.
        - Bytecode. (First word is the length of the bytecode)
        - Memory. (First word is the length of the memory)
    */

    uint256 constant DEBUG_SLOT_OFFSET = 32 * 32;
    uint256 constant LAST_RETURNDATA_SIZE_OFFSET = DEBUG_SLOT_OFFSET + 5 * 32;
    uint256 constant STACK_OFFSET = LAST_RETURNDATA_SIZE_OFFSET + 32;
    uint256 constant BYTECODE_OFFSET = STACK_OFFSET + 1024 * 32;

    // Slightly higher just in case
    uint256 constant MAX_POSSIBLE_BYTECODE = 32000;
    uint256 constant MEM_OFFSET = BYTECODE_OFFSET + MAX_POSSIBLE_BYTECODE;

    uint256 constant MEM_OFFSET_INNER = MEM_OFFSET + 32;

    // We can not just pass `gas()`, because it would overflow the gas counter in EVM contracts,
    // but we can pass a limited value, ensuring that the total ergsLeft will never exceed 2bln.
    uint256 constant TO_PASS_INF_GAS = 1e9;

    // Note, that this function can overflow, up to the caller to ensure that it does not.
    function memCost(uint256 memSizeWords) internal pure returns (uint256 gasCost) {
        unchecked {
            gasCost = (memSizeWords * memSizeWords) / 512 + (3 * memSizeWords);
        }
    }

    // To prevent overflows, we always keep memory below 1MB.
    // This constant is chosen in a way that:
    // - expandMemory will never overflow with 2 * MAX_ALLOWED_MEM_SIZE as input
    // - it should never be realistic for an EVM to get that much memory. TODO: possibly enforce that.
    uint256 constant MAX_ALLOWED_MEM_SIZE = 1e6;

    function ensureAcceptableMemLocation(uint256 location) internal pure {
        unchecked {
            require(location < MAX_ALLOWED_MEM_SIZE);
        }
    }

    // This function can overflow, it is the job of the caller to ensure that it does not.
    function expandMemory(uint256 newSize) internal pure returns (uint256 gasCost) {
        unchecked {
            uint256 memOffset = MEM_OFFSET;
            uint256 oldSizeWords;
            assembly {
                oldSizeWords := mload(memOffset)
            }

            uint256 newSizeWords = _words(newSize);

            // old size should be aligned, but align just in case to be on the safe side
            uint256 oldCost = memCost(oldSizeWords);
            uint256 newCost = memCost(newSizeWords);

            if (newSizeWords > oldSizeWords) {
                gasCost = newCost - oldCost;
                assembly ("memory-safe") {
                    mstore(memOffset, newSizeWords)
                }
            }
        }
    }

    function memSize() internal pure returns (uint256 _memSize) {
        uint256 memOffset = MEM_OFFSET;
        assembly {
            _memSize := shl(5, mload(memOffset))
        }
    }

    function _getRawCodeHash(address _account) internal view returns (bytes32 hash) {
        bytes4 selector = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash.selector;
        address to = address(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT);
        assembly {
            mstore(0, selector)
            mstore(4, _account)
            let success := staticcall(gas(), to, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            hash := mload(0)
        }
    }

    function _getDeployedBytecode() internal view {
        uint256 codeLen = _fetchDeployedCode(
            SystemContractHelper.getCodeAddress(),
            BYTECODE_OFFSET + 32,
            MAX_POSSIBLE_BYTECODE
        );

        uint256 bytecodeLenPosition = BYTECODE_OFFSET;
        assembly {
            mstore(bytecodeLenPosition, codeLen)
        }
    }

    /// @dev This function is used to get the initCode.
    /// @dev It assumes that the initCode has been passed via the calldata and so we use the pointer
    /// to obtain the bytecode.
    function _getConstructorBytecode() internal {
        uint256 bytecodeLengthOffset = BYTECODE_OFFSET;
        uint256 bytecodeOffset = BYTECODE_OFFSET + 32;

        SystemContractHelper.loadCalldataIntoActivePtr();
        uint256 size = SystemContractHelper.getActivePtrDataSize();

        assembly {
            mstore(bytecodeLengthOffset, size)
        }

        SystemContractHelper.copyActivePtrData(bytecodeOffset, 0, size);
    }

    // Basically performs an extcodecopy, while returning the length of the bytecode.
    function _fetchDeployedCode(address _addr, uint256 _offset, uint256 _len) internal view returns (uint256 codeLen) {
        bytes32 codeHash = _getRawCodeHash(_addr);

        address to = CODE_ORACLE_SYSTEM_CONTRACT;

        assembly {
            mstore(0, codeHash)
            let success := staticcall(gas(), to, 0, 32, 0, 0)

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
    }

    function _extcodecopy(address _addr, uint256 dest, uint256 offset, uint256 len) internal view {
        address to = address(DEPLOYER_SYSTEM_CONTRACT);

        // Firstly, we zero out everything.
        unchecked {
            uint256 _lastByte = dest + len;
            for (uint i = dest; i < _lastByte; i++) {
                assembly {
                    mstore8(i, 0)
                }
            }
        }

        // Secondly, we get the actual bytecode
        _fetchDeployedCode(_addr, offset, len);
    }

    // Note that this function modifies EVM memory and does not restore it. It is expected that
    // it is the last called function during execution.
    function _setDeployedCode(uint256 gasLeft, uint256 offset, uint256 len) internal {
        // This error should never be triggered
        require(offset > 100, "Offset too small");

        bytes4 selector = DEPLOYER_SYSTEM_CONTRACT.setDeployedCode.selector;
        address to = address(DEPLOYER_SYSTEM_CONTRACT);

        assembly {
            mstore(sub(offset, 100), selector)
            mstore(sub(offset, 96), gasLeft)
            mstore(sub(offset, 64), 0x40)
            mstore(sub(offset, 32), len)

            let success := call(gas(), to, 0, sub(offset, 100), add(len, 100), 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
    }

    function _popStackItem(uint256 tos) internal returns (uint256 a, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET);

            assembly {
                a := mload(tos)
                newTos := sub(tos, 0x20)
            }
        }
    }

    function _pop2StackItems(uint256 tos) internal returns (uint256 a, uint256 b, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 32);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))

                newTos := sub(tos, 0x40)
            }
        }
    }

    function _pop3StackItems(uint256 tos) internal returns (uint256 a, uint256 b, uint256 c, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 64);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))
                c := mload(sub(tos, 0x40))

                newTos := sub(tos, 0x60)
            }
        }
    }

    function _pop4StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 96);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))
                c := mload(sub(tos, 0x40))
                d := mload(sub(tos, 0x60))

                newTos := sub(tos, 0x80)
            }
        }
    }

    function _pop5StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 128);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))
                c := mload(sub(tos, 0x40))
                d := mload(sub(tos, 0x60))
                e := mload(sub(tos, 0x80))

                newTos := sub(tos, 0xa0)
            }
        }
    }

    function _pop6StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 160);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))
                c := mload(sub(tos, 0x40))
                d := mload(sub(tos, 0x60))
                e := mload(sub(tos, 0x80))
                f := mload(sub(tos, 0xa0))

                newTos := sub(tos, 0xc0)
            }
        }
    }

    function _pop7StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 h, uint256 newTos) {
        unchecked {
            // We can not return any error here, because it would break compatibility
            require(tos >= STACK_OFFSET + 192);

            assembly {
                a := mload(tos)
                b := mload(sub(tos, 0x20))
                c := mload(sub(tos, 0x40))
                d := mload(sub(tos, 0x60))
                e := mload(sub(tos, 0x80))
                f := mload(sub(tos, 0xa0))
                h := mload(sub(tos, 0xc0))

                newTos := sub(tos, 0xe0)
            }
        }
    }

    function pushStackItem(uint256 tos, uint256 item) internal returns (uint256 newTos) {
        unchecked {
            require(tos < BYTECODE_OFFSET);

            assembly {
                newTos := add(tos, 0x20)
                mstore(newTos, item)
            }
        }
    }

    // Note, that if `x` is too large, this method can overflow
    function dupStack(uint256 tos, uint256 x) internal returns (uint256 newTos) {
        unchecked {
            uint256 elemPos = tos - x * 32;
            // We can not return any error here, because it would break compatibility
            require(elemPos >= STACK_OFFSET);

            uint256 elem;
            assembly {
                elem := mload(elemPos)
            }

            newTos = pushStackItem(tos, elem);
        }
    }

    // Note, that if `x` is too large, this method can overflow
    function swapStack(uint256 tos, uint256 x) internal {
        unchecked {
            uint256 elemPos = tos - x * 32;

            // We can not return any error here, because it would break compatibility
            require(elemPos >= STACK_OFFSET);

            assembly {
                let elem1 := mload(elemPos)
                let elem2 := mload(tos)

                mstore(elemPos, elem2)
                mstore(tos, elem1)
            }
        }
    }

    // It is the responsibility of the caller to ensure that ip >= BYTECODE_OFFSET + 32
    function readIP(uint256 ip) internal returns (uint256 opcode, bool outOfBounds) {
        uint256 bytecodeOffset = BYTECODE_OFFSET;
        assembly {
            let bytecodeLen := mload(bytecodeOffset)

            let maxAcceptablePos := add(add(bytecodeOffset, bytecodeLen), 31)
            if gt(ip, maxAcceptablePos) {
                // This error should never happen
                outOfBounds := 1
            }

            opcode := and(mload(sub(ip, 31)), 0xff)
        }
    }

    function warmAccount(address _addr) internal returns (bool isWarm) {
        bytes4 selector = EVM_GAS_MANAGER.warmAccount.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            let success := call(gas(), addr, 0, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            isWarm := mload(0)
        }
    }

    function doesAccountExist(address _addr) internal returns (bool accountExists) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_addr)
        }
        return codeSize > 0 || _addr.balance > 0 || getRawNonce(_addr) > 0;
    }

    function isSlotWarm(uint256 key) internal returns (bool isWarm) {
        bytes4 selector = EVM_GAS_MANAGER.isSlotWarm.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)
            mstore(4, key)

            let success := call(gas(), addr, 0, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            isWarm := mload(0)
        }
    }

    function warmSlot(uint256 key, uint256 currentValue) internal returns (bool isWarm, uint256 originalValue) {
        bytes4 selector = EVM_GAS_MANAGER.warmSlot.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)
            mstore(4, key)
            mstore(36, currentValue)

            let success := call(gas(), addr, 0, 0, 68, 0, 64)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            isWarm := mload(0)
            originalValue := mload(32)
        }
    }

    // It is expected that for EVM <> EVM calls both returndata and calldata start with the `gas`.
    modifier paddWithGasAndReturn(
        bool shouldPad,
        uint256 gasToPass,
        uint256 dst
    ) {
        if (shouldPad) {
            uint256 previousValue;
            assembly {
                previousValue := mload(sub(dst, 32))
                mstore(sub(dst, 32), gasToPass)
            }

            _;

            assembly {
                mstore(sub(dst, 32), previousValue)
            }
        } else {
            _;
        }
    }

    function _eraseReturndataPointer() internal {
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_OFFSET;

        uint256 activePtrSize = SystemContractHelper.getActivePtrDataSize();
        SystemContractHelper.ptrShrinkIntoActive(uint32(activePtrSize));
        assembly {
            mstore(lastRtSzOffset, 0)
        }
    }

    function _saveReturnDataAfterEVMCall(
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (uint256 _gasLeft) {
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_OFFSET;
        uint256 rtsz;
        assembly {
            rtsz := returndatasize()
        }

        SystemContractHelper.loadReturndataIntoActivePtr();

        if (rtsz > 31) {
            // There was a normal return. The first 32 bytes are the gasLeft.

            assembly {
                returndatacopy(0, 0, 32)
                _gasLeft := mload(0)

                returndatacopy(_outputOffset, 32, _outputLen)

                mstore(lastRtSzOffset, sub(rtsz, 32))
            }
            // Skipping the returndata data
            SystemContractHelper.ptrAddIntoActive(32);
        } else {
            // Unexpected return data. It means that some fatal mistake has happenned to the callee, so
            // no gas was returned.

            _gasLeft = 0;
            _eraseReturndataPointer();
        }
    }

    function _saveReturnDataAfterZkEVMCall() internal {
        SystemContractHelper.loadReturndataIntoActivePtr();
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_OFFSET;
        assembly {
            mstore(lastRtSzOffset, returndatasize())
        }
    }

    // Returns a pair of `(gasToPay, gasToPass)`
    function getMessageCallGas(
        uint256 _value,
        uint256 _gas,
        uint256 _gasLeft,
        uint256 _memoryCost,
        uint256 _extraGas
    ) internal returns (uint256, uint256) {
        uint256 callStipend;
        if (_value > 0) {
            callStipend = GAS_CALL_STIPEND;
        } else {
            callStipend = 0;
        }

        if (_gasLeft < _extraGas + _memoryCost) {
            // We don't have enough funds to cover for memory growth as well as the cost for the call
            return (_gas + _extraGas, _gas + callStipend);
        }

        uint256 maxGasToPass = _maxAllowedCallGas(_gasLeft - _extraGas - _memoryCost);

        if (_gas > maxGasToPass) {
            _gas = maxGasToPass;
        }

        return (_gas + _extraGas, _gas + callStipend);
    }

    function _performCall(
        bool _calleeIsEVM,
        bool _isStatic,
        uint256 _calleeGas,
        address _callee,
        uint256 _value,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (bool success, uint256 _gasLeft) {
        // Doing calls in static context is allowed. But we need to preserve the static context.
        // In this case, the call becomes equivalent to staticcall.
        // FIXME: decide on how to handle this in tracer
        if (_isStatic) {
            return
                _performStaticCall(
                    _calleeIsEVM,
                    _calleeGas,
                    _callee,
                    _inputOffset,
                    _inputLen,
                    _outputOffset,
                    _outputLen
                );
        }

        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas, _isStatic);
            assembly {
                success := call(
                    // We can not just pass all gas here to prevert overflow of zkEVM gas counter
                    _calleeGas,
                    _callee,
                    _value,
                    _inputOffset,
                    _inputLen,
                    0,
                    0
                )
            }

            _gasLeft = _saveReturnDataAfterEVMCall(_outputOffset, _outputLen);

            _popEVMFrame();
        } else {
            // Performing the conversion
            _calleeGas = _getZkEVMGas(_calleeGas);

            uint256 zkevmGasBefore = gasleft();
            assembly {
                success := call(_calleeGas, _callee, _value, _inputOffset, _inputLen, _outputOffset, _outputLen)
            }

            _saveReturnDataAfterZkEVMCall();

            uint256 gasUsed = _calcEVMGas(zkevmGasBefore - gasleft());

            if (_calleeGas > gasUsed) {
                _gasLeft = _calleeGas - gasUsed;
            } else {
                _gasLeft = 0;
            }
        }
    }

    function _performDelegateCall(
        bool _calleeIsEVM,
        bool _isStatic,
        uint256 _calleeGas,
        address _callee,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (bool success, uint256 _gasLeft) {
        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas, _isStatic);
            assembly {
                success := delegatecall(
                    // We can not just pass all gas here to prevert overflow of zkEVM gas counter
                    _calleeGas,
                    _callee,
                    _inputOffset,
                    _inputLen,
                    0,
                    0
                )
            }

            _gasLeft = _saveReturnDataAfterEVMCall(_outputOffset, _outputLen);

            _popEVMFrame();
        } else {
            // FIXME: decide on how to handle such error
            revert();
        }
    }

    function _performStaticCall(
        bool _calleeIsEVM,
        uint256 _calleeGas,
        address _callee,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (bool success, uint256 _gasLeft) {
        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas, true);
            assembly {
                success := staticcall(
                    // We can not just pass all gas here to prevert overflow of zkEVM gas counter
                    _calleeGas,
                    _callee,
                    _inputOffset,
                    _inputLen,
                    0,
                    0
                )
            }

            _gasLeft = _saveReturnDataAfterEVMCall(_outputOffset, _outputLen);

            _popEVMFrame();
        } else {
            // Performing the conversion
            _calleeGas = _getZkEVMGas(_calleeGas);

            uint256 zkevmGasBefore = gasleft();
            assembly {
                success := staticcall(_calleeGas, _callee, _inputOffset, _inputLen, _outputOffset, _outputLen)
            }
            _saveReturnDataAfterZkEVMCall();

            uint256 gasUsed = _calcEVMGas(zkevmGasBefore - gasleft());

            if (_calleeGas > gasUsed) {
                _gasLeft = _calleeGas - gasUsed;
            } else {
                _gasLeft = 0;
            }
        }
    }

    function _performReturnOrRevert(
        bool _shouldRevert,
        bool _callerIsEVM,
        uint256 _gasLeft,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal paddWithGasAndReturn(_callerIsEVM, _gasLeft, _outputOffset) {
        if (_callerIsEVM) {
            // Includes gas
            _outputOffset -= 32;
            _outputLen += 32;
        }

        if (_shouldRevert) {
            assembly {
                revert(_outputOffset, _outputLen)
            }
        } else {
            assembly {
                return(_outputOffset, _outputLen)
            }
        }
    }

    function _fetchConstructorReturnGas() internal returns (uint256 _constructorGas) {
        bytes4 constructorReturnGasSelector = DEPLOYER_SYSTEM_CONTRACT.constructorReturnGas.selector;
        address to = address(DEPLOYER_SYSTEM_CONTRACT);

        assembly {
            mstore(0, constructorReturnGasSelector)
            let success := staticcall(gas(), to, 0, 4, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            _constructorGas := mload(0)
        }
    }

    // Should be called after create/create2EVM call
    function _processCreateResult(bool success) internal returns (address addr, uint256 gasLeft) {
        if (success) {
            // If success, the returndata should be set to 0 + address was returned
            assembly {
                returndatacopy(0, 0, 32)
                addr := mload(0)
            }

            // reseting the returndata
            _eraseReturndataPointer();

            gasLeft = _fetchConstructorReturnGas();
        } else {
            // If failure, then EVM contract should've returned the gas in the first 32 bytes of the returndata
            gasLeft = _saveReturnDataAfterEVMCall(0, 0);
        }
    }

    modifier store3TmpVars(
        uint256 lastPos,
        uint256 a,
        uint256 b,
        uint256 c
    ) {
        uint256 pos = lastPos - 96;

        uint256 prev1;
        uint256 prev2;
        uint256 prev3;

        assembly {
            prev1 := mload(pos)
            prev2 := mload(add(pos, 0x20))
            prev3 := mload(add(pos, 0x40))

            mstore(pos, a)
            mstore(add(pos, 0x20), b)
            mstore(add(pos, 0x40), c)
        }

        _;

        assembly {
            mstore(pos, prev1)
            mstore(add(pos, 0x20), prev2)
            mstore(add(pos, 0x40), prev3)
        }
    }

    modifier store4TmpVars(
        uint256 lastPos,
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) {
        uint256 pos = lastPos - 128;

        uint256 prev1;
        uint256 prev2;
        uint256 prev3;
        uint256 prev4;

        assembly {
            prev1 := mload(pos)
            prev2 := mload(add(pos, 0x20))
            prev3 := mload(add(pos, 0x40))
            prev4 := mload(add(pos, 0x60))

            mstore(pos, a)
            mstore(add(pos, 0x20), b)
            mstore(add(pos, 0x40), c)
            mstore(add(pos, 0x60), d)
        }

        _;

        assembly {
            mstore(pos, prev1)
            mstore(add(pos, 0x20), prev2)
            mstore(add(pos, 0x40), prev3)
            mstore(add(pos, 0x60), prev4)
        }
    }

    bytes4 constant GET_DEPLOYMENT_NONCE_SELECTOR = NONCE_HOLDER_SYSTEM_CONTRACT.getDeploymentNonce.selector;
    bytes4 constant GET_RAW_NONCE_SELECTOR = NONCE_HOLDER_SYSTEM_CONTRACT.getRawNonce.selector;
    bytes4 constant INCREMENT_DEPLOYMENT_NONCE_SELECTOR =
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce.selector;

    function getNonce(address _addr) internal returns (uint256 nonce) {
        bytes4 selector = GET_DEPLOYMENT_NONCE_SELECTOR;
        address to = address(NONCE_HOLDER_SYSTEM_CONTRACT);
        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            let success := staticcall(gas(), to, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            nonce := mload(0)
        }
    }

    function getRawNonce(address _addr) internal returns (uint256 nonce) {
        bytes4 selector = GET_RAW_NONCE_SELECTOR;
        address to = address(NONCE_HOLDER_SYSTEM_CONTRACT);
        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            let success := staticcall(gas(), to, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            nonce := mload(0)
        }
    }

    function incrementDeploymentNonce(address _addr) internal {
        bytes4 selector = INCREMENT_DEPLOYMENT_NONCE_SELECTOR;
        address to = address(NONCE_HOLDER_SYSTEM_CONTRACT);

        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            let success := call(gas(), to, 0, 0, 36, 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
    }

    function initCodeGas(uint256 _len) internal pure returns (uint256) {
        return GAS_INIT_CODE_WORD_COST * _words(_len);
    }

    // Returns a pair of created address and the new gasLeft.
    function genericCreate(
        address _expectedAddress,
        uint256 _offset,
        uint256 _len,
        uint256 _value,
        uint256 _gasLeft
    ) internal returns (address, uint256) {
        warmAccount(_expectedAddress);

        _eraseReturndataPointer();

        uint256 gasForTheCall = _maxAllowedCallGas(_gasLeft);
        _gasLeft -= gasForTheCall;

        /*
            In the execution spec the following check is present here:
            ```python
                if (
                sender.balance < endowment
                or sender.nonce == Uint(2**64 - 1)
                or evm.message.depth + 1 > STACK_DEPTH_LIMIT
            ):
                evm.gas_left += create_message_gas
                push(evm.stack, U256(0))
                return
            ```

            We do not check for for nonce as it is not feasible to achieve that high of a nonce, while it would
            introduce unncecessary computation. 

            We also can not support max stack depth in a feasible way, so we do not check it either.
        */
        if (address(this).balance < _value) {
            _gasLeft += gasForTheCall;
            return (address(0), _gasLeft);
        }

        uint256 targetNonce = getNonce(_expectedAddress);
        uint256 targetCodeSize;
        assembly {
            targetCodeSize := extcodesize(_expectedAddress)
        }

        /*
        ```python
            if account_has_code_or_nonce(evm.env.state, contract_address):
                increment_nonce(evm.env.state, evm.message.current_target)
                push(evm.stack, U256(0))
                return
        ```

        Note, that this part can not be moved to ContractDeployer, because it will revert & so rollback those changes
        */
        if (targetNonce > 0 || targetCodeSize > 0) {
            incrementDeploymentNonce(address(this));
            return (address(0), _gasLeft);
        }

        // Max allowed EVM code size
        require(_len <= 2 * MAX_ALLOWED_EVM_CODE_SIZE);

        incrementDeploymentNonce(address(this));

        (address _createdAddress, uint256 gasLeftFromFrame) = _performCreateCall(
            _expectedAddress,
            gasForTheCall,
            _value,
            _offset,
            _len
        );

        _gasLeft += gasLeftFromFrame;

        return (_createdAddress, _gasLeft);
    }

    uint32 constant CREATE_EVM_INTERNAL_SELECTOR = uint32(DEPLOYER_SYSTEM_CONTRACT.createEVMInternal.selector);

    function _performCreateCall(
        address _deployedAddress,
        uint256 _calleeGas,
        uint256 _value,
        uint256 _inputOffset,
        uint256 _inputLen
    )
        internal
        store4TmpVars(_inputOffset, CREATE_EVM_INTERNAL_SELECTOR, uint256(uint160(_deployedAddress)), 64, _inputLen)
        returns (address addr, uint256 gasLeft)
    {
        _pushEVMFrame(_calleeGas, false);
        address to = address(DEPLOYER_SYSTEM_CONTRACT);
        bool success;
        uint256 _addr;
        uint256 zkevmGas = TO_PASS_INF_GAS;

        assembly {
            success := call(zkevmGas, to, _value, sub(_inputOffset, 100), add(_inputLen, 100), 0, 0)
        }

        if (success) {
            // reseting the returndata
            gasLeft = _fetchConstructorReturnGas();
            addr = _deployedAddress;
        } else {
            // If failure, then EVM contract should've returned the gas in the first 32 bytes of the returndata
            gasLeft = _saveReturnDataAfterEVMCall(0, 0);
        }

        _popEVMFrame();
    }

    constructor() {
        uint256 evmGas;
        bool isCallerEVM;
        bool isStatic;

        (evmGas, isStatic, isCallerEVM) = _consumeEvmFrame();

        // This error should be never triggered. In any case, we return nothing just in case to preserve
        // compatibility.
        require(!isStatic);

        _getConstructorBytecode();

        if (!isCallerEVM) {
            evmGas = _getEVMGas();
        }

        (uint256 offset, uint256 len, uint256 gasToReturn) = _simulate(isCallerEVM, msg.data[0:0], evmGas, false);

        gasToReturn = validateCorrectBytecode(offset, len, gasToReturn);

        (offset, len) = padBytecode(offset, len);

        _setDeployedCode(gasToReturn, offset, len);
    }

    uint256 constant GAS_CODE_DEPOSIT = 200;

    /// This function assumes that `len` can only be a reasoable value, otherwise it might overflow.
    function validateCorrectBytecode(uint256 offset, uint256 len, uint256 gasToReturn) internal returns (uint256) {
        unchecked {
            if (len > 0) {
                uint256 firstByte;
                assembly {
                    firstByte := shr(mload(offset), 248)
                }
                // Check for invalid contract prefix.
                require(firstByte != 0xEF);
            }
            uint256 gasForCode = len * GAS_CODE_DEPOSIT;
            return chargeGas(gasToReturn, gasForCode);
        }
    }

    /// zkEVM requires all bytecodes that can be decommitted into the memory to be at leas t
    function padBytecode(uint256 _offset, uint256 _len) internal pure returns (uint256 blobOffset, uint256 blobLen) {
        blobOffset = _offset - 32;
        uint256 trueLastByte = _offset + _len;

        assembly {
            mstore(blobOffset, _len)
            // clearing out additional bytes
            mstore(trueLastByte, 0)
            mstore(add(trueLastByte, 32), 0)
        }

        blobLen = _len + 32;
        if (blobLen % 32 != 0) {
            blobLen += 32 - (blobLen % 32);
        }

        // Not it is divisible by 32, but we must make sure that the number of 32 byte words is odd
        if (blobLen % 64 != 32) {
            blobLen += 32;
        }
    }

    function dbg(uint256 _tos, uint256 _ip, uint256 _opcode, uint256 _gasleft) internal {
        uint256 offset = DEBUG_SLOT_OFFSET;
        assembly {
            mstore(add(offset, 0x20), _ip)
            mstore(add(offset, 0x40), _tos)
            mstore(add(offset, 0x60), _gasleft)
            mstore(add(offset, 0x80), _opcode)
            mstore(offset, 0x4A15830341869CAA1E99840C97043A1EA15D2444DA366EFFF5C43B4BEF299681)
        }
    }

    function chargeGas(uint256 prevGas, uint256 toCharge) internal returns (uint256 gasRemaining) {
        unchecked {
            // I can not return any readable error to preserve compatibility
            require(prevGas >= toCharge);
            gasRemaining = prevGas - toCharge;
        }
    }

    /// Executes the EVM bytecode and returns a triple of (offset, len, gas) to return to the caller.
    function _simulate(
        bool isCallerEVM,
        bytes calldata input,
        uint256 gasLeft,
        bool isStatic
    ) internal returns (uint256, uint256, uint256) {
        uint256 memOffset = MEM_OFFSET_INNER;

        uint256 _bytecodeLen;
        {
            uint256 bytecodeOffset = BYTECODE_OFFSET;
            assembly {
                _bytecodeLen := mload(bytecodeOffset)
            }
        }

        unchecked {
            uint256 _ergTracking = gasleft();

            // program counter (pc is taken in assembly, so ip = instruction pointer)
            uint256 ip = BYTECODE_OFFSET + 32;

            // top of stack - index to first stack element; empty stack = -1
            // (this is simpler than tos = stack.length, cleaner code)
            // note it is technically possible to underflow due to the unchecked
            // but that will immediately revert due to out of bounds memory access -> out of gas
            uint256 tos = STACK_OFFSET - 32;

            // emit OverheadTrace(_ergTracking - gasleft());
            while (true) {
                // _ergTracking = gasleft();
                // optimization: opcode is uint256 instead of uint8 otherwise every op will trim bits every time
                uint256 opcode;

                {
                    bool outOfBounds = false;
                    (opcode, outOfBounds) = readIP(ip);

                    if (outOfBounds) {
                        opcode = OP_STOP;
                    }
                }

                dbg(tos, ip, opcode, gasLeft);

                ip++;

                // ALU 1 - arithmetic-logic opcodes group (1 out of 2)
                if (opcode < GRP_ALU1) {
                    // optimization: STOP is part of group ALU 1
                    if (opcode == OP_STOP) {
                        return (memOffset, 0, gasLeft);
                    }

                    uint256 a;
                    uint256 b;
                    uint256 result;

                    (a, tos) = _popStackItem(tos);
                    (b, tos) = _popStackItem(tos);

                    if (opcode == OP_ADD) {
                        result = a + b;
                        gasLeft = chargeGas(gasLeft, 3);
                    } else if (opcode == OP_MUL) {
                        result = a * b;
                        gasLeft = chargeGas(gasLeft, 5);
                    } else if (opcode == OP_SUB) {
                        result = a - b;
                        gasLeft = chargeGas(gasLeft, 3);
                    } else if (opcode == OP_DIV) {
                        assembly ("memory-safe") {
                            result := div(a, b)
                        }
                        gasLeft = chargeGas(gasLeft, 5);
                    } else if (opcode == OP_SDIV) {
                        assembly ("memory-safe") {
                            result := sdiv(a, b)
                        }
                        gasLeft = chargeGas(gasLeft, 5);
                    } else if (opcode == OP_MOD) {
                        assembly ("memory-safe") {
                            result := mod(a, b)
                        }
                        gasLeft = chargeGas(gasLeft, 5);
                    } else if (opcode == OP_SMOD) {
                        assembly ("memory-safe") {
                            result := smod(a, b)
                        }
                        gasLeft = chargeGas(gasLeft, 5);
                    } else if (opcode == OP_ADDMOD) {
                        uint256 n;
                        (n, tos) = _popStackItem(tos);
                        assembly ("memory-safe") {
                            result := addmod(a, b, n)
                        }
                        gasLeft = chargeGas(gasLeft, 8);
                    } else if (opcode == OP_MULMOD) {
                        uint256 n;
                        (n, tos) = _popStackItem(tos);
                        assembly ("memory-safe") {
                            result := mulmod(a, b, n)
                        }
                        gasLeft = chargeGas(gasLeft, 8);
                    } else if (opcode == OP_EXP) {
                        result = a ** b;

                        uint256 toCharge = 10;
                        while (b > 0) {
                            toCharge += 50;
                            b >>= 8;
                        }

                        gasLeft = chargeGas(gasLeft, toCharge);
                    } else if (opcode == OP_SIGNEXTEND) {
                        assembly ("memory-safe") {
                            result := signextend(a, b)
                        }
                        gasLeft = chargeGas(gasLeft, 5);
                    }

                    tos = pushStackItem(tos, result);

                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // ALU 2 - arithmetic-logic opcodes group (2 out of 2)
                if (opcode < GRP_ALU2) {
                    uint256 result;
                    if (opcode == OP_NOT) {
                        uint256 a;
                        (a, tos) = _popStackItem(tos);

                        result = ~a;
                    } else if (opcode == OP_ISZERO) {
                        uint256 a;
                        (a, tos) = _popStackItem(tos);

                        if (a == 0) {
                            result = 1;
                        } else {
                            result = 0;
                        }
                    } else {
                        uint256 a;
                        uint256 b;

                        (a, tos) = _popStackItem(tos);
                        (b, tos) = _popStackItem(tos);

                        if (opcode == OP_LT) {
                            assembly ("memory-safe") {
                                result := lt(a, b)
                            }
                        } else if (opcode == OP_GT) {
                            assembly ("memory-safe") {
                                result := gt(a, b)
                            }
                        } else if (opcode == OP_SLT) {
                            assembly ("memory-safe") {
                                result := slt(a, b)
                            }
                        } else if (opcode == OP_SGT) {
                            assembly ("memory-safe") {
                                result := sgt(a, b)
                            }
                        } else if (opcode == OP_EQ) {
                            assembly ("memory-safe") {
                                result := eq(a, b)
                            }
                        } else if (opcode == OP_AND) {
                            result = (a & b);
                        } else if (opcode == OP_OR) {
                            result = (a | b);
                        } else if (opcode == OP_XOR) {
                            result = (a ^ b);
                        } else if (opcode == OP_BYTE) {
                            assembly ("memory-safe") {
                                result := byte(b, a)
                            }
                        } else if (opcode == OP_SHL) {
                            result = (b << a);
                        } else if (opcode == OP_SHR) {
                            result = (b >> a);
                        } else if (opcode == OP_SAR) {
                            assembly ("memory-safe") {
                                result := sar(a, b)
                            }
                        }
                    }

                    tos = pushStackItem(tos, result);
                    gasLeft = chargeGas(gasLeft, 3);
                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // evm state & more misc opcodes
                if (opcode < GRP_VM_STATE) {
                    // TODO: optimize this group by sorting opcodes by popularity & gas cost (cheaper first)

                    if (opcode == OP_KECCAK256) {
                        uint256 ost;
                        uint256 len;

                        (ost, tos) = _popStackItem(tos);
                        (len, tos) = _popStackItem(tos);

                        ensureAcceptableMemLocation(len);
                        ensureAcceptableMemLocation(ost);
                        uint256 toCharge = 30 + 6 * _words(len) + expandMemory(ost + len);

                        gasLeft = chargeGas(gasLeft, toCharge);

                        uint256 val;
                        assembly ("memory-safe") {
                            val := keccak256(add(memOffset, ost), len)
                        }
                        tos = pushStackItem(tos, val);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_ADDRESS) {
                        tos = pushStackItem(tos, uint256(uint160(address(this))));
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BALANCE) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        tos = pushStackItem(tos, address(uint160(addr)).balance);
                        // TODO: dynamic gas cost (simply 2600 if cold...)
                        gasLeft = chargeGas(gasLeft, 100);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_ORIGIN) {
                        tos = pushStackItem(tos, uint256(uint160(tx.origin)));
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLER) {
                        tos = pushStackItem(tos, uint256(uint160(msg.sender)));
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLVALUE) {
                        tos = pushStackItem(tos, uint256(uint160(msg.value)));
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATALOAD) {
                        uint256 idx;
                        (idx, tos) = _popStackItem(tos);

                        uint256 val;

                        // It is assumed that the input is always the last part of the calldata
                        // and it encompasses the entire intended calldata.
                        assembly {
                            // TODO: double check if non zero `input.offset` should be even allowed, otherwise an overflow might happen
                            val := calldataload(add(input.offset, idx))
                        }

                        tos = pushStackItem(tos, val);
                        gasLeft = chargeGas(gasLeft, 3);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATASIZE) {
                        tos = pushStackItem(tos, input.length);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATACOPY) {
                        uint256 dstOst;
                        uint256 ost;
                        uint256 len;

                        (dstOst, tos) = _popStackItem(tos);
                        (ost, tos) = _popStackItem(tos);
                        (len, tos) = _popStackItem(tos);

                        // Preventing overflow.
                        ensureAcceptableMemLocation(dstOst);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 3 + 3 * _words(len) + expandMemory(dstOst + len);

                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            calldatacopy(add(memOffset, dstOst), add(input.offset, ost), len)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CODESIZE) {
                        tos = pushStackItem(tos, _bytecodeLen);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CODECOPY) {
                        // NOTE: since code is in memory this is essentially memcopy
                        // pretty expensive, need to think how to optimize

                        uint256 dstOst;
                        uint256 ost;
                        uint256 len;

                        (dstOst, tos) = _popStackItem(tos);
                        (ost, tos) = _popStackItem(tos);
                        (len, tos) = _popStackItem(tos);

                        // Preventing overflow.
                        ensureAcceptableMemLocation(dstOst);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 3 + 3 * _words(len) + expandMemory(dstOst + len);

                        // TODO: double check whether the require below is needed
                        // require(ost + len <= _bytecodeLen, "codecopy: bytecode too long");

                        gasLeft = chargeGas(gasLeft, toCharge);

                        // basically BYTECODE_OFFSET + 32 - 31, since
                        // we always need to read one byte
                        uint256 bytecodeOffsetInner = BYTECODE_OFFSET + 1;
                        // TODO: optimize this
                        for (uint256 i = 0; i < len; i++) {
                            if (ost + i < _bytecodeLen) {
                                assembly {
                                    mstore8(
                                        add(add(memOffset, dstOst), i),
                                        and(mload(add(add(bytecodeOffsetInner, ost), i)), 0xff)
                                    )
                                }
                            } else {
                                assembly {
                                    mstore8(add(add(memOffset, dstOst), i), 0)
                                }
                            }
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GASPRICE) {
                        tos = pushStackItem(tos, tx.gasprice);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODESIZE) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            gasLeft = chargeGas(gasLeft, 100);
                        } else {
                            gasLeft = chargeGas(gasLeft, 2600);
                        }

                        uint256 res;
                        assembly {
                            res := extcodesize(addr)
                        }

                        tos = pushStackItem(tos, res);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODECOPY) {
                        uint256 addr;
                        uint256 destOffset;
                        uint256 offset;
                        uint256 size;

                        (addr, destOffset, offset, size, tos) = _pop4StackItems(tos);

                        uint256 toCharge;

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            toCharge = 100;
                        } else {
                            toCharge = 2600;
                        }

                        ensureAcceptableMemLocation(size);
                        ensureAcceptableMemLocation(destOffset);

                        toCharge +=
                            3 *
                            _words(size) + // word copy cost
                            expandMemory(destOffset + size); // memory expansion

                        gasLeft = chargeGas(gasLeft, toCharge);

                        _extcodecopy(address(uint160(addr)), destOffset, offset, size);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATASIZE) {
                        uint256 rsz;
                        uint256 rszOffset = LAST_RETURNDATA_SIZE_OFFSET;

                        gasLeft = chargeGas(gasLeft, 2);

                        assembly {
                            rsz := mload(rszOffset)
                        }

                        tos = pushStackItem(tos, rsz);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATACOPY) {
                        uint256 dstOst;
                        uint256 ost;
                        uint256 len;

                        (dstOst, ost, len, tos) = _pop3StackItems(tos);

                        ensureAcceptableMemLocation(len);
                        ensureAcceptableMemLocation(dstOst);

                        gasLeft = chargeGas(gasLeft, expandMemory(dstOst + len));

                        SystemContractHelper.copyActivePtrData(memOffset + dstOst, ost, len);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODEHASH) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            gasLeft = chargeGas(gasLeft, 100);
                        } else {
                            gasLeft = chargeGas(gasLeft, 2600);
                        }

                        uint256 result;
                        assembly {
                            result := extcodehash(addr)
                        }

                        tos = pushStackItem(tos, result);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_TIMESTAMP) {
                        tos = pushStackItem(tos, block.timestamp);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_NUMBER) {
                        tos = pushStackItem(tos, block.number);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CHAINID) {
                        tos = pushStackItem(tos, block.chainid);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SELFBALANCE) {
                        tos = pushStackItem(tos, address(this).balance);
                        gasLeft = chargeGas(gasLeft, 5);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BLOCKHASH) {
                        uint256 blockNumber;
                        (blockNumber, tos) = _popStackItem(tos);
                        gasLeft = chargeGas(gasLeft, 20);

                        tos = pushStackItem(tos, uint256(blockhash(blockNumber)));
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_COINBASE) {
                        tos = pushStackItem(tos, uint256(uint160(address(block.coinbase))));
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_PREVRANDAO) {
                        gasLeft = chargeGas(gasLeft, 2);

                        // formerly known as DIFFICULTY
                        tos = pushStackItem(tos, block.difficulty);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GASLIMIT) {
                        gasLeft = chargeGas(gasLeft, 2);

                        tos = pushStackItem(tos, block.gaslimit);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BASEFEE) {
                        gasLeft = chargeGas(gasLeft, 2);

                        tos = pushStackItem(tos, block.basefee);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                // misc group: memory, control flow and more
                if (opcode < GRP_MISC) {
                    if (opcode == OP_POP) {
                        gasLeft = chargeGas(gasLeft, 2);

                        (, tos) = _popStackItem(tos);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MLOAD) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);

                        ensureAcceptableMemLocation(ost);
                        gasLeft = chargeGas(gasLeft, 3 + expandMemory(ost));

                        uint256 val;
                        assembly ("memory-safe") {
                            val := mload(add(memOffset, ost))
                        }

                        tos = pushStackItem(tos, val);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);
                        uint256 val;
                        (val, tos) = _popStackItem(tos);

                        ensureAcceptableMemLocation(ost);

                        gasLeft = chargeGas(gasLeft, 3 + expandMemory(ost));

                        assembly ("memory-safe") {
                            mstore(add(memOffset, ost), val)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE8) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);
                        uint256 val;
                        (val, tos) = _popStackItem(tos);

                        ensureAcceptableMemLocation(ost);
                        gasLeft = chargeGas(gasLeft, 3 + expandMemory(ost));

                        assembly ("memory-safe") {
                            mstore8(add(memOffset, ost), val)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SLOAD) {
                        uint256 key;

                        (key, tos) = _popStackItem(tos);

                        bool isWarm = isSlotWarm(key);

                        // extra cost if account is cold
                        if (isWarm) {
                            gasLeft = chargeGas(gasLeft, GAS_WARM_ACCESS);
                        } else {
                            gasLeft = chargeGas(gasLeft, GAS_COLD_SLOAD);
                        }

                        uint256 result;
                        assembly ("memory-safe") {
                            result := sload(key)
                        }

                        if (!isWarm) {
                            warmSlot(key, result);
                        }

                        tos = pushStackItem(tos, result);

                        // need not to worry about gas refunds as it happens outside the evm
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SSTORE) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 key;
                        uint256 val;

                        (key, tos) = _popStackItem(tos);
                        (val, tos) = _popStackItem(tos);

                        require(gasLeft > GAS_CALL_STIPEND);

                        // Here it is okay to read before we charge since we known anyway that
                        // the context has enough funds to compensate at least for the read.
                        uint256 currentValue;
                        assembly {
                            currentValue := sload(key)
                        }
                        (bool wasWarm, uint256 originalValue) = warmSlot(key, currentValue);

                        uint256 gasCost;

                        if (!wasWarm) {
                            // The slot has been warmed up before
                            gasCost += GAS_COLD_SLOAD;
                        }

                        if (originalValue == currentValue && currentValue != val) {
                            if (originalValue == 0) {
                                gasCost += GAS_STORAGE_SET;
                            } else {
                                gasCost += GAS_STORAGE_UPDATE - GAS_COLD_SLOAD;
                            }
                        } else {
                            gasCost += GAS_WARM_ACCESS;
                        }

                        // Need not to worry about gas refunds as it happens outside the EVM

                        gasLeft = chargeGas(gasLeft, gasCost);

                        assembly ("memory-safe") {
                            sstore(key, val)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                    // NOTE: We don't currently do full jumpdest validation (i.e. validating a jumpdest isn't in PUSH data)
                    if (opcode == OP_JUMP) {
                        gasLeft = chargeGas(gasLeft, 8);

                        uint256 dest;
                        (dest, tos) = _popStackItem(tos);

                        ip = BYTECODE_OFFSET + dest + 32;

                        uint256 _newOpcode;
                        bool outOfbounds;
                        (_newOpcode, outOfbounds) = readIP(ip);

                        require(!outOfbounds, "interpreter: JUMP: out of bounds");
                        require(_newOpcode == OP_JUMPDEST, "interpreter: JUMP: invalid destination");

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                    // NOTE: We don't currently do full jumpdest validation (i.e. validating a jumpdest isn't in PUSH data)
                    if (opcode == OP_JUMPI) {
                        gasLeft = chargeGas(gasLeft, 10);

                        uint256 dest;
                        uint256 cond;

                        (dest, cond, tos) = _pop2StackItems(tos);

                        if (cond > 0) {
                            ip = BYTECODE_OFFSET + dest + 32;

                            (uint256 _newOpcode, bool outOfbounds) = readIP(ip);
                            require(!outOfbounds, "interpreter: JUMP: out of bounds");
                            require(_newOpcode == OP_JUMPDEST, "interpreter: JUMP: invalid destination");
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_PC) {
                        // compensate for pc++ earlier
                        tos = pushStackItem(tos, ip - BYTECODE_OFFSET - 32);
                        gasLeft = chargeGas(gasLeft, 2);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSIZE) {
                        gasLeft = chargeGas(gasLeft, 2);

                        tos = pushStackItem(tos, memSize());
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GAS) {
                        // GAS opcode gives the remaining gas *after* consuming the opcode
                        gasLeft = chargeGas(gasLeft, 2);

                        tos = pushStackItem(tos, gasLeft);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_JUMPDEST) {
                        gasLeft = chargeGas(gasLeft, 1);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                // stack operations (PUSH, DUP, SWAP) and LOGs
                if (opcode < GRP_STACK_AND_LOGS) {
                    if (opcode == OP_PUSH0) {
                        gasLeft = chargeGas(gasLeft, 2);

                        tos = pushStackItem(tos, 0);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_PUSH) {
                        // PUSHx
                        gasLeft = chargeGas(gasLeft, 3);

                        uint256 len = opcode - OP_PUSH0;
                        uint256 num = 0;
                        // TODO: this can be optimized by reading uint256 from code then shr by ((0x7f - opcode) * 8)
                        for (uint256 i = 0; i < len; i++) {
                            (uint256 _opcode, bool overflow) = readIP(ip + i);

                            if (overflow) {
                                assembly {
                                    revert(0, 0)
                                }
                            }

                            num = (num << 8) | _opcode;
                        }

                        tos = pushStackItem(tos, num);
                        ip += len;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_DUP) {
                        // DUPx
                        gasLeft = chargeGas(gasLeft, 3);

                        uint256 ost = opcode - 0x80; //0x7F;
                        tos = dupStack(tos, ost);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_SWAP) {
                        // SWAPx
                        gasLeft = chargeGas(gasLeft, 3);

                        uint256 ost = opcode - 0x8F;
                        swapStack(tos, ost);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG0) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 ost;
                        uint256 len;
                        (ost, len, tos) = _pop2StackItems(tos);

                        ensureAcceptableMemLocation(ost);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 375 + 8 * len + expandMemory(ost + len);
                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            log0(add(memOffset, ost), len)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG1) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 ost;
                        uint256 len;
                        uint256 topic0;

                        (ost, len, topic0, tos) = _pop3StackItems(tos);

                        ensureAcceptableMemLocation(ost);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 750 + 8 * len + expandMemory(ost + len);
                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            log1(add(memOffset, ost), len, topic0)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG2) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;

                        (ost, len, topic0, topic1, tos) = _pop4StackItems(tos);

                        ensureAcceptableMemLocation(ost);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 1125 + 8 * len + expandMemory(ost + len);
                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            log2(add(memOffset, ost), len, topic0, topic1)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG3) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;
                        uint256 topic2;

                        (ost, len, topic0, topic1, topic2, tos) = _pop5StackItems(tos);

                        ensureAcceptableMemLocation(ost);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 1500 + 8 * len + expandMemory(ost + len);
                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            log3(add(memOffset, ost), len, topic0, topic1, topic2)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG4) {
                        // We can not return a readable error to preserve compatibility
                        require(!isStatic);

                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;
                        uint256 topic2;
                        uint256 topic3;

                        (ost, len, topic0, topic1, topic2, topic3, tos) = _pop6StackItems(tos);

                        ensureAcceptableMemLocation(ost);
                        ensureAcceptableMemLocation(len);

                        uint256 toCharge = 1875 + 8 * len + expandMemory(ost + len);
                        gasLeft = chargeGas(gasLeft, toCharge);

                        assembly ("memory-safe") {
                            log4(add(memOffset, ost), len, topic0, topic1, topic2, topic3)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                if (opcode == OP_CALL) {
                    uint256 gas;
                    uint256 addr;
                    uint256 value;
                    uint256 argOst;
                    uint256 argLen;
                    uint256 retOst;
                    uint256 retLen;

                    (gas, addr, value, argOst, argLen, retOst, retLen, tos) = _pop7StackItems(tos);

                    ensureAcceptableMemLocation(argOst);
                    ensureAcceptableMemLocation(argLen);
                    ensureAcceptableMemLocation(retOst);
                    ensureAcceptableMemLocation(retLen);

                    // The separation betweeen `memoryExpansionCost` and `extraCost` is done
                    // only to keep the code closer to the execution spec.
                    // In essense their sum could be used as just one variable.
                    uint256 memoryExpansionCost = expandMemory(max(argOst + argLen, retOst + retLen));

                    uint256 extraCost = 0;
                    if (warmAccount(address(uint160(addr)))) {
                        extraCost = GAS_WARM_ACCESS;
                    } else {
                        extraCost = GAS_COLD_ACCOUNT_ACCESS;
                    }
                    if (!doesAccountExist(address(uint160(addr)))) {
                        extraCost += GAS_NEW_ACCOUNT;
                    }
                    if (value > 0) {
                        require(!isStatic);
                        extraCost += GAS_CALL_VALUE;
                    }

                    (uint256 gasToPay, uint256 gasToPass) = getMessageCallGas(
                        value,
                        gas,
                        gasLeft,
                        memoryExpansionCost,
                        extraCost
                    );

                    gasLeft = chargeGas(gasLeft, memoryExpansionCost + gasToPay);

                    (bool success, uint256 frameGasLeft) = _performCall(
                        _isEVM(address(uint160(addr))),
                        isStatic,
                        gasToPass,
                        address(uint160(addr)),
                        value,
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

                    // We assume no overflow here
                    gasLeft += frameGasLeft;

                    continue;
                }

                if (opcode == OP_DELEGATECALL) {
                    uint256 gas;
                    uint256 addr;
                    uint256 argOst;
                    uint256 argLen;
                    uint256 retOst;
                    uint256 retLen;

                    (gas, addr, argOst, argLen, retOst, retLen, tos) = _pop6StackItems(tos);

                    ensureAcceptableMemLocation(argOst);
                    ensureAcceptableMemLocation(argLen);
                    ensureAcceptableMemLocation(retOst);
                    ensureAcceptableMemLocation(retLen);

                    // The separation betweeen `memoryExpansionCost` and `extraCost` is done
                    // only to keep the code closer to the execution spec.
                    // In essense their sum could be used as just one variable.
                    uint256 memoryExpansionCost = expandMemory(max(argOst + argLen, retOst + retLen));

                    uint256 extraCost = 0;

                    if (warmAccount(address(uint160(addr)))) {
                        extraCost = GAS_WARM_ACCESS;
                    } else {
                        extraCost = GAS_COLD_ACCOUNT_ACCESS;
                    }

                    (uint256 gasToPay, uint256 gasToPass) = getMessageCallGas(
                        0,
                        gas,
                        gasLeft,
                        memoryExpansionCost,
                        extraCost
                    );

                    gasLeft = chargeGas(gasLeft, gasToPay);

                    (bool success, uint256 frameGasLeft) = _performDelegateCall(
                        _isEVM(address(uint160(addr))),
                        isStatic,
                        gasToPass,
                        address(uint160(addr)),
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

                    // We assume no overflow here
                    gasLeft += frameGasLeft;

                    continue;
                }

                if (opcode == OP_STATICCALL) {
                    uint256 gas;
                    uint256 addr;
                    uint256 argOst;
                    uint256 argLen;
                    uint256 retOst;
                    uint256 retLen;

                    (gas, addr, argOst, argLen, retOst, retLen, tos) = _pop6StackItems(tos);

                    // The separation betweeen `memoryExpansionCost` and `extraCost` is done
                    // only to keep the code closer to the execution spec.
                    // In essence their sum could be used as just one variable.
                    uint256 memoryExpansionCost = expandMemory(max(argOst + argLen, retOst + retLen));

                    uint256 extraCost = 0;

                    if (warmAccount(address(uint160(addr)))) {
                        extraCost = GAS_WARM_ACCESS;
                    } else {
                        extraCost = GAS_COLD_ACCOUNT_ACCESS;
                    }

                    (uint256 gasToPay, uint256 gasToPass) = getMessageCallGas(
                        0,
                        gas,
                        gasLeft,
                        memoryExpansionCost,
                        extraCost
                    );

                    gasLeft = chargeGas(gasLeft, gasToPay);

                    (bool success, uint256 frameGasLeft) = _performStaticCall(
                        _isEVM(address(uint160(addr))),
                        gasToPass,
                        address(uint160(addr)),
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

                    // No overflow is assumed here
                    gasLeft += frameGasLeft;

                    continue;
                }

                if (opcode == OP_REVERT) {
                    uint256 ost;
                    uint256 len;

                    (ost, len, tos) = _pop2StackItems(tos);

                    ensureAcceptableMemLocation(ost);
                    ensureAcceptableMemLocation(len);

                    gasLeft = chargeGas(gasLeft, expandMemory(ost + len));

                    _performReturnOrRevert(true, isCallerEVM, gasLeft, ost + memOffset, len);
                }

                if (opcode == OP_RETURN) {
                    uint256 ost;
                    uint256 len;

                    (ost, len, tos) = _pop2StackItems(tos);

                    ensureAcceptableMemLocation(ost);
                    ensureAcceptableMemLocation(len);
                    gasLeft = chargeGas(gasLeft, expandMemory(ost + len));

                    return (ost + memOffset, len, gasLeft);
                }

                if (opcode == OP_CREATE) {
                    // We can not return a readable error to preserve compatibility
                    require(!isStatic);

                    uint256 val;
                    uint256 ost;
                    uint256 len;

                    (val, ost, len, tos) = _pop3StackItems(tos);

                    ensureAcceptableMemLocation(len);
                    ensureAcceptableMemLocation(ost);

                    gasLeft = chargeGas(gasLeft, 32000 + initCodeGas(len) + expandMemory(ost + len));

                    address expectedAddress = Utils.getNewAddressCreateEVM(address(this), getNonce(address(this)));

                    address addr;
                    (addr, gasLeft) = genericCreate(expectedAddress, ost + memOffset, len, val, gasLeft);

                    tos = pushStackItem(tos, uint256(uint160(addr)));

                    continue;
                }

                if (opcode == OP_CREATE2) {
                    // We can not return a readable error to preserve compatibility
                    require(!isStatic);

                    uint256 val;
                    uint256 ost;
                    uint256 len;
                    uint256 salt;

                    (val, ost, len, salt, tos) = _pop4StackItems(tos);

                    ensureAcceptableMemLocation(len);
                    ensureAcceptableMemLocation(ost);

                    gasLeft = chargeGas(gasLeft, 32000 + initCodeGas(len) + expandMemory(ost + len));

                    bytes32 _bytecodeHash;
                    assembly {
                        _bytecodeHash := keccak256(add(memOffset, ost), len)
                    }

                    address expectedAddress = Utils.getNewAddressCreate2EVM(
                        address(this),
                        bytes32(salt),
                        _bytecodeHash
                    );

                    address addr;
                    (addr, gasLeft) = genericCreate(expectedAddress, ost + memOffset, len, val, gasLeft);

                    tos = pushStackItem(tos, uint256(uint160(addr)));

                    continue;
                }

                revert("interpreter: invalid opcode");
            } // while
        } // unchecked
    }

    function _maxAllowedCallGas(uint256 _gasLeft) internal pure returns (uint256) {
        unchecked {
            return _gasLeft - _gasLeft / 64;
        }
    }

    function _maxCallGas(uint256 gasLimit, uint256 gasLeft) internal pure returns (uint256) {
        unchecked {
            uint256 maxGas = _maxAllowedCallGas(gasLeft);
            if (gasLimit > maxGas) {
                return maxGas;
            }

            return gasLimit;
        }
    }

    function _isEVM(address _addr) internal view returns (bool isEVM) {
        bytes4 selector = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM.selector;
        address addr = address(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT);
        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            let success := staticcall(gas(), addr, 0, 36, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            isEVM := mload(0)
        }
    }

    function _pushEVMFrame(uint256 _passGas, bool _isStatic) internal {
        bytes4 selector = EVM_GAS_MANAGER.pushEVMFrame.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)
            mstore(4, _passGas)
            mstore(36, _isStatic)

            let success := call(gas(), addr, 0, 0, 68, 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
    }

    function _popEVMFrame() internal {
        bytes4 selector = EVM_GAS_MANAGER.popEVMFrame.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)

            let success := call(gas(), addr, 0, 0, 4, 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }
    }

    function _consumeEvmFrame() internal returns (uint256 _passGas, bool isStatic, bool callerEVM) {
        bytes4 selector = EVM_GAS_MANAGER.consumeEvmFrame.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)

            let success := call(gas(), addr, 0, 0, 4, 0, 64)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            _passGas := mload(0)
            isStatic := mload(32)
        }

        if (_passGas != INF_PASS_GAS) {
            callerEVM = true;
        }
    }

    // Each evm gas is 5 zkEVM one
    // FIXME: change this variable to reflect real ergs : gas ratio
    uint256 constant GAS_DIVISOR = 5;
    uint256 constant EVM_GAS_STIPEND = (1 << 30);
    uint256 constant OVERHEAD = 2000;

    function _calcEVMGas(uint256 zkevmGas) internal pure returns (uint256) {
        return zkevmGas / GAS_DIVISOR;
    }

    function _getEVMGas() internal view returns (uint256) {
        uint256 _gas = gasleft();
        uint256 requiredGas = EVM_GAS_STIPEND + OVERHEAD;

        if (_gas < requiredGas) {
            return 0;
        } else {
            return (_gas - requiredGas) / GAS_DIVISOR;
        }
    }

    function _getZkEVMGas(uint256 _evmGas) internal view returns (uint256) {
        /*
            TODO: refine the formula, especially with regard to decommitment costs
        */
        return _evmGas * GAS_DIVISOR;
    }

    // If the caller is a zkEVM contract and
    function _getIsStaticFromCallFlags() internal view returns (bool) {
        uint256 callFlags = SystemContractHelper.getCallFlags();
        // TODO: make it a constnat
        return (callFlags & 0x04) != 0;
    }

    function _ensureThisIsEVM() internal view {
        // Here we return readable error as this error can be only triggered by zkEVM -> EVM delegatecall
        require(_isEVM(address(this)), "interpreter: not an EVM contract");
    }

    fallback() external payable {
        // This is needed to avoid zkEVM contracts doing accidental delegatecalls
        // to EVM contracts.
        _ensureThisIsEVM();

        bytes calldata input;
        uint256 evmGas;
        bool isCallerEVM;
        bool isStatic;

        (evmGas, isStatic, isCallerEVM) = _consumeEvmFrame();

        if (!isCallerEVM) {
            evmGas = _getEVMGas();
            isStatic = _getIsStaticFromCallFlags();
        }

        input = msg.data;
        _getDeployedBytecode();

        warmAccount(address(uint160(address(this))));
        (uint256 retOffset, uint256 retLen, uint256 gasLeft) = _simulate(isCallerEVM, input, evmGas, isStatic);

        _performReturnOrRevert(false, isCallerEVM, gasLeft, retOffset, retLen);

        // revert("interpreter: unreachable");
    }
}

/*

We need the following memory:
- Scratch space (10 words)
- Bytecode (1k words)
- Stack (1024 words)
- Unlimited memory space

Rules of inter frame gas:

call (accept):
- caller is zkEVM -> convert
- caller is EVM -> first 32 bytes are gas

call (action):
- Forbidden callees -> return(0,0)
- EVM callees -> gas + data

return/revert:
- caller is zkEVM -> plain return
- caller is EVM -> gas + return
- panic -> return with no data

*/
