// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

// Denotes that passGas has been consumed
uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

uint256 constant IS_ACCOUNT_EVM_PREFIX = 1 << 255;
uint256 constant IS_ACCOUNT_WARM_PREFIX = 1 << 254;
uint256 constant IS_SLOT_WARM_PREFIX = 1 << 253;
uint256 constant EVM_STACK_SLOT = 2;

contract EvmGasManager {
    modifier onlySystemEvm() {
        // cache use is safe since we do not support SELFDESTRUCT
        uint256 slot = IS_ACCOUNT_EVM_PREFIX | uint256(uint160(msg.sender));
        bool isEVM;
        assembly {
            isEVM := tload(slot)
        }

        if (!isEVM) {
            isEVM = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM(msg.sender);
            if (isEVM) {
                assembly {
                    tstore(slot, isEVM)
                }
            }
        }

        require(isEVM, "only system evm");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;

        uint256 slot = IS_ACCOUNT_WARM_PREFIX | uint256(uint160(account));

        assembly {
            wasWarm := tload(slot)
        }

        if (!wasWarm) {
            assembly {
                tstore(slot, 1)
            }
        }
    }

    function isSlotWarm(uint256 _slot) external view returns (bool isWarm) {
        uint256 slot = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        assembly {
            mstore(0, slot)
            mstore(0x20, _slot)
            slot := keccak256(0, 64)
        }

        assembly {
            isWarm := tload(slot)
        }
    }

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable onlySystemEvm returns (bool isWarm, uint256 originalValue) {
        uint256 slot = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        assembly {
            mstore(0, slot)
            mstore(0x20, _slot)
            slot := keccak256(0, 64)
        }

        assembly {
            isWarm := tload(slot)
        }

        if (isWarm) {
            assembly {
                originalValue := tload(add(slot, 1))
            }
        } else {
            originalValue = _currentValue;

            assembly {
                tstore(slot, 1)
                tstore(add(slot, 1), originalValue)
            }
        }
    }

    /*

    The flow is the following:

    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas & make sure that subsequent callee wont be able to read it.
        3. callee sets the return gas
        4. callee calls popEVMFrame to return the gas to the caller & remove the frame

    */

    function pushEVMFrame(uint256 _passGas, bool _isStatic) external {
        uint256 stackDepth;
        assembly {
            stackDepth := add(tload(EVM_STACK_SLOT), 1)
            tstore(EVM_STACK_SLOT, stackDepth)
        }

        assembly {
            let stackPointer := add(EVM_STACK_SLOT, mul(2, stackDepth))
            tstore(stackPointer, _passGas)
            tstore(add(stackPointer, 1), _isStatic)
        }
    }

    function consumeEvmFrame() external returns (uint256 passGas, bool isStatic) {
        uint256 stackDepth;
        assembly {
            stackDepth := tload(EVM_STACK_SLOT)
        }
        if (stackDepth == 0) return (INF_PASS_GAS, false);
        
        assembly {
            let stackPointer := add(EVM_STACK_SLOT, mul(2, stackDepth))
            passGas := tload(stackPointer)
            isStatic := tload(add(stackPointer, 1))
            tstore(stackPointer, INF_PASS_GAS) // Mark as used
        }
    }

    // unchecked sub
    function popEVMFrame() external {
        uint256 stackDepth;
        assembly {
            stackDepth := tload(EVM_STACK_SLOT)
        }
        require(stackDepth != 0);
        assembly {
            tstore(EVM_STACK_SLOT, sub(stackDepth, 1))
        }       
    }
}
