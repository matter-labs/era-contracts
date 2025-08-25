// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, TokenBalanceMigrationData} from "../../common/Messaging.sol";

interface IL2AssetTracker {
    function setAddresses(uint256 _l1ChainId) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function handleInitiateBridgingOnL2(bytes32 _assetId, uint256 _amount, uint256 _tokenOriginChainId) external;

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external;

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external;

    function handleFinalizeBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setIsL1ToL2DepositProcessed(uint256 _migrationNumber) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;
}
