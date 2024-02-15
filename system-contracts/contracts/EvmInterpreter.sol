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
    return (n + 31) >> 5;
}

function max(uint256 a, uint256 b) pure returns (uint256) {
    return a > b ? a : b;
}

contract EvmInterpreter {
    /*
        Memory layout:
        - 32 words scratch space
        - 1024 words stack.
        - Bytecode. (First word is the length of the bytecode)
        - Memory. (First word is the length of the bytecode)
    */

    /*
        We must avoid polluting the memory of the contract, so we have to do raw calls
    */

    uint256 constant DEBUG_SLOT_OFFSET = 32 * 32;
    uint256 constant LAST_RETURNDATA_SIZE_LENGTH = DEBUG_SLOT_OFFSET + 5 * 32;
    uint256 constant STACK_OFFSET = LAST_RETURNDATA_SIZE_LENGTH + 32;
    uint256 constant BYTECODE_OFFSET = 32 * 1024 + STACK_OFFSET;
    // Slightly higher just in case
    uint256 constant MAX_POSSIBLE_BYTECODE = 32000;
    uint256 constant MEM_OFFSET = BYTECODE_OFFSET + MAX_POSSIBLE_BYTECODE;

    uint256 constant MEM_OFFSET_INNER = MEM_OFFSET + 32;

    // We can not just pass `gas()`, because it would overflow the gas counter in EVM contracts,
    // but we can pass a limited value, ensuring that the total ergsLeft will never exceed 2bln.
    uint256 constant TO_PASS_INF_GAS = 1e9;

    function memCost(uint256 memSize) internal pure returns (uint256 gasCost) {
        gasCost = (memSize * memSize) / 512 + (3 * memSize);
    }

    function expandMemory(uint256 newSize) internal pure returns (uint256 gasCost) {
        unchecked {
            uint256 memOffset = MEM_OFFSET;
            uint256 oldSize;
            assembly {
                oldSize := mload(memOffset)
            }

            if (newSize > oldSize) {
                // old size should be aligned, but align just in case to be on the safe side
                uint256 oldSizeWords = _words(oldSize);
                uint256 newSizeWords = _words(newSize);

                uint256 oldCost = memCost(oldSizeWords);
                uint256 newCost = memCost(newSizeWords);

                gasCost = newCost - oldCost;
                assembly ("memory-safe") {
                    let size := shl(5, newSizeWords)
                    mstore(memOffset, size)
                }
            }
        }
    }

    function memSize() internal pure returns (uint256 memSize) {
        uint256 memOffset = MEM_OFFSET;
        assembly {
            memSize := mload(memOffset)
        }
    }

    // function _getConstructorEVMGas() internal returns (uint256 _evmGas) {
    //     bytes4 selector = DEPLOYER_SYSTEM_CONTRACT.constructorGas.selector;
    //     address to = address(DEPLOYER_SYSTEM_CONTRACT);

    //     assembly {
    //         mstore(0, selector)
    //         mstore(4, address())

    //         let success := staticcall(
    //             gas(),
    //             to,
    //             0,
    //             36,
    //             0,
    //             0
    //         )

    //         if iszero(success) {
    //             // This error should never happen
    //             revert(0, 0)
    //         }

    //         returndatacopy(
    //             0,
    //             0,
    //             32
    //         )

    //         _evmGas := mload(0)
    //     }
    // }

    function _getBytecode() internal {
        bytes4 selector = DEPLOYER_SYSTEM_CONTRACT.evmCode.selector;
        address to = address(DEPLOYER_SYSTEM_CONTRACT);
        uint256 bytecodeLengthOffset = BYTECODE_OFFSET;
        uint256 bytecodeOffset = BYTECODE_OFFSET + 32;

        assembly {
            mstore(0, selector)
            mstore(4, address())

            let success := staticcall(gas(), to, 0, 36, 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            returndatacopy(
                bytecodeLengthOffset,
                // Skip 0x20
                32,
                sub(returndatasize(), 32)
            )
        }
    }

    function _extcodecopy(address _addr, uint256 dest, uint256 offset, uint256 len) internal view {
        bytes4 selector = DEPLOYER_SYSTEM_CONTRACT.evmCode.selector;
        address to = address(DEPLOYER_SYSTEM_CONTRACT);

        // TODO: This is not very efficient

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
        assembly {
            mstore(0, selector)
            mstore(4, _addr)

            // TODO: test how it behaves on corner cases
            let success := staticcall(gas(), to, 0, 36, 0, 0)

            // Note that it is not 'actual' bytecode size as the returndata might've been padded
            // to be divisible by 32, but for the purposes here it is enough, since padded bytes are zeroes
            let bytecodeSize := sub(returndatasize(), 64)

            let rtOffset := add(offset, 64)

            if lt(returndatasize(), rtOffset) {
                rtOffset := returndatasize()
            }

            if gt(add(rtOffset, len), returndatasize()) {
                len := sub(returndatasize(), rtOffset)
            }

            returndatacopy(dest, rtOffset, len)
        }
    }

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

    function _popStackItem(uint256 tos) internal returns (uint256 val, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET, "interpreter: stack underflow");

        assembly {
            val := mload(tos)
            newTos := sub(tos, 0x20)
        }
    }

    // a = stack[tos]
    // b = stack[tos - 1]
    function _pop2StackItems(uint256 tos) internal returns (uint256 a, uint256 b, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 32, "interpreter: stack underflow");

        assembly {
            a := mload(tos)
            b := mload(sub(tos, 0x20))

            newTos := sub(tos, 64)
        }
    }

    function _pop3StackItems(uint256 tos) internal returns (uint256 a, uint256 b, uint256 c, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 64, "interpreter: stack underflow");

        assembly {
            a := mload(tos)
            b := mload(sub(tos, 0x20))
            c := mload(sub(tos, 0x40))

            newTos := sub(tos, 0x60)
        }
    }

    function _pop4StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 96, "interpreter: stack underflow");

        assembly {
            a := mload(tos)
            b := mload(sub(tos, 0x20))
            c := mload(sub(tos, 0x40))
            d := mload(sub(tos, 0x60))

            newTos := sub(tos, 0x80)
        }
    }

    function _pop5StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 96, "interpreter: stack underflow");

        assembly {
            a := mload(tos)
            b := mload(sub(tos, 0x20))
            c := mload(sub(tos, 0x40))
            d := mload(sub(tos, 0x60))
            e := mload(sub(tos, 0x80))

            newTos := sub(tos, 0xa0)
        }
    }

    function _pop6StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 96, "interpreter: stack underflow");

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

    function _pop7StackItems(
        uint256 tos
    ) internal returns (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 h, uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos >= STACK_OFFSET + 96, "interpreter: stack underflow");

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

    function pushStackItem(uint256 tos, uint256 item) internal returns (uint256 newTos) {
        // TODO: remove this error for more compatibility
        require(tos < BYTECODE_OFFSET, "interpreter: stack overflow");

        assembly {
            newTos := add(tos, 0x20)
            mstore(newTos, item)
        }
    }

    function dupStack(uint256 tos, uint256 x) internal returns (uint256 newTos) {
        uint256 elemPos = tos - x * 32;
        // TODO: remove his error
        require(elemPos >= STACK_OFFSET, "interpreter: stack underflow (dupStack)");

        uint256 elem;
        assembly {
            elem := mload(elemPos)
        }

        newTos = pushStackItem(tos, elem);
    }

    function swapStack(uint256 tos, uint256 x) internal {
        uint256 elemPos = tos - x * 32;

        require(elemPos >= STACK_OFFSET, "interpreter: stack underflow (swapStack)");

        assembly {
            let elem1 := mload(elemPos)
            let elem2 := mload(tos)

            mstore(elemPos, elem2)
            mstore(tos, elem1)
        }
    }

    function unsafeReadIP(uint256 ip) internal returns (uint256 opcode) {
        assembly {
            opcode := and(mload(sub(ip, 31)), 0xff)
        }
    }

    function readIP(uint256 ip) internal returns (uint256 opcode, bool outOfBounds) {
        uint256 bytecodeOffset = BYTECODE_OFFSET;
        uint256 bytecodeLen;
        assembly {
            bytecodeLen := mload(bytecodeOffset)

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

    function warmSlot(uint256 key) internal returns (bool isWarm) {
        bytes4 selector = EVM_GAS_MANAGER.warmSlot.selector;
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

    // It is expected that for EVM <> EVM calls both returndata and calldata start with the `gas`.
    modifier paddWithGasAndReturn(
        bool shouldPad,
        uint256 gasToPass,
        uint256 dst
    ) {
        if (shouldPad) {
            uint256 tmp;
            assembly {
                tmp := mload(sub(dst, 32))
                mstore(sub(dst, 32), gasToPass)
            }

            _;

            assembly {
                mstore(sub(dst, 32), tmp)
            }
        } else {
            _;
        }
    }

    function _eraseRtPointer() internal {
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_LENGTH;

        // Erase the active pointer +
        uint256 previousRtSz = SystemContractHelper.getActivePtrDataSize();
        SystemContractHelper.ptrShrinkIntoActive(uint32(previousRtSz));
        assembly {
            mstore(lastRtSzOffset, 0)
        }
    }

    function _saveReturnDataAfterEVMCall(
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (uint256 _gasLeft) {
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_LENGTH;
        uint256 rtsz;
        assembly {
            rtsz := returndatasize()
        }

        SystemContractHelper.loadReturndataIntoActivePtr();

        if (rtsz > 31) {
            assembly {
                returndatacopy(0, 0, 32)
                _gasLeft := mload(0)

                returndatacopy(_outputOffset, 32, _outputLen)

                mstore(lastRtSzOffset, sub(rtsz, 32))
            }
            // Skipping the returndata data
            SystemContractHelper.ptrAddIntoActive(32);
        } else {
            _gasLeft = 0;
            _eraseRtPointer();
        }
    }

    function _saveReturnDataAfterZkEVMCall() internal {
        SystemContractHelper.loadReturndataIntoActivePtr();
        uint256 lastRtSzOffset = LAST_RETURNDATA_SIZE_LENGTH;
        assembly {
            mstore(lastRtSzOffset, returndatasize())
        }
    }

    function _performCall(
        bool _calleeIsEVM,
        uint256 _calleeGas,
        address _callee,
        uint256 _value,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (bool success, uint256 _gasLeft) {
        uint256 memOffset = MEM_OFFSET_INNER;

        /*
            TODO Please do not overwrite the returndata
        */

        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas);
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

            uint256 tmp = gasleft();
            assembly {
                success := call(_calleeGas, _callee, _value, _inputOffset, _inputLen, _outputOffset, _outputLen)
            }

            _saveReturnDataAfterZkEVMCall();

            uint256 gasUsed = _calcEVMGas(tmp - gasleft());

            if (_calleeGas > gasUsed) {
                _gasLeft = _calleeGas - gasUsed;
            } else {
                _gasLeft = 0;
            }
        }
    }

    function _performDelegateCall(
        bool _calleeIsEVM,
        uint256 _calleeGas,
        address _callee,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _outputOffset,
        uint256 _outputLen
    ) internal returns (bool success, uint256 _gasLeft) {
        uint256 memOffset = MEM_OFFSET_INNER;

        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas);
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
            // ToDO: remove this error for compatibility
            revert("delegatecall to zkevm unallowed");
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
        uint256 memOffset = MEM_OFFSET_INNER;
        /*
            TODO Please do not overwrite the returndata
        */

        if (_calleeIsEVM) {
            _pushEVMFrame(_calleeGas);
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

            uint256 tmp = gasleft();
            assembly {
                success := staticcall(_calleeGas, _callee, _inputOffset, _inputLen, _outputOffset, _outputLen)
            }
            _saveReturnDataAfterZkEVMCall();

            uint256 gasUsed = _calcEVMGas(tmp - gasleft());

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
        uint256 memOffset = MEM_OFFSET_INNER;

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
        // If success, the returndata should be set to 0 + address was returned
        if (success) {
            assembly {
                returndatacopy(0, 0, 32)
                addr := mload(0)
            }

            // reseting the returndata
            _eraseRtPointer();

            gasLeft = _fetchConstructorReturnGas();
        } else {
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
            mstore(add(pos, 0x40), prev4)
        }
    }

    uint32 constant CREATE_SELECTOR = uint32(DEPLOYER_SYSTEM_CONTRACT.createEVM.selector);
    uint32 constant CREATE2_SELECTOR = uint32(DEPLOYER_SYSTEM_CONTRACT.create2EVM.selector);

    function _performCreate(
        uint256 _calleeGas,
        uint256 _value,
        uint256 _inputOffset,
        uint256 _inputLen
    ) internal store3TmpVars(_inputOffset, CREATE_SELECTOR, 32, _inputLen) returns (address addr, uint256 gasLeft) {
        _pushEVMFrame(_calleeGas);

        address to = address(DEPLOYER_SYSTEM_CONTRACT);
        bool success;

        uint256 _addr;

        uint256 zkevmGas = TO_PASS_INF_GAS;

        assembly {
            success := call(zkevmGas, to, _value, sub(_inputOffset, 68), add(_inputLen, 68), 0, 0)
        }

        (addr, gasLeft) = _processCreateResult(success);

        _popEVMFrame();
    }

    function _performCreate2(
        uint256 _calleeGas,
        uint256 _value,
        uint256 _inputOffset,
        uint256 _inputLen,
        uint256 _salt
    )
        internal
        store4TmpVars(_inputOffset, CREATE2_SELECTOR, _salt, 64, _inputLen)
        returns (address addr, uint256 gasLeft)
    {
        _pushEVMFrame(_calleeGas);
        address to = address(DEPLOYER_SYSTEM_CONTRACT);

        bool success;

        uint256 _addr;

        uint256 zkevmGas = TO_PASS_INF_GAS;

        assembly {
            success := call(zkevmGas, to, _value, sub(_inputOffset, 100), add(_inputLen, 100), 0, 32)
        }

        (addr, gasLeft) = _processCreateResult(success);

        _popEVMFrame();
    }

    // TODO: make sure it also supplies the gas left for the EVM caller
    constructor() {
        uint256 evmGas;
        bool isCallerEVM;

        (evmGas, isCallerEVM) = _consumePassGas();
        _getBytecode();

        if (!isCallerEVM) {
            evmGas = _getEVMGas();
        }

        (uint256 offset, uint256 len, uint256 gasToReturn) = _simulate(isCallerEVM, msg.data[0:0], evmGas);

        _setDeployedCode(gasToReturn, offset, len);
    }

    // using EvmUtils for bytes;

    // event OverheadTrace(uint256 gasUsage);
    // event OpcodeTrace(uint256 opcode, uint256 gasUsage);

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

    /*

    Should return (offset, len, gas) to return to the callee.

    This slice may include any mem size

    */

    function _simulate(
        bool isCallerEVM,
        bytes calldata input,
        uint256 gasLeft
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

            // temp storage for many various operations
            uint256 tmp = 0;

            // program counter (pc is taken in assembly, so ip = instruction pointer)
            uint256 ip = BYTECODE_OFFSET + 32;

            // top of stack - index to first stack element; empty stack = -1
            // (this is simpler than tos = stack.length, cleaner code)
            // note it is technically possible to underflow due to the unchecked
            // but that will immediately revert due to out of bounds memory access -> out of gas
            uint256 tos = STACK_OFFSET - 32;

            // emit OverheadTrace(_ergTracking - gasleft());
            while (true) {
                _ergTracking = gasleft();
                // optimization: opcode is uint256 instead of uint8 otherwise every op will trim bits every time
                uint256 opcode;

                // check for stack overflow/underflow

                // TODO: we potentially might need to perform this after each opcode
                if (int256(gasLeft) < 0) {
                    assembly {
                        revert(0, 0)
                    }
                }

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

                    (a, tos) = _popStackItem(tos);
                    (b, tos) = _popStackItem(tos);

                    if (opcode == OP_ADD) {
                        tmp = a + b;
                        gasLeft -= 3;
                    } else if (opcode == OP_MUL) {
                        tmp = a * b;
                        gasLeft -= 5;
                    } else if (opcode == OP_SUB) {
                        tmp = a - b;
                        gasLeft -= 3;
                    } else if (opcode == OP_DIV) {
                        assembly ("memory-safe") {
                            tmp := div(a, b)
                        }
                        gasLeft -= 5;
                    } else if (opcode == OP_SDIV) {
                        assembly ("memory-safe") {
                            tmp := sdiv(a, b)
                        }
                        gasLeft -= 5;
                    } else if (opcode == OP_MOD) {
                        assembly ("memory-safe") {
                            tmp := mod(a, b)
                        }
                        gasLeft -= 5;
                    } else if (opcode == OP_SMOD) {
                        assembly ("memory-safe") {
                            tmp := smod(a, b)
                        }
                        gasLeft -= 5;
                    } else if (opcode == OP_ADDMOD) {
                        uint256 n;
                        (n, tos) = _popStackItem(tos);
                        assembly ("memory-safe") {
                            tmp := addmod(a, b, n)
                        }
                        gasLeft -= 8;
                    } else if (opcode == OP_MULMOD) {
                        uint256 n;
                        (n, tos) = _popStackItem(tos);
                        assembly ("memory-safe") {
                            tmp := mulmod(a, b, n)
                        }
                        gasLeft -= 8;
                    } else if (opcode == OP_EXP) {
                        tmp = a ** b;
                        gasLeft -= 10;
                        while (b > 0) {
                            gasLeft -= 50;
                            b >>= 8;
                        }
                    } else if (opcode == OP_SIGNEXTEND) {
                        assembly ("memory-safe") {
                            tmp := signextend(a, b)
                        }
                        gasLeft -= 5;
                    }

                    tos = pushStackItem(tos, tmp);

                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // ALU 2 - arithmetic-logic opcodes group (2 out of 2)
                if (opcode < GRP_ALU2) {
                    if (opcode == OP_NOT) {
                        uint256 a;
                        (a, tos) = _popStackItem(tos);

                        tmp = ~a;
                    } else if (opcode == OP_ISZERO) {
                        uint256 a;
                        (a, tos) = _popStackItem(tos);

                        if (a == 0) {
                            tmp = 1;
                        } else {
                            tmp = 0;
                        }
                    } else {
                        uint256 a;
                        uint256 b;

                        (a, tos) = _popStackItem(tos);
                        (b, tos) = _popStackItem(tos);

                        if (opcode == OP_LT) {
                            assembly ("memory-safe") {
                                tmp := lt(a, b)
                            }
                        } else if (opcode == OP_GT) {
                            assembly ("memory-safe") {
                                tmp := gt(a, b)
                            }
                        } else if (opcode == OP_SLT) {
                            assembly ("memory-safe") {
                                tmp := slt(a, b)
                            }
                        } else if (opcode == OP_SGT) {
                            assembly ("memory-safe") {
                                tmp := sgt(a, b)
                            }
                        } else if (opcode == OP_EQ) {
                            assembly ("memory-safe") {
                                tmp := eq(a, b)
                            }
                        } else if (opcode == OP_AND) {
                            tmp = (a & b);
                        } else if (opcode == OP_OR) {
                            tmp = (a | b);
                        } else if (opcode == OP_XOR) {
                            tmp = (a ^ b);
                        } else if (opcode == OP_BYTE) {
                            assembly ("memory-safe") {
                                tmp := byte(b, a)
                            }
                        } else if (opcode == OP_SHL) {
                            tmp = (b << a);
                        } else if (opcode == OP_SHR) {
                            tmp = (b >> a);
                        } else if (opcode == OP_SAR) {
                            assembly ("memory-safe") {
                                tmp := sar(a, b)
                            }
                        }
                    }

                    tos = pushStackItem(tos, tmp);
                    gasLeft -= 3;
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

                        gasLeft -=
                            30 + // base cost
                            6 *
                            _words(len) + // cost per word
                            expandMemory(ost + len); // memory expansion

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
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BALANCE) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        tos = pushStackItem(tos, address(uint160(addr)).balance);
                        // TODO: dynamic gas cost (simply 2600 if cold...)
                        gasLeft -= 100;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_ORIGIN) {
                        tos = pushStackItem(tos, uint256(uint160(tx.origin)));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLER) {
                        tos = pushStackItem(tos, uint256(uint160(msg.sender)));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLVALUE) {
                        tos = pushStackItem(tos, uint256(uint160(msg.value)));
                        gasLeft -= 2;
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
                            val := calldataload(add(input.offset, idx))
                        }

                        tos = pushStackItem(tos, val);
                        gasLeft -= 3;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATASIZE) {
                        tos = pushStackItem(tos, input.length);
                        gasLeft -= 2;
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

                        gasLeft -=
                            3 + // base cost
                            3 *
                            _words(len) + // word copy cost
                            expandMemory(dstOst + len); // memory expansion

                        assembly ("memory-safe") {
                            calldatacopy(add(memOffset, dstOst), add(input.offset, ost), len)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CODESIZE) {
                        tos = pushStackItem(tos, _bytecodeLen);
                        gasLeft -= 2;
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

                        // TODO: double check whether the require below is needed
                        // require(ost + len <= _bytecodeLen, "codecopy: bytecode too long");

                        gasLeft -=
                            3 + // base cost
                            3 *
                            _words(len) + // word copy cost
                            expandMemory(dstOst + len); // memory expansion

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
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODESIZE) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        uint256 res;
                        assembly {
                            res := extcodesize(addr)
                        }

                        tos = pushStackItem(tos, res);

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODECOPY) {
                        uint256 addr;
                        uint256 destOffset;
                        uint256 offset;
                        uint256 size;

                        (addr, destOffset, offset, size, tos) = _pop4StackItems(tos);

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        gasLeft -=
                            3 *
                            _words(size) + // word copy cost
                            expandMemory(destOffset + size); // memory expansion

                        _extcodecopy(address(uint160(addr)), destOffset, offset, size);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATASIZE) {
                        uint256 rsz;
                        uint256 rszOffset = LAST_RETURNDATA_SIZE_LENGTH;
                        assembly {
                            rsz := mload(rszOffset)
                        }

                        tos = pushStackItem(tos, rsz);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATACOPY) {
                        uint256 dstOst;
                        uint256 ost;
                        uint256 len;

                        (dstOst, ost, len, tos) = _pop3StackItems(tos);

                        gasLeft -= expandMemory(dstOst + len);

                        SystemContractHelper.copyActivePtrData(memOffset + dstOst, ost, len);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODEHASH) {
                        uint256 addr;
                        (addr, tos) = _popStackItem(tos);

                        uint256 result;
                        assembly {
                            result := extcodehash(addr)
                        }

                        // extra cost if account is cold
                        if (warmAccount(address(uint160(addr)))) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        tos = pushStackItem(tos, result);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_TIMESTAMP) {
                        tos = pushStackItem(tos, block.timestamp);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_NUMBER) {
                        tos = pushStackItem(tos, block.number);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CHAINID) {
                        tos = pushStackItem(tos, block.chainid);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SELFBALANCE) {
                        tos = pushStackItem(tos, address(this).balance);
                        gasLeft -= 5;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BLOCKHASH) {
                        uint256 blockNumber;
                        (blockNumber, tos) = _popStackItem(tos);

                        tos = pushStackItem(tos, uint256(blockhash(blockNumber)));
                        gasLeft -= 20;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_COINBASE) {
                        tos = pushStackItem(tos, uint256(uint160(address(block.coinbase))));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_PREVRANDAO) {
                        // formerly known as DIFFICULTY
                        tos = pushStackItem(tos, block.difficulty);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GASLIMIT) {
                        tos = pushStackItem(tos, block.gaslimit);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BASEFEE) {
                        tos = pushStackItem(tos, block.basefee);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                // misc group: memory, control flow and more
                if (opcode < GRP_MISC) {
                    if (opcode == OP_POP) {
                        (, tos) = _popStackItem(tos);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MLOAD) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);
                        uint256 val;

                        assembly ("memory-safe") {
                            val := mload(add(memOffset, ost))
                        }
                        gasLeft -= 3 + expandMemory(ost + 32);

                        tos = pushStackItem(tos, val);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);
                        uint256 val;
                        (val, tos) = _popStackItem(tos);

                        assembly ("memory-safe") {
                            mstore(add(memOffset, ost), val)
                        }

                        gasLeft -= 3 + expandMemory(ost + 32);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE8) {
                        uint256 ost;
                        (ost, tos) = _popStackItem(tos);
                        uint256 val;
                        (val, tos) = _popStackItem(tos);

                        assembly ("memory-safe") {
                            mstore8(add(memOffset, ost), val)
                        }

                        gasLeft -= 3 + expandMemory(ost + 1);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SLOAD) {
                        uint256 key;

                        (key, tos) = _popStackItem(tos);

                        uint256 tmp;
                        assembly ("memory-safe") {
                            tmp := sload(key)
                        }
                        tos = pushStackItem(tos, tmp);

                        // extra cost if account is cold
                        if (warmSlot(key)) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2100;
                        }

                        // need not to worry about gas refunds as it happens outside the evm
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SSTORE) {
                        uint256 key;
                        uint256 val;

                        (key, tos) = _popStackItem(tos);
                        (val, tos) = _popStackItem(tos);

                        assembly ("memory-safe") {
                            sstore(key, val)
                        }

                        // TODO: those are not the *exact* same rules
                        // extra cost if account is cold
                        if (warmSlot(key)) {
                            gasLeft -= 100;
                            // } else if (val == 0) {
                            //     gasLeft -= 5000; // 2900 + 2100
                        } else {
                            gasLeft -= 22100; // 20000 + 2100
                        }

                        // need not to worry about gas refunds as it happens outside the evm
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                    // NOTE: We don't currently do full jumpdest validation (i.e. validating a jumpdest isn't in PUSH data)
                    if (opcode == OP_JUMP) {
                        gasLeft -= 8;

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
                        gasLeft -= 10;

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
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSIZE) {
                        tos = pushStackItem(tos, memSize());
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GAS) {
                        // GAS opcode gives the remaining gas *after* consuming the opcode
                        gasLeft -= 2;
                        tos = pushStackItem(tos, gasLeft);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_JUMPDEST) {
                        gasLeft -= 1;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                // stack operations (PUSH, DUP, SWAP) and LOGs
                if (opcode < GRP_STACK_AND_LOGS) {
                    if (opcode == OP_PUSH0) {
                        tos = pushStackItem(tos, 0);
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_PUSH) {
                        // PUSHx
                        uint256 len = opcode - OP_PUSH0;
                        uint256 num = 0;
                        // TODO: this can be optimized by reading uint256 from code then shr by ((0x7f - opcode) * 8)
                        for (uint256 i = 0; i < len; i++) {
                            (uint256 opcode, bool overflow) = readIP(ip + i);

                            if (overflow) {
                                assembly {
                                    revert(0, 0)
                                }
                            }

                            num = (num << 8) | opcode;
                        }

                        tos = pushStackItem(tos, num);
                        ip += len;
                        gasLeft -= 3;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_DUP) {
                        // DUPx
                        uint256 ost = opcode - 0x80; //0x7F;
                        gasLeft -= 3;
                        tos = dupStack(tos, ost);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_SWAP) {
                        // SWAPx
                        uint256 ost = opcode - 0x8F;
                        gasLeft -= 3;
                        swapStack(tos, ost);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG0) {
                        uint256 ost;
                        uint256 len;
                        (ost, len, tos) = _pop2StackItems(tos);

                        assembly ("memory-safe") {
                            log0(add(memOffset, ost), len)
                        }

                        gasLeft -=
                            375 + // base cost
                            8 *
                            len + // word copy cost
                            expandMemory(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG1) {
                        uint256 ost;
                        uint256 len;
                        uint256 topic0;

                        (ost, len, topic0, tos) = _pop3StackItems(tos);

                        assembly ("memory-safe") {
                            log1(add(memOffset, ost), len, topic0)
                        }

                        gasLeft -=
                            750 + // base cost
                            8 *
                            len + // word copy cost
                            expandMemory(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG2) {
                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;

                        (ost, len, topic0, topic1, tos) = _pop4StackItems(tos);

                        assembly ("memory-safe") {
                            log2(add(memOffset, ost), len, topic0, topic1)
                        }

                        gasLeft -=
                            1125 + // base cost
                            8 *
                            len + // word copy cost
                            expandMemory(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG3) {
                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;
                        uint256 topic2;

                        (ost, len, topic0, topic1, topic2, tos) = _pop5StackItems(tos);

                        assembly ("memory-safe") {
                            log3(add(memOffset, ost), len, topic0, topic1, topic2)
                        }

                        gasLeft -=
                            1500 + // base cost
                            8 *
                            len + // word copy cost
                            expandMemory(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG4) {
                        uint256 ost;
                        uint256 len;
                        uint256 topic0;
                        uint256 topic1;
                        uint256 topic2;
                        uint256 topic3;

                        (ost, len, topic0, topic1, topic2, topic3, tos) = _pop6StackItems(tos);

                        assembly ("memory-safe") {
                            log4(add(memOffset, ost), len, topic0, topic1, topic2, topic3)
                        }

                        gasLeft -=
                            1875 + // base cost
                            8 *
                            len + // word copy cost
                            expandMemory(ost + len); // memory expansion

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

                    if (value != 0) {
                        uint256 codeSize;
                        assembly {
                            codeSize := extcodesize(addr)
                        }

                        /*
                        If value is not 0, then positive_value_cost is 9000.
                        In this case there is also a call stipend that is given to
                        make sure that a basic fallback function can be called.
                        2300 is thus removed from the cost, and also added to the gas input.
                        */
                        // that is, 9000 minus 2300 stipend going towards gas limit
                        // and another 25000 added to the 9000 - 2300 if
                        if (codeSize == 0) {
                            // if value AND account empty:
                            gasLeft -= 31700; // 25000 + (9000 - 2300);
                        } else {
                            // if value AND account not empty:
                            gasLeft -= 6700; // 9000 - 2300;
                        }

                        // call stipend: https://github.com/ethereum/go-ethereum/blob/576681f29b895dd39e559b7ba17fcd89b42e4833/core/vm/instructions.go#L659
                        gas += 2300;
                    }

                    gasLeft -= expandMemory(max(argOst + argLen, retOst + retLen));

                    // extra cost if account is cold:
                    // If address is warm, then address_access_cost is 100, otherwise it is 2600.
                    if (warmAccount(address(uint160(addr)))) {
                        gasLeft -= 100;
                    } else {
                        gasLeft -= 2600;
                    }

                    gas = _maxCallGas(gas, gasLeft);

                    gasLeft -= gas;
                    (bool success, uint256 frameGasLeft) = _performCall(
                        _isEVM(address(uint160(addr))),
                        gas,
                        address(uint160(addr)),
                        value,
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

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

                    gasLeft -= expandMemory(max(argOst + argLen, retOst + retLen));

                    // extra cost if account is cold:
                    // If address is warm, then address_access_cost is 100, otherwise it is 2600.
                    if (warmAccount(address(uint160(addr)))) {
                        gasLeft -= 100;
                    } else {
                        gasLeft -= 2600;
                    }

                    gas = _maxCallGas(gas, gasLeft);

                    gasLeft -= gas;
                    (bool success, uint256 frameGasLeft) = _performDelegateCall(
                        _isEVM(address(uint160(addr))),
                        gas,
                        address(uint160(addr)),
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

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

                    gasLeft -= expandMemory(max(argOst + argLen, retOst + retLen));

                    // extra cost if account is cold:
                    // If address is warm, then address_access_cost is 100, otherwise it is 2600.
                    if (warmAccount(address(uint160(addr)))) {
                        gasLeft -= 100;
                    } else {
                        gasLeft -= 2600;
                    }

                    gas = _maxCallGas(gas, gasLeft);
                    gasLeft -= gas;
                    (bool success, uint256 frameGasLeft) = _performStaticCall(
                        _isEVM(address(uint160(addr))),
                        gas,
                        address(uint160(addr)),
                        argOst + memOffset,
                        argLen,
                        retOst + memOffset,
                        retLen
                    );

                    tos = pushStackItem(tos, success ? 1 : 0);

                    gasLeft += frameGasLeft;

                    continue;
                }

                if (opcode == OP_REVERT) {
                    uint256 ost;
                    uint256 len;

                    (ost, len, tos) = _pop2StackItems(tos);

                    gasLeft -= expandMemory(ost + len);

                    _performReturnOrRevert(true, isCallerEVM, gasLeft, ost + memOffset, len);
                }

                if (opcode == OP_RETURN) {
                    uint256 ost;
                    uint256 len;

                    (ost, len, tos) = _pop2StackItems(tos);

                    // FIXME: double check thaat we still have enough gas
                    gasLeft -= expandMemory(ost + len);

                    return (ost + memOffset, len, gasLeft);
                }

                if (opcode == OP_CREATE) {
                    uint256 val;
                    uint256 ost;
                    uint256 len;

                    // TODO: dobule check whether the 63/64 is applicable here
                    (val, ost, len, tos) = _pop3StackItems(tos);

                    // todo: whatchout for gas overflows
                    gasLeft -= 32000 + 200 * len + expandMemory(ost + len);

                    (address addr, uint256 _frameGasLeft) = _performCreate(gasLeft, val, memOffset + ost, len);

                    gasLeft = _frameGasLeft;

                    tos = pushStackItem(tos, uint256(uint160(addr)));

                    continue;
                }

                if (opcode == OP_CREATE2) {
                    uint256 val;
                    uint256 ost;
                    uint256 len;
                    uint256 salt;

                    (val, ost, len, salt, tos) = _pop4StackItems(tos);

                    gasLeft -= 32000 + 200 * len + expandMemory(ost + len);

                    (address addr, uint256 _frameGasLeft) = _performCreate2(gasLeft, val, memOffset + ost, len, salt);

                    tos = pushStackItem(tos, uint256(uint160(addr)));

                    gasLeft = _frameGasLeft;

                    continue;
                }

                revert("interpreter: invalid opcode");
            } // while
        } // unchecked
    }

    function _maxCallGas(uint256 gasLimit, uint256 gasLeft) internal pure returns (uint256) {
        // shift 6 more efficient than div 64
        uint256 maxGas = ((gasLeft + 1) * 63) >> 6;
        if (gasLimit > maxGas) {
            return maxGas;
        }

        return gasLimit;
    }

    function _isEVM(address _addr) internal view returns (bool isEVM) {
        bytes4 selector = DEPLOYER_SYSTEM_CONTRACT.isEVM.selector;
        address addr = address(DEPLOYER_SYSTEM_CONTRACT);
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

    function _pushEVMFrame(uint256 _passGas) internal {
        bytes4 selector = EVM_GAS_MANAGER.pushEVMFrame.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)
            mstore(4, _passGas)

            let success := call(gas(), addr, 0, 0, 36, 0, 0)

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

    function _consumePassGas() internal returns (uint256 _passGas, bool callerEVM) {
        bytes4 selector = EVM_GAS_MANAGER.consumePassGas.selector;
        address addr = address(EVM_GAS_MANAGER);
        assembly {
            mstore(0, selector)

            let success := call(gas(), addr, 0, 0, 4, 0, 32)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }

            _passGas := mload(0)
        }

        if (_passGas != INF_PASS_GAS) {
            callerEVM = true;
        }
    }

    // Each evm gas is 200 zkEVM one
    uint256 constant GAS_DIVISOR = 20;
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

    fallback() external payable {
        bytes calldata input;
        uint256 evmGas;
        bool isCallerEVM;

        (evmGas, isCallerEVM) = _consumePassGas();

        if (!isCallerEVM) {
            evmGas = _getEVMGas();
        }

        input = msg.data;
        _getBytecode();

        warmAccount(address(uint160(address(this))));
        (uint256 retOffset, uint256 retLen, uint256 gasLeft) = _simulate(isCallerEVM, input, evmGas);

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

/*

0x
60
80604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea264697066735822122064c70c33b791f6d7904ea1cf78deb1ceea5057f756d52084f914dd5391a14dec64736f6c63430008100033

*/
