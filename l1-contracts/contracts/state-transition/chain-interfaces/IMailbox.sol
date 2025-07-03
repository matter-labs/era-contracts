// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IMessageVerification} from "./IMessageVerification.sol";
import {IMailboxImpl} from "./IMailboxImpl.sol";

uint256 constant TRANSIENT_SETTLEMENT_LAYER_SLOT = uint256(keccak256("TRANSIENT_SETTLEMENT_LAYER_SLOT")) - 1;
uint256 constant TRANSIENT_FINAL_PROOF_NODE_SLOT = uint256(keccak256("TRANSIENT_FINAL_PROOF_NODE_SLOT")) - 1;

/// @title The interface of the ZKsync Mailbox contract that provides interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox is IMessageVerification, IMailboxImpl {}
