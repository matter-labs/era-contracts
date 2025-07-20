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
    function BRIDGE_HUB() external view returns (IBridgehub);

    function assetMigrationNumber(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) external;

    function registerLegacyTokenOnChain(bytes32 _assetId) external;

    function handleChainBalanceIncreaseOnSL(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external;

    function handleChainBalanceDecreaseOnSL(
        // uint256 _tokenOriginChainId,
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external;

    function handleInitiateBridgingOnL2(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount);

    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;
}
