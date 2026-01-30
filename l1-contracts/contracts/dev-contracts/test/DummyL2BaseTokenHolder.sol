// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title DummyL2BaseTokenHolder
/// @notice A test smart contract that simulates BaseTokenHolder for testing interop flows
contract DummyL2BaseTokenHolder {
    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external {
        if (_amount == 0) {
            return;
        }

        // Transfer base tokens using native transfer
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Fallback to accept base token transfers.
    receive() external payable {}
}
