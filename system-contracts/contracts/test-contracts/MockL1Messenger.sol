// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract MockL1Messenger {
    event MockBytecodeL1Published(bytes32 indexed bytecodeHash);

    function requestBytecodeL1Publication(bytes32 _bytecodeHash) external {
        emit MockBytecodeL1Published(_bytecodeHash);
    }

    // To prevent failing during calls from the bootloader
    function sendToL1(bytes calldata) external returns (bytes32) {
        return bytes32(0);
    }
}
