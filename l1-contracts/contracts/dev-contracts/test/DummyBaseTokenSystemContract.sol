// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {L2_BASE_TOKEN_HOLDER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

/// @title DummyBaseTokenSystemContract
/// @notice A test smart contract that simulates L2BaseToken for testing interop flows (native ETH transfers)
contract DummyBaseTokenSystemContract {
    /// @notice Emitted during token transfers
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Returns ETH balance of an account (uses native balance)
    function balanceOf(uint256 _account) external view returns (uint256) {
        return address(uint160(_account)).balance;
    }

    /// @notice Transfer tokens from one address to another.
    /// @dev In the zkfoundry VM, the bootloader calls this for ETH refunds.
    /// @dev This is a no-op since zkfoundry manages native balances directly.
    function transferFromTo(address _from, address _to, uint256 _amount) external {
        emit Transfer(_from, _to, _amount);
    }

    /// @notice Circulating supply, mirroring the ZKsync OS holder-delta formula with no pre-v31
    /// history (`L2BaseTokenZKOS.totalSupply`): zero right after setup, growing with mints. Like
    /// production, no underflow guard: the holder can only receive balance that exists outside it.
    function totalSupply() external view returns (uint256) {
        return INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance;
    }

    /// @notice Fallback to accept ETH
    receive() external payable {}
}
