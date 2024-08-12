// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The "empty" contract that is put into some system contracts by default.
 */
contract EmptyContract {
    fallback() external payable {}

    receive() external payable {}
}
