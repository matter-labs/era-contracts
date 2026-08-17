// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2ToL1MessengerEra} from "../common/l2-helpers/IL2ToL1MessengerEra.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title MockL2BaseToken
/// @notice Mock of the zksync-os L2BaseToken for Anvil-based testing: instead of burning ETH via
/// the `Burner` selfdestruct pattern it simply accepts it, since Anvil tracks ETH balances natively.
contract MockL2BaseToken {
    IL2ToL1MessengerEra constant L1_MESSENGER = IL2ToL1MessengerEra(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR);

    event Withdrawal(address indexed l2Sender, address indexed l1Receiver, uint256 amount);

    function initL2(uint256 /* _l1ChainId */) external {
        // No-op in the mock
    }

    function burnMsgValue(uint256 /* _toChainId */) external payable {
        // No-op in the mock
    }

    function withdraw(address _l1Receiver) external payable {
        uint256 amount = msg.value;

        // Message must match the format L1Nullifier expects when finalizing the withdrawal
        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, _l1Receiver, amount);
        L1_MESSENGER.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function name() external pure returns (string memory) {
        return "Ether";
    }

    function symbol() external pure returns (string memory) {
        return "ETH";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
