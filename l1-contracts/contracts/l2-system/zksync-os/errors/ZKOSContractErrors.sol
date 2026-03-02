// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0xf801b069
error L1MessengerHookFailed();
// 0xa3628b43
error L1MessengerSendFailed();
// 0x497087ab
error NotEnoughGasSupplied();
// 0xec7cdc0a
error NotSelfCall();
// 0x058f5efe
error SetBytecodeOnAddressHookFailed();
// 0x8e4a23d6
error Unauthorized(address);
