// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

error FailedToDeploy(ZksyncContract);
error BytecodeNotSet();
error FailedToDeployViaCreate2();
error MissingAddress(ZksyncContract);
error AddressHasNoCode(address);
error MintFailed();

enum ZksyncContract {
    Create2Factory,
    DiamondProxy,
    BaseToken
}
