// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// 0x86bb51b8
error AddressHasNoCode(address);
// 0xa5cea466
error ArgumentsLengthNotIdentical();
// 0x07637bd8
error MintFailed();

enum ZksyncContract {
    Create2Factory,
    DiamondProxy,
    BaseToken
}
