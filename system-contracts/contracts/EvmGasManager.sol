// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

// Denotes that passGas has been consumed
uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

contract EvmGasManager {
    // We need trust to use `storage` pointers
    struct WarmAccountInfo {
        bool isWarm;
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

    function tstoreWarmAccount(address account, bool isWarm) internal {
        WarmAccountInfo storage ptr = warmAccounts[account];

        assembly {
            tstore(ptr.slot, isWarm)
        }
    }

    function tloadWarmAccount(address account) internal returns (bool isWarm) {
        WarmAccountInfo storage ptr = warmAccounts[account];

        assembly {
            isWarm := tload(ptr.slot)
        }
    }

    function tstoreWarmSlot(address _account, uint256 _key, SlotInfo memory info) internal {
        SlotInfo storage ptr = warmSlots[_account][_key];

        bool warm = info.warm;
        uint256 originalValue = info.originalValue;

        assembly {
            tstore(ptr.slot, warm)
            tstore(add(ptr.slot, 1), originalValue)
        }
    }

    function tloadWarmSlot(address _account, uint256 _key) internal view returns (SlotInfo memory info) {
        SlotInfo storage ptr = warmSlots[_account][_key];

        bool isWarm;
        uint256 originalValue;

        assembly {
            isWarm := tload(ptr.slot)
            originalValue := tload(add(ptr.slot, 1))
        }

        info.warm = isWarm;
        info.originalValue = originalValue;
    }

    modifier onlySystemEvm() {
        require(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM(msg.sender), "only system evm");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;

        wasWarm = tloadWarmAccount(account);
        if (!wasWarm) tstoreWarmAccount(account, true);
    }

    function isSlotWarm(uint256 _slot) external view returns (bool) {
        return tloadWarmSlot(msg.sender, _slot).warm;
    }

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable onlySystemEvm returns (bool, uint256) {
        SlotInfo memory info = tloadWarmSlot(msg.sender, _slot);

        if (info.warm) {
            return (true, info.originalValue);
        }

        info.warm = true;
        info.originalValue = _currentValue;

        tstoreWarmSlot(msg.sender, _slot, info);

        return (false, _currentValue);
    }

    /*
    The flow is the following:
    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas & make sure that subsequent callee won't be able to read it.
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
