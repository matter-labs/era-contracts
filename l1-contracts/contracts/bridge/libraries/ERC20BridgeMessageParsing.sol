// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {UnsafeBytes} from "../../common/libraries/UnsafeBytes.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1BridgeDeprecated} from "../interfaces/IL1BridgeDeprecated.sol";

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev A helper library for initializing L2 bridges in zkSync hyperchain L2 network.
library ERC20BridgeMessageParsing {    
    /// @dev Decode the withdraw message that came from L2
    function parseL2WithdrawalMessage(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) public view returns (address l1Receiver, address l1Token, uint256 amount) {
        IBridgehub bridgehub = IBridgehub(_bridgehub);
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is sent by `withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData)`
        // It should be equal to the length of the following:
        // bytes4 function signature + address l1Receiver + uint256 amount + address l2Sender + bytes _additionalData =
        // = 4 + 20 + 32 + 32 + _additionalData.length >= 68 (bytes).

        // So the data is expected to be at least 56 bytes long.
        require(_l2ToL1message.length >= 56, "EB w msg len"); // wrong messsage length

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            l1Token = bridgehub.baseToken(_chainId);
        } else if (bytes4(functionSignature) == IL1BridgeDeprecated.finalizeWithdrawal.selector) {
            // note we use the IL1BridgeDeprecated only to send L1<>L2 messages,
            // and we use this interface so that when the switch happened the old messages could be processed

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "kk");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
        } else {
            revert("W msg f slctr");
        }
    }
}