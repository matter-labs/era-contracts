// SPDX-License-Identifier: MIT

// solhint-disable reason-string, gas-custom-errors

pragma solidity ^0.8.0;

import "./libraries/Utils.sol";

import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

// Transient storage prefixes
uint256 constant IS_ACCOUNT_EVM_PREFIX = 1 << 255;
uint256 constant IS_ACCOUNT_WARM_PREFIX = 1 << 254;
uint256 constant IS_SLOT_WARM_PREFIX = 1 << 253;
uint256 constant EVM_STACK_SLOT = 2;

contract EvmGasManager {
    modifier onlySystemEvm() {
        // cache use is safe since we do not support SELFDESTRUCT
        uint256 transient_slot = IS_ACCOUNT_EVM_PREFIX | uint256(uint160(msg.sender));
        bool isEVM;
        assembly {
            isEVM := tload(transient_slot)
        }

        if (!isEVM) {
            bytes32 bytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(msg.sender);
            isEVM = Utils.isCodeHashEVM(bytecodeHash);
            if (isEVM) {
                if (!Utils.isContractConstructing(bytecodeHash)) {
                    assembly {
                        tstore(transient_slot, isEVM)
                    }
                }
            }
        }

        require(isEVM, "only system evm");
        require(SystemContractHelper.isSystemCall(), "This method requires system call flag");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;

        uint256 transient_slot = IS_ACCOUNT_WARM_PREFIX | uint256(uint160(account));

        assembly {
            wasWarm := tload(transient_slot)
        }

        if (!wasWarm) {
            assembly {
                tstore(transient_slot, 1)
            }
        }
    }

    function isSlotWarm(uint256 _slot) external view returns (bool isWarm) {
        uint256 prefix = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        uint256 transient_slot;
        assembly {
            mstore(0, prefix)
            mstore(0x20, _slot)
            transient_slot := keccak256(0, 64)
        }

        assembly {
            isWarm := tload(transient_slot)
        }
    }

    function warmSlot(
        uint256 _slot,
        uint256 _currentValue
    ) external payable onlySystemEvm returns (bool isWarm, uint256 originalValue) {
        uint256 prefix = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        uint256 transient_slot;
        assembly {
            mstore(0, prefix)
            mstore(0x20, _slot)
            transient_slot := keccak256(0, 64)
        }

        assembly {
            isWarm := tload(transient_slot)
        }

        if (isWarm) {
            assembly {
                originalValue := tload(add(transient_slot, 1))
            }
        } else {
            originalValue = _currentValue;

            assembly {
                tstore(transient_slot, 1)
                tstore(add(transient_slot, 1), originalValue)
            }
        }
    }

    /*

    The flow is the following:

    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas and determine if a call is static
        3. calleer calls popEVMFrame to remove the frame
    */

    function pushEVMFrame(uint256 passGas, bool isStatic) external onlySystemEvm {
        assembly {
            let stackDepth := add(tload(EVM_STACK_SLOT), 1)
            tstore(EVM_STACK_SLOT, stackDepth)
            let stackPointer := add(EVM_STACK_SLOT, mul(2, stackDepth))
            tstore(stackPointer, passGas)
            tstore(add(stackPointer, 1), isStatic)
        }
    }

    function consumeEvmFrame() external view returns (uint256 passGas, bool isStatic) {
        uint256 stackDepth;
        assembly {
            stackDepth := tload(EVM_STACK_SLOT)
        }
        if (stackDepth == 0) return (INF_PASS_GAS, false);

        assembly {
            let stackPointer := add(EVM_STACK_SLOT, mul(2, stackDepth))
            passGas := tload(stackPointer)
            isStatic := tload(add(stackPointer, 1))
        }
    }

    function popEVMFrame() external onlySystemEvm {
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
