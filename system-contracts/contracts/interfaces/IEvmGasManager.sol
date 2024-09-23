// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEvmGasManager {
    function warmAccount(address account) external payable returns (bool wasWarm);

    function isSlotWarm(uint256 _slot) external view returns (bool);

    function warmSlot(uint256 _slot, uint256 _currentValue) external payable returns (bool, uint256);

    function pushEVMFrame(uint256 _passGas, bool _isStatic) external;

    function consumeEvmFrame() external returns (uint256 passGas, bool isStatic);

    function popEVMFrame() external;
}
