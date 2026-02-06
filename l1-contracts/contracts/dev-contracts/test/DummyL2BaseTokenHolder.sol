// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {BaseTokenTransferFailed} from "../../common/L1ContractErrors.sol";

/// @title DummyL2BaseTokenHolder
/// @notice A test smart contract that simulates BaseTokenHolder for testing interop flows using ZKOS logic (native ETH transfers)
contract DummyL2BaseTokenHolder {
    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's native balance.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external {
        if (_amount == 0) {
            return;
        }

        // Transfer native ETH from this holder to the recipient (ZKOS style)
        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) {
            revert BaseTokenTransferFailed();
        }
    }

    /// @notice Burns ETH by accepting it into this contract and notifies the asset tracker.
    /// @dev In production, this would also notify L2AssetTracker. For testing, we just accept the ETH.
    function burnAndStartBridging() external payable {
        // Just accept the ETH - in tests this simulates the burn
        // The ETH stays in this contract, effectively "burning" it from circulation
    }

    /// @notice Fallback to accept base token transfers.
    receive() external payable {}
}
