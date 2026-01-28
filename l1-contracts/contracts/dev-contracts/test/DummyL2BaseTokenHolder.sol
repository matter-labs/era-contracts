// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

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

        // Transfer base tokens from this holder to the recipient using DummyL2BaseTokenSystemContract
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR.call(
            abi.encodeWithSignature("transferFromTo(address,address,uint256)", address(this), _to, _amount)
        );
        require(success, "Transfer failed");
    }

    /// @notice Fallback to accept base token transfers.
    receive() external payable {}
}
