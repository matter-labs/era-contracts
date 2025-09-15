// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {TokenBalanceMigrationData} from "../../common/Messaging.sol";

interface IL2AssetTracker {
    function setAddresses(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external;

    function handleInitiateBridgingOnL2(bytes32 _assetId, uint256 _amount, uint256 _tokenOriginChainId) external;

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external;

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external;

    function handleFinalizeBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external;

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;
}
