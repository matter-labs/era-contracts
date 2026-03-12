// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2ToL1MessengerEra} from "../common/l2-helpers/IL2ToL1MessengerEra.sol";
import {IMailboxLegacy} from "../state-transition/chain-interfaces/IMailboxLegacy.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title MockL2BaseToken
/// @notice A mock for L2BaseToken that supports withdraw() for Anvil-based testing.
/// Mirrors the real zksync-os L2BaseToken (da-contracts/contracts/l2-system/zksync-os/L2BaseToken.sol)
/// but avoids its `Burner` selfdestruct pattern (deprecated on newer EVM versions).
/// Instead of burning ETH, the mock simply accepts it — Anvil tracks ETH balances natively.
contract MockL2BaseToken {
    IL2ToL1MessengerEra constant L1_MESSENGER = IL2ToL1MessengerEra(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR);

    event Withdrawal(address indexed l2Sender, address indexed l1Receiver, uint256 amount);

    /// @notice Burns msg.value amount of ETH from the user (called by InteropCenter/NTV)
    function burnMsgValue(uint256 /* _toChainId */) external payable {
        // Anvil tracks ETH natively; no explicit burn needed
    }

    /// @notice Initiate a withdrawal of ETH to L1.
    /// Sends an L2→L1 message that L1Nullifier will finalize on L1.
    function withdraw(address _l1Receiver) external payable {
        uint256 amount = msg.value;

        // Build the L2→L1 message matching L1Nullifier's expected format
        bytes memory message = abi.encodePacked(IMailboxLegacy.finalizeEthWithdrawal.selector, _l1Receiver, amount);
        L1_MESSENGER.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Returns the balance of an account (always returns max for testing)
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the token name
    function name() external pure returns (string memory) {
        return "Ether";
    }

    /// @notice Returns the token symbol
    function symbol() external pure returns (string memory) {
        return "ETH";
    }

    /// @notice Returns the token decimals
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
