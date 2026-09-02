// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @param chainId the id of the chain
/// @param bridgehub the address of the bridgehub contract
/// @param chainTypeManager contract's address
/// @param protocolVersion initial protocol version
/// @param validatorTimelock address of the validator timelock that delays execution
/// @param admin address who can manage the contract
/// @param baseTokenAssetId asset id of the base token of the chain
/// @param storedBatchZero hash of the initial genesis batch
// solhint-disable-next-line gas-struct-packing
struct InitializeData {
    uint256 chainId;
    address bridgehub;
    address interopCenter;
    address chainTypeManager;
    uint256 protocolVersion;
    address admin;
    address validatorTimelock;
    bytes32 baseTokenAssetId;
    bytes32 storedBatchZero;
}

interface IDiamondInit {
    function initialize(InitializeData calldata _initData) external returns (bytes32);
}
