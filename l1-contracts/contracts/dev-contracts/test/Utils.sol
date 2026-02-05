// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

bytes1 constant TRIGGER_IDENTIFIER = 0x02;

struct GasFields {
    uint256 gasLimit;
    uint256 gasPerPubdataByteLimit;
    address refundRecipient;
    address paymaster;
    bytes paymasterInput;
}

struct InteropTrigger {
    uint256 destinationChainId;
    address sender;
    address recipient;
    bytes32 feeBundleHash;
    bytes32 executionBundleHash;
    GasFields gasFields;
}
