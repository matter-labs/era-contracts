// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {FinalizeL1DepositParams} from "../../common/Messaging.sol";

interface IAssetTracker {
    function handleChainBalanceIncrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function handleChainBalanceDecrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount);

    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function migrateTokenBalanceFromL2(bytes32 _assetId) external;

    function receiveMigrationOnGateway(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function confirmMigrationOnL2(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber
    ) external;
}
