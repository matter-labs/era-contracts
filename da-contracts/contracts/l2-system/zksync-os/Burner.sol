// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper burner contract used for base token withdrawals.
 */
contract Burner {
    constructor() payable {
        selfdestruct(payable(address(this)));
    }
}
