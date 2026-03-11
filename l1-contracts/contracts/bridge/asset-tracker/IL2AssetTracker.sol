// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {MigrationConfirmationData} from "../../common/Messaging.sol";

interface IL2AssetTracker {
    struct InteropL2Info {
        uint256 totalWithdrawalsToL1;
        uint256 totalSuccessfulDepositsFromL1;
    }

    /// @notice Emitted when L1 to Gateway migration is initiated for an asset
    /// @param assetId The asset ID being migrated
    /// @param chainId The chain ID from which the migration is initiated
    event L1ToGatewayMigrationInitiated(bytes32 indexed assetId, uint256 chainId);

    /// @notice Emitted when the base token is registered during a V31 upgrade.
    /// @param assetId The base token asset ID that was registered.
    event BaseTokenRegisteredDuringUpgrade(bytes32 indexed assetId);

    function L1_CHAIN_ID() external view returns (uint256);

    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId, bool _needBaseTokenTotalSupplyBackfill) external;

    function handleInitiateBridgingOnL2(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external;

    function handleInitiateBaseTokenBridgingOnL2(uint256 _maybeToBlockChainId, uint256 _amount) external;

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _fromChainId, uint256 _amount) external;

    function handleFinalizeBridgingOnL2(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external;

    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external;

    function confirmMigrationOnL2(MigrationConfirmationData calldata _migrationConfirmationData) external;

    function registerLegacyToken(bytes32 _assetId) external;

    function registerBaseTokenDuringUpgrade() external;

    function needBaseTokenTotalSupplyBackfill() external view returns (bool);

    function backFillZKSyncOSBaseTokenV31MigrationData(uint256 _amount) external;
}
