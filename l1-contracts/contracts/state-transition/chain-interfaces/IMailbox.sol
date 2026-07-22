// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IMessageVerification} from "../../common/interfaces/IMessageVerification.sol";
import {IMailboxImpl} from "./IMailboxImpl.sol";
import {IMailboxLegacy} from "./IMailboxLegacy.sol"; // TODO(EVM-1216): remove after the legacy mailbox.finalizeEthWithdrawal and mailbox.requestL2Transaction are deprecated.

/// @title The interface of the ZKsync Mailbox contract that provides interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox is IMessageVerification, IMailboxImpl, IMailboxLegacy {}
