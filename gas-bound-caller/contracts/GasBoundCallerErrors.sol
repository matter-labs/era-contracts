// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x0921241a
error MaxGasLessThanGasLeft();
// 0xb2017838
error PubdataAllowanceAndGasLeftLessThanPubdataGasAndOverhead();