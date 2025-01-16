// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {L2CanonicalTransaction, L2Log, L2Message, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {IMessageVerification} from "./IMessageVerification.sol";
import {IMailboxImpl} from "./IMailboxImpl.sol";

/// @title The interface of the ZKsync Mailbox contract that provides interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox is IMessageVerification, IMailboxImpl {
}
