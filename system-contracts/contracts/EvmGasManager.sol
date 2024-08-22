// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

// Denotes that passGas has been consumed
uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

contract EvmGasManager {
    // We need strust to use `storage` pointers
    struct WarmAccountInfo {
        bool isWarm;
    }

    struct AccountInfo {
        bool isEVM;
    }
    
    struct SlotInfo {
        bool warm;
        uint256 originalValue;
    }

    // We dont care about the size, since none of it will be stored/pub;ushed anywya
    struct EVMStackFrameInfo {
        bool isStatic;
        uint256 passGas;
    }

    // The following storage variables are not used anywhere explicitly and are just used to obtain the storage pointers
    // to use the transient storage with.
    mapping(address => WarmAccountInfo) private warmAccounts;
    mapping(address => mapping(uint256 => SlotInfo)) private warmSlots;
    EVMStackFrameInfo[] private evmStackFrames;
    mapping(address => AccountInfo) private isAccountEVM;

    modifier onlySystemEvm() {
        // cache use is safe since we do not support SELFDESTRUCT
        AccountInfo storage ptr = isAccountEVM[msg.sender];
        bool isEVM;
        assembly {
            isEVM := tload(ptr.slot)
        }

        if (!isEVM) {
            isEVM = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM(msg.sender);
            if (isEVM) {
                assembly {
                    tstore(ptr.slot, isEVM)
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

        WarmAccountInfo storage ptr = warmAccounts[account];

        assembly {
            wasWarm := tload(ptr.slot)
        }

        if (!wasWarm) {
            assembly {
                tstore(ptr.slot, 1)
            }
        }
    }

    function isSlotWarm(uint256 _slot) external view returns (bool isWarm) {
        SlotInfo storage ptr = warmSlots[msg.sender][_slot];

        assembly {
            isWarm := tload(ptr.slot)
        }
    }

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable onlySystemEvm returns (bool isWarm, uint256 originalValue) {
        SlotInfo storage ptr = warmSlots[msg.sender][_slot];

        assembly {
            isWarm := tload(ptr.slot)
        }

        if (isWarm) {
            assembly {
                originalValue := tload(add(ptr.slot, 1))
            }
        } else {
            originalValue = _currentValue;

            assembly {
                tstore(ptr.slot, 1)
                tstore(add(ptr.slot, 1), originalValue)
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
        EVMStackFrameInfo memory frame = EVMStackFrameInfo({passGas: _passGas, isStatic: _isStatic});

        evmStackFrames.push(frame);
    }

    function consumeEvmFrame() external returns (uint256 passGas, bool isStatic) {
        if (evmStackFrames.length == 0) return (INF_PASS_GAS, false);

        EVMStackFrameInfo memory frameInfo = evmStackFrames[evmStackFrames.length - 1];

        passGas = frameInfo.passGas;
        isStatic = frameInfo.isStatic;

        // Mark as used
        evmStackFrames[evmStackFrames.length - 1].passGas = INF_PASS_GAS;
    }

    function popEVMFrame() external {
        evmStackFrames.pop();
    }
}
