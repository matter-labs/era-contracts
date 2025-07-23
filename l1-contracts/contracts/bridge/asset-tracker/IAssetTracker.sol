// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {FinalizeL1DepositParams} from "../../common/Messaging.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

struct TokenBalanceMigrationData {
    uint256 chainId;
    bytes32 assetId;
    uint256 tokenOriginChainId;
    uint256 amount;
    uint256 migrationNumber;
    bool isL1ToGateway;
}

interface IAssetTracker {
    struct BalanceChange {
        bytes32 baseTokenAssetId;
        uint256 baseTokenAmount;
        bytes32 assetId;
        uint256 amount;
    }

    function BRIDGE_HUB() external view returns (IBridgehub);

    function tokenMigratedThisChain(bytes32 _assetId) external view returns (bool);

    function tokenMigrated(uint256 _chainId, bytes32 _assetId) external view returns (bool);

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) external;

    function registerLegacyTokenOnChain(bytes32 _assetId) external;

    function handleChainBalanceIncreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external;

    function handleChainBalanceDecreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        bytes32 _baseTokenAssetId,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external;

    function handleInitiateBridgingOnL2(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function handleFinalizeBridgingOnL2(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount);

    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;
}
