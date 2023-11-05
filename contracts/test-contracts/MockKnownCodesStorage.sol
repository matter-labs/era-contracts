// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract MockKnownCodesStorage {
    event MockBytecodePublished(bytes32 indexed bytecodeHash);

    function markBytecodeAsPublished(bytes32 _bytecodeHash) external {
        emit MockBytecodePublished(_bytecodeHash);
    }

    // To be able to deploy original know codes storage again
    function getMarker(bytes32) public pure returns (uint256 marker) {
        return 1;
    }

    // To prevent failing during calls from the bootloader
    fallback() external {}
}
