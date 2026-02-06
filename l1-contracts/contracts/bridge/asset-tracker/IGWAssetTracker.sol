// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, TokenBalanceMigrationData, TokenBridgingData} from "../../common/Messaging.sol";

interface IGWAssetTracker {
    /// @notice Emitted when Gateway to L1 migration is initiated for an asset
    /// @param assetId The asset ID being migrated
    /// @param chainId The ID of the chain initiating the asset migration
    /// @param amount The amount being migrated
    event GatewayToL1MigrationInitiated(bytes32 indexed assetId, uint256 indexed chainId, uint256 amount);

    function setAddresses(uint256 _l1ChainId) external;

    function registerBaseTokenOnGateway(TokenBridgingData calldata _baseTokenBridgingData) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    function requestPauseDepositsForChain(uint256 _chainId) external;
}
