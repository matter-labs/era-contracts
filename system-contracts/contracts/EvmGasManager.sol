// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

import {DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

// Denotes that passGas has been consumed
uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

contract EvmGasManager {
    mapping(address => bool) private warmAccounts;

    struct SlotInfo {
        bool warm;
        uint256 originalValue;
    }

    mapping(address => mapping(uint256 => SlotInfo)) private warmSlots;

    bytes latestReturndata;

    modifier onlySystemEvm() {
        require(DEPLOYER_SYSTEM_CONTRACT.isEVM(msg.sender), "only system evm");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;

        wasWarm = warmAccounts[account];
        if (!wasWarm) warmAccounts[account] = true;
    }

    function isSlotWarm(uint256 _slot) external view returns (bool) {
        return warmSlots[msg.sender][_slot].warm;
    }

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable onlySystemEvm returns (bool, uint256) {
        SlotInfo memory info = warmSlots[msg.sender][_slot];

        if (info.warm) {
            return (true, info.originalValue);
        }

        info.warm = true;
        info.originalValue = _currentValue;

        warmSlots[msg.sender][_slot] = info;

        return (false, _currentValue);
    }

    // We dont care about the size, since none of it will be stored/pub;ushed anywya
    struct EVMStackFrameInfo {
        uint256 passGas;
        bool isStatic;
        // uint256 returnGas;
    }

    /*

    The flow is the following:

    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas & make sure that subsequent callee wont be able to read it.
        3. callee sets the return gas
        4. callee calls popEVMFrame to return the gas to the caller & remove the frame

    */

    EVMStackFrameInfo[] private evmStackFrames;

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
