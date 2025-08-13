// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, TokenBalanceMigrationData} from "./IAssetTrackerBase.sol";

interface IL2AssetTracker {
    function setAddresses(
        uint256 _l1ChainId,
        address _bridgeHub,
        address,
        address _nativeTokenVault,
        address _messageRoot
    ) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function handleInitiateBridgingOnL2(bytes32 _assetId) external;

    function handleInitiateBaseTokenBridgingOnL2() external view;

    function handleFinalizeBaseTokenBridgingOnL2() external;

    function handleFinalizeBridgingOnL2(bytes32 _assetId, address _tokenAddress) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setIsL1ToL2DepositProcessed(uint256 _migrationNumber) external;
}
