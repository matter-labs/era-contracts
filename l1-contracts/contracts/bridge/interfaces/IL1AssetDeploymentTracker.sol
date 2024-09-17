// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetDeploymentTracker {
    function bridgeCheckCounterpartAddress(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        address _assetHandlerAddressOnCounterpart
    ) external view;
}
