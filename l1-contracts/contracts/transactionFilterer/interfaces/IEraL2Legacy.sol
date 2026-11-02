// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Entry points of EraVM L2 contracts that are no longer part of this codebase, used to recognise
/// L1->L2 calls to them.
interface IEraL2BaseToken {
    function withdraw(address _l1Receiver) external payable;

    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Legacy bridge entry points of the EraVM L2 asset router. The legacy L2 shared bridge and
/// custom bridges with the same ABI (e.g. the Lido bridge) expose the same functions.
interface IEraL2LegacyBridge {
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external;

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Asset-id based withdrawal entry point of the EraVM L2 asset router.
interface IEraL2AssetRouter {
    function withdraw(bytes32 _assetId, bytes calldata _assetData) external returns (bytes32);
}
