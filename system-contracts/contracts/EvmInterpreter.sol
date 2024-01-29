// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./EvmConstants.sol";
import "./EvmContract.sol";
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

// library EvmUtils {
//     function expand(bytes memory bmem, uint256 newSize) internal pure returns (uint256 gasCost) {
//         unchecked {
//             uint256 oldSize = bmem.length;

//             if (newSize > oldSize) {
//                 // old size should be aligned, but align just in case to be on the safe side
//                 uint256 oldSizeWords = _words(oldSize);
//                 uint256 newSizeWords = _words(newSize);

//                 uint256 words = newSizeWords - oldSizeWords;
//                 gasCost = (words ** 2) / 512 + (3 * words);
//                 assembly ("memory-safe") {
//                     let size := shl(5, newSizeWords)
//                     mstore(bmem, size)
//                     mstore(0x40, add(add(bmem, 0x20), size))
//                 }
//             }
//         }
//     }
// }

contract EvmInterpreter {
    using EvmUtils for bytes;

    // event OverheadTrace(uint256 gasUsage);
    // event OpcodeTrace(uint256 opcode, uint256 gasUsage);

    function _simulate(bytes calldata input, uint256 gasLeft, uint256 _bytecodeLen) internal {
        unchecked {
            uint256 _ergTracking = gasleft();
            // NOTE: I tried putting these state variables in a struct but the
            // yul code turned out less efficient due to calculating field offsets
            // from the base, rather than accessing the struct directly...

            // temp storage for many various operations
            uint256 tmp = 0;

            uint256 returnDataSize = 0;

            // program counter (pc is taken in assembly, so ip = instruction pointer)
            uint256 ip = 0;

            // top of stack - index to first stack element; empty stack = -1
            // (this is simpler than tos = stack.length, cleaner code)
            // note it is technically possible to underflow due to the unchecked
            // but that will immediately revert due to out of bounds memory access -> out of gas
            uint256 tos = uint256(int256(-1));

            // classic EVM has 1024 stack items
            uint256[1024] memory stack;

            bytes memory bmem = new bytes(0);

            // emit OverheadTrace(_ergTracking - gasleft());
            while (true) {
                _ergTracking = gasleft();
                // optimization: opcode is uint256 instead of uint8 otherwise every op will trim bits every time
                uint256 opcode;

                // check for stack overflow/underflow
                if ((tos + 1) >= 1024) {
                    revert("interpreter: stack overflow");
                }

                if (int256(gasLeft) < 0) {
                    revert("interpreter: out of gas");
                }

                if (ip < code.length) {
                    opcode = uint256(uint8(code[ip]));
                } else {
                    opcode = OP_STOP;
                }

                ip++;

                // ALU 1 - arithmetic-logic opcodes group (1 out of 2)
                if (opcode < GRP_ALU1) {
                    // optimization: STOP is part of group ALU 1
                    if (opcode == OP_STOP) {
                        assembly ("memory-safe") {
                            stop()
                        }
                    }

                    uint256 a = stack[tos--];
                    uint256 b = stack[tos];

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
                        uint256 n = stack[--tos];
                        assembly ("memory-safe") {
                            tmp := addmod(a, b, n)
                        }
                        gasLeft -= 8;
                    } else if (opcode == OP_MULMOD) {
                        uint256 n = stack[--tos];
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

                    stack[tos] = tmp;
                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // ALU 2 - arithmetic-logic opcodes group (2 out of 2)
                if (opcode < GRP_ALU2) {
                    if (opcode == OP_NOT) {
                        tmp = ~stack[tos];
                    } else if (opcode == OP_ISZERO) {
                        tmp = (stack[tos] == 0 ? 1 : 0);
                    } else {
                        uint256 a = stack[tos--];
                        uint256 b = stack[tos];

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

                    stack[tos] = tmp;
                    gasLeft -= 3;
                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // evm state & more misc opcodes
                if (opcode < GRP_VM_STATE) {
                    // TODO: optimize this group by sorting opcodes by popularity & gas cost (cheaper first)

                    if (opcode == OP_KECCAK256) {
                        // aka SHA3
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos];

                        // TODO: this is arbitrary, find a better way to limit
                        // NOTE: this causes one of the tests to fail because the length is 0x0f_ffff which is way out of bounds
                        // apparently this does succeed in evm so need to figure out the limits
                        // might be good to fix but not strictly necessary
                        require(ost <= 65000 && len <= 65000, "interpreter: KECCAK256: invalid memory access");

                        gasLeft -=
                            30 + // base cost
                            6 *
                            _words(len) + // cost per word
                            bmem.expand(ost + len); // memory expansion

                        uint256 val;
                        assembly ("memory-safe") {
                            val := keccak256(add(add(bmem, 0x20), ost), len)
                        }
                        stack[tos] = val;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_ADDRESS) {
                        stack[++tos] = uint256(uint160(address(this)));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BALANCE) {
                        stack[tos] = address(uint160(stack[tos])).balance;
                        // TODO: dynamic gas cost (simply 2600 if cold...)
                        gasLeft -= 100;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_ORIGIN) {
                        stack[++tos] = uint256(uint160(tx.origin));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLER) {
                        stack[++tos] = uint256(uint160(msg.sender));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLVALUE) {
                        stack[++tos] = msg.value;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATALOAD) {
                        uint256 idx = stack[tos];
                        // uint256 val = uint256(bytes32(input[idx:idx+0x20]));
                        uint256 val;
                        assembly ("memory-safe") {
                            let ost := add(input.offset, idx)
                            // it is possible to overflow with high idx so prevent
                            // reading interpreter's calldata, read zero instead
                            if lt(ost, input.offset) {
                                val := 0
                            }
                            {
                                val := calldataload(ost)
                            }
                        }

                        stack[tos] = val;
                        gasLeft -= 3;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATASIZE) {
                        stack[++tos] = input.length;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CALLDATACOPY) {
                        uint256 dstOst = stack[tos--];
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // NOTE: when ost is out of range, e.g. 2^256-1, then it should read zeros
                        // but here we revert instead... because otherwise input.offset + ost could overflow
                        // TODO: this is arbitrary, find a better way to limit
                        require(
                            ost <= 65000 && len <= 65000 && dstOst <= 65000,
                            "interpreter: CALLDATACOPY: invalid memory access"
                        );

                        gasLeft -=
                            3 + // base cost
                            3 *
                            _words(len) + // word copy cost
                            bmem.expand(dstOst + len); // memory expansion

                        assembly ("memory-safe") {
                            calldatacopy(add(add(bmem, 0x20), dstOst), add(input.offset, ost), len)
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CODESIZE) {
                        stack[++tos] = code.length;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CODECOPY) {
                        // NOTE: since code is in memory this is essentially memcopy
                        // pretty expensive, need to think how to optimize
                        uint256 dstOst = stack[tos--];
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // TODO: this is arbitrary, find a better way to limit
                        require(
                            /*ost+len <= 65000 && */ dstOst + len <= 65000,
                            "interpreter: CODECOPY: invalid memory access"
                        );

                        gasLeft -=
                            3 + // base cost
                            3 *
                            _words(len) + // word copy cost
                            bmem.expand(dstOst + len); // memory expansion

                        // TODO: optimize this
                        for (uint256 i = 0; i < len; i++) {
                            bmem[dstOst + i] = (ost + i < code.length ? code[ost + i] : bytes1(0));
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GASPRICE) {
                        stack[++tos] = tx.gasprice;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODESIZE) {
                        // TODO: need to return 0 if addr is currently in constructor
                        address addr = address(uint160(stack[tos]));
                        stack[tos] = DEPLOYER_SYSTEM_CONTRACT.getCodeSize(addr);

                        // extra cost if account is cold
                        if (EVM_GAS_MANAGER.warmAccount(addr)) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODECOPY) {
                        address addr = address(uint160(stack[tos--]));
                        uint256 dstOst = stack[tos--];
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];
                        DEPLOYER_SYSTEM_CONTRACT.getCode(addr);
                        assembly ("memory-safe") {
                            returndatacopy(add(add(bmem, 0x20), dstOst), add(ost, 0x20), len)
                        }

                        // extra cost if account is cold
                        if (EVM_GAS_MANAGER.warmAccount(addr)) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        gasLeft -=
                            3 *
                            _words(len) + // word copy cost
                            bmem.expand(dstOst + len); // memory expansion
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATASIZE) {
                        stack[++tos] = returnDataSize;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_RETURNDATACOPY) {
                        uint256 dstOst = stack[tos--];
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        EVM_GAS_MANAGER.returnDataCopy();

                        // TODO: bound check on memOst
                        assembly ("memory-safe") {
                            let memOst := add(add(bmem, 0x20), dstOst)
                            returndatacopy(memOst, ost, len)
                        }

                        gasLeft -= 3 + bmem.expand(dstOst + len);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_EXTCODEHASH) {
                        address addr = address(uint160(stack[tos]));
                        stack[tos] = uint256(DEPLOYER_SYSTEM_CONTRACT.getCodeHash(addr));

                        // extra cost if account is cold
                        if (EVM_GAS_MANAGER.warmAccount(addr)) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2600;
                        }

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_TIMESTAMP) {
                        stack[++tos] = block.timestamp;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_NUMBER) {
                        stack[++tos] = block.number;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_CHAINID) {
                        stack[++tos] = block.chainid;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SELFBALANCE) {
                        stack[++tos] = address(this).balance;
                        gasLeft -= 5;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BLOCKHASH) {
                        stack[++tos] = uint256(blockhash(stack[tos]));
                        gasLeft -= 20;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_COINBASE) {
                        stack[++tos] = uint256(uint160(address(block.coinbase)));
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_PREVRANDAO) {
                        // formerly known as DIFFICULTY
                        stack[++tos] = block.difficulty;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GASLIMIT) {
                        stack[++tos] = block.gaslimit;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_BASEFEE) {
                        stack[++tos] = block.basefee;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }

                // misc group: memory, control flow and more
                if (opcode < GRP_MISC) {
                    if (opcode == OP_POP) {
                        gasLeft -= 2;
                        tos--;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MLOAD) {
                        uint256 ost = stack[tos];
                        uint256 val;
                        assembly ("memory-safe") {
                            val := mload(add(add(bmem, 0x20), ost))
                        }
                        stack[tos] = val;
                        gasLeft -= 3 + bmem.expand(ost + 32);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE) {
                        uint256 ost = stack[tos--];
                        uint256 val = stack[tos--];
                        assembly ("memory-safe") {
                            mstore(add(add(bmem, 0x20), ost), val)
                        }

                        gasLeft -= 3 + bmem.expand(ost + 32);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSTORE8) {
                        uint256 ost = stack[tos--];
                        uint256 val = stack[tos--];
                        assembly ("memory-safe") {
                            mstore8(add(add(bmem, 0x20), ost), val)
                        }

                        gasLeft -= 3 + bmem.expand(ost + 1);

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SLOAD) {
                        uint256 key = stack[tos];
                        assembly ("memory-safe") {
                            tmp := sload(key)
                        }
                        stack[tos] = tmp;

                        // extra cost if account is cold
                        if (EVM_GAS_MANAGER.warmSlot(key)) {
                            gasLeft -= 100;
                        } else {
                            gasLeft -= 2100;
                        }

                        // need not to worry about gas refunds as it happens outside the evm
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_SSTORE) {
                        uint256 key = stack[tos--];
                        uint256 val = stack[tos--];

                        assembly ("memory-safe") {
                            tmp := sload(key)
                            sstore(key, val)
                        }

                        // TODO: those are not the *exact* same rules
                        // extra cost if account is cold
                        if (EVM_GAS_MANAGER.warmSlot(key)) {
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
                        ip = stack[tos--];
                        require(ip < code.length && code[ip] == 0x5B, "interpreter: expecting JUMPDEST");
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                    // NOTE: We don't currently do full jumpdest validation (i.e. validating a jumpdest isn't in PUSH data)
                    if (opcode == OP_JUMPI) {
                        gasLeft -= 10;
                        if (stack[tos - 1] > 0) {
                            ip = stack[tos];
                            // jumpdest only checked if branch taken
                            require(ip < code.length && code[ip] == 0x5B, "interpreter: expecting JUMPDEST");
                        }
                        tos -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_PC) {
                        // compensate for pc++ earlier
                        stack[++tos] = ip - 1;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_MSIZE) {
                        stack[++tos] = bmem.length;
                        gasLeft -= 2;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_GAS) {
                        // GAS opcode gives the remaining gas *after* consuming the opcode
                        gasLeft -= 2;
                        stack[++tos] = gasLeft;
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
                        stack[++tos] = 0;
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
                            num = (num << 8) | uint8(code[ip + i]);
                        }
                        stack[++tos] = num;
                        ip += len;
                        gasLeft -= 3;
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_DUP) {
                        // DUPx
                        tos++;
                        uint256 ost = opcode - 0x7F;
                        gasLeft -= 3;
                        require(ost <= tos, "interpreter: stack underflow");
                        stack[tos] = stack[tos - ost];
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode < GRP_SWAP) {
                        // SWAPx
                        uint256 ost = opcode - 0x8F;
                        gasLeft -= 3;
                        require(ost <= tos, "interpreter: stack underflow");
                        (stack[tos], stack[tos - ost]) = (stack[tos - ost], stack[tos]);
                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG0) {
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];
                        // TODO: this is arbitrary, find a better way to limit
                        require(ost <= 65000 && len <= 65000, "interpreter: LOG0: invalid memory access");
                        assembly ("memory-safe") {
                            log0(add(add(bmem, 0x20), ost), len)
                        }

                        gasLeft -=
                            375 + // base cost
                            8 *
                            len + // word copy cost
                            bmem.expand(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG1) {
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // TODO: this is arbitrary, find a better way to limit
                        require(ost <= 65000 && len <= 65000, "interpreter: LOG1: invalid memory access");
                        uint256 topic0 = stack[tos--];
                        assembly ("memory-safe") {
                            log1(add(add(bmem, 0x20), ost), len, topic0)
                        }

                        gasLeft -=
                            750 + // base cost
                            8 *
                            len + // word copy cost
                            bmem.expand(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG2) {
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // TODO: this is arbitrary, find a better way to limit
                        require(ost <= 65000 && len <= 65000, "interpreter: LOG2: invalid memory access");
                        uint256 topic0 = stack[tos--];
                        uint256 topic1 = stack[tos--];
                        assembly ("memory-safe") {
                            log2(add(add(bmem, 0x20), ost), len, topic0, topic1)
                        }

                        gasLeft -=
                            1125 + // base cost
                            8 *
                            len + // word copy cost
                            bmem.expand(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG3) {
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // TODO: this is arbitrary, find a better way to limit
                        require(ost <= 65000 && len <= 65000, "interpreter: LOG3: invalid memory access");
                        uint256 topic0 = stack[tos--];
                        uint256 topic1 = stack[tos--];
                        uint256 topic2 = stack[tos--];
                        assembly ("memory-safe") {
                            log3(add(add(bmem, 0x20), ost), len, topic0, topic1, topic2)
                        }

                        gasLeft -=
                            1500 + // base cost
                            8 *
                            len + // word copy cost
                            bmem.expand(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }

                    if (opcode == OP_LOG4) {
                        uint256 ost = stack[tos--];
                        uint256 len = stack[tos--];

                        // TODO: this is arbitrary, find a better way to limit
                        require(ost <= 65000 && len <= 65000, "interpreter: LOG4: invalid memory access");
                        uint256 topic0 = stack[tos--];
                        uint256 topic1 = stack[tos--];
                        uint256 topic2 = stack[tos--];
                        uint256 topic3 = stack[tos--];
                        assembly ("memory-safe") {
                            log4(add(add(bmem, 0x20), ost), len, topic0, topic1, topic2, topic3)
                        }

                        gasLeft -=
                            1875 + // base cost
                            8 *
                            len + // word copy cost
                            bmem.expand(ost + len); // memory expansion

                        // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                        continue;
                    }
                }
                // TODO: Fix static call once new vm version is available
                // call contract opcodes
                if (opcode == OP_CALL || opcode == OP_DELEGATECALL || opcode == OP_STATICCALL) {
                    uint256 gasLimit = stack[tos--];
                    address addr = address(uint160(stack[tos--]));
                    uint256 val;
                    if (opcode == OP_CALL) {
                        val = stack[tos--];

                        if (val != 0) {
                            /*
                            If value is not 0, then positive_value_cost is 9000.
                            In this case there is also a call stipend that is given to
                            make sure that a basic fallback function can be called.
                            2300 is thus removed from the cost, and also added to the gas input.
                            */
                            // that is, 9000 minus 2300 stipend going towards gas limit
                            // and another 25000 added to the 9000 - 2300 if
                            if (0 == DEPLOYER_SYSTEM_CONTRACT.getCodeSize(address(uint160(addr)))) {
                                // if value AND account empty:
                                gasLeft -= 31700; // 25000 + (9000 - 2300);
                            } else {
                                // if value AND account not empty:
                                gasLeft -= 6700; // 9000 - 2300;
                            }

                            // call stipend: https://github.com/ethereum/go-ethereum/blob/576681f29b895dd39e559b7ba17fcd89b42e4833/core/vm/instructions.go#L659
                            gasLimit += 2300;
                        }
                    }

                    uint256 argOst = stack[tos--];
                    uint256 argLen = stack[tos--];
                    uint256 retOst = stack[tos--];
                    uint256 retLen = stack[tos];
                    uint256 success;

                    // memory expansion
                    gasLeft -= bmem.expand(max(argOst + argLen, retOst + retLen));

                    // extra cost if account is cold:
                    // If address is warm, then address_access_cost is 100, otherwise it is 2600.
                    if (EVM_GAS_MANAGER.warmAccount(address(uint160(addr)))) {
                        gasLeft -= 100;
                    } else {
                        gasLeft -= 2600;
                    }

                    // NOTE: To ensure evm contracts cannot call gas manager
                    require(addr != address(EVM_GAS_MANAGER), "interpreter: cannot call gas manager");
                    gasLimit = _maxCallGas(gasLimit, gasLeft);
                    EVM_GAS_MANAGER.pushGasLeft(gasLimit);

                    if (opcode == OP_CALL) {
                        assembly ("memory-safe") {
                            tmp := gas()
                            success := call(
                                tmp,
                                addr,
                                val,
                                add(add(bmem, 0x20), argOst),
                                argLen,
                                add(add(bmem, 0x20), retOst),
                                retLen
                            )
                        }
                    } else if (opcode == OP_DELEGATECALL) {
                        assembly ("memory-safe") {
                            tmp := gas()
                            success := delegatecall(
                                tmp,
                                addr,
                                add(add(bmem, 0x20), argOst),
                                argLen,
                                add(add(bmem, 0x20), retOst),
                                retLen
                            )
                        }
                    } else {
                        // if (opcode == OP_STATICCALL)
                        // TODO: Fix static call once zkevm 1.5.0 is integrated
                        assembly ("memory-safe") {
                            tmp := gas()
                            success := call(
                                tmp,
                                addr,
                                0,
                                add(add(bmem, 0x20), argOst),
                                argLen,
                                add(add(bmem, 0x20), retOst),
                                retLen
                            )
                        }
                    }

                    bytes memory returnData;
                    assembly ("memory-safe") {
                        returnDataSize := returndatasize()
                        returnData := add(add(bmem, 0x20), mload(bmem))
                        mstore(returnData, returnDataSize)
                        returndatacopy(add(returnData, 0x20), 0x00, returnDataSize)
                    }

                    // TODO: check if this does another copy because of selector and if so, optimize by calling in assembly directly
                    // (and that also allows optimizing the case where returnDataSize <= retLen)
                    EVM_GAS_MANAGER.setReturnBuffer(returnData);

                    stack[tos] = success;

                    // consider reusing gasLimit as gasUsed...
                    uint256 frameGasUsed = gasLimit - EVM_GAS_MANAGER.popGasLeft();
                    if (frameGasUsed == 0) {
                        // if call used 0 gas means it's non-evm so guesstimate a multiple of ergs used
                        // (`tmp` is re-used here to avoid stack too deep)
                        frameGasUsed = (tmp - gasleft()) / GAS_DIVISOR;
                    }

                    // TODO: some tests are off, eg. return.json:439 have an off-by-one
                    // (might be unrelated to the calculation in this CALL* opcodes)
                    gasLeft -= frameGasUsed;
                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
                    continue;
                }

                // return & revert opcodes
                if (opcode == OP_RETURN || opcode == OP_REVERT) {
                    uint256 ost = stack[tos--];
                    uint256 len = stack[tos];

                    gasLeft -= bmem.expand(ost + len);
                    EVM_GAS_MANAGER.reportGasLeft(gasLeft);

                    assembly ("memory-safe") {
                        if eq(opcode, OP_RETURN) {
                            return(add(add(bmem, 0x20), ost), len)
                        }

                        revert(add(add(bmem, 0x20), ost), len)
                    }
                }

                // create contract opcodes
                if (opcode == OP_CREATE || opcode == OP_CREATE2) {
                    uint256 val = stack[tos--];
                    uint256 ost = stack[tos--];
                    uint256 len = stack[tos];

                    EVM_GAS_MANAGER.pushGasLeft(gasLeft);

                    bytes memory create_code;
                    assembly ("memory-safe") {
                        create_code := add(bmem, ost)
                        // temporary override len
                        tmp := mload(create_code)
                        mstore(create_code, len)
                    }

                    if (opcode == OP_CREATE2) {
                        uint256 salt = stack[--tos];
                        stack[tos] = uint256(
                            uint160(DEPLOYER_SYSTEM_CONTRACT.create2EVM{value: val}(bytes32(salt), create_code))
                        );
                    } else {
                        stack[tos] = uint256(uint160(DEPLOYER_SYSTEM_CONTRACT.createEVM{value: val}(create_code)));
                    }

                    assembly ("memory-safe") {
                        // restore len
                        mstore(create_code, tmp)
                    }

                    // gasLeft is *before* the create, popGasLeft() is *after* the create
                    uint256 frameGasUsed = gasLeft - EVM_GAS_MANAGER.popGasLeft();
                    if (frameGasUsed == 0) {
                        // if call used 0 gas means it's non-evm so guesstimate a multiple of ergs used
                        // (`tmp` is re-used here to avoid stack too deep)
                        frameGasUsed = (tmp - gasleft()) / GAS_DIVISOR;
                    }

                    gasLeft -= 32000 + 200 * len + frameGasUsed;
                    // emit OpcodeTrace(opcode, _ergTracking - gasleft());
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

    // todo: move to a separate lib
    function _isEVM(address _addr) {

    }

    // Each evm gas is 200 zkEVM one
    uint256 constant GAS_DIVISOR = 200;
    uint256 constant EVM_GAS_STIPEND = (1 << 30);
    uint256 constant OVERHEAD = 2000;
    function _getEVMGas() internal view returns (uint256) {
        uint256 _gas = gasleft();
        uint256 requiredGas = EVM_GAS_STIPEND + OVERHEAD;

        if (_gas < requiredGas) {
            return 0;
        } else {
            return (_gas - requiredGas) / GAS_DIVISOR;
        }
    }

    function _requestBytecode() internal view returns (bytes memory bytecode) {
        SystemContractHelper.
    }

    fallback() external payable {
        bytes calldata input;
        bytes memory bytecode;
        uint256 evmGas;

        if(msg.sender == address(DEPLOYER_SYSTEM_CONTRACT)) {
            evmGas = uint256(bytes32(msg.data[0:32]));
            bytecode = msg.data[32:];
        } else if (_isEVM(msg.sender)) {
            evmGas = uint256(bytes32(msg.data[0:32]));
            input = msg.data[32:];
            bytecode = _requestBytecode(this);
        } else {
            evmGas = _getEVMGas();
            input = msg.data;
        }

        (bool isConstructor, bytes memory bytecode) = DEPLOYER_SYSTEM_CONTRACT.prepareEvmExecution(codeAddress);
        if (bytecode.length == 0) {
            // It is EOA or empty contract
            assembly ("memory-safe") {
                stop()
            }
        }

        if (isConstructor) {
            input = msg.data[0:0];
        } else {
            input = msg.data[0x20:];
        }

        // TODO: consider creating a cheaper primitive with only writing to storage, without reading current state
        EVM_GAS_MANAGER.warmAccount(address(uint160(address(this))));
        EVM_GAS_MANAGER.setReturnBuffer(hex"");
        _simulate(bytecode, input, evmGas);

        revert("interpreter: unreachable");
    }
}


/*

We need the following memory:
- Bytecode (1k words)
- Scratch space (10 words)
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
