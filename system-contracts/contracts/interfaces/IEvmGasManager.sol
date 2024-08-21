// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEvmGasManager {
    // We need trust to use `storage` pointers
    struct WarmAccountInfo {
        bool isWarm;
    }

    struct SlotInfo {
        bool warm;
        uint256 originalValue;
    }

    // We dont care about the size, since none of it will be stored/pub;ushed anyway.
    struct EVMStackFrameInfo {
        bool isStatic;
        uint256 passGas;
    }

    function warmAccount(address account) external payable returns (bool wasWarm);

    function isSlotWarm(uint256 _slot) external view returns (bool);

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable returns (bool, uint256);

    /*
    The flow is the following:
    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas & make sure that subsequent callee won't be able to read it.
        3. callee sets the return gas
        4. callee calls popEVMFrame to return the gas to the caller & remove the frame
    */

    function pushEVMFrame(uint256 _passGas, bool _isStatic) external;

    function consumeEvmFrame() external returns (uint256 passGas, bool isStatic);

    function popEVMFrame() external;
}
