// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {L2AssetBookkeepingInfo} from "../../common/L2AssetBookkeeping.sol";

/// @title L2 Asset Tracker interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Chain-local asset bookkeeping hooks called by the NTV, BaseTokenHolder and L2BaseToken.
/// See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
interface IL2AssetTracker {
    /// @notice The chain ID of L1, set during genesis or the v31 upgrade.
    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice The asset ID of the chain's base token, set during genesis or the v31 upgrade.
    // solhint-disable-next-line func-name-mixedcase
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Whether the asset's bookkeeping has been initialized, i.e. its baseline is recorded.
    function isAssetTracked(bytes32 _assetId) external view returns (bool);

    /// @notice The asset's recorded L1 <-> L2 flows and its pre-tracking baseline;
    /// see {L2AssetBookkeepingInfo}.
    function getAssetBookkeeping(bytes32 _assetId) external view returns (L2AssetBookkeepingInfo memory);

    /// @notice Initializes the tracker at genesis.
    /// @param _l1ChainId The chain ID of the L1 network.
    /// @param _baseTokenAssetId The asset ID of the chain's base token.
    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external;

    /// @notice Records the base token's pre-tracking baseline, once.
    /// @dev Called during the upgrade/genesis (only the upgrader may call it), before any flow the
    /// BaseTokenHolder can report, so the baseline and the recorded flows never overlap.
    function trackBaseToken() external;

    /// @notice Initializes the bookkeeping of a token registered on the vault after this release,
    /// which by construction has no pre-tracking flows. No-op if already initialized.
    /// @param _assetId The asset ID of the token.
    /// @param _originChainId The chain ID the token is native to.
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external;

    /// @notice Initializes the bookkeeping of a token registered on the vault before this release,
    /// capturing its pre-tracking baseline. No-op if already initialized.
    /// @dev Must be called before the triggering operation changes the token's supply or the
    /// vault's escrow, both of which the baseline is derived from. The vault drives this (rather
    /// than the tracker exposing it directly) so that the baseline and the vault's `bridgedOut`
    /// seeding — derived from the same escrow — are always captured at the same moment.
    /// @param _assetId The asset ID of the token.
    /// @param _originChainId The chain ID the token is native to.
    /// @param _tokenAddress The token's address on this chain.
    function trackLegacyTokenIfNeeded(bytes32 _assetId, uint256 _originChainId, address _tokenAddress) external;

    /// @notice Records an outgoing transfer from this chain (L2 -> L1 withdrawal or L2 -> L2 interop).
    /// @param _toChainId The destination chain id of the transfer.
    /// @param _assetId The bridged asset id.
    /// @param _amount The transferred amount.
    function handleInitiateBridgingOnL2(uint256 _toChainId, bytes32 _assetId, uint256 _amount) external;

    /// @notice Records an incoming transfer into this chain.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _assetId The asset ID of the token being bridged in.
    /// @param _amount The amount of tokens being bridged in.
    function handleFinalizeBridgingOnL2(uint256 _fromChainId, bytes32 _assetId, uint256 _amount) external;

    /// @notice Base-token counterpart of `handleInitiateBridgingOnL2`.
    /// @param _toChainId The destination chain id of the transfer.
    /// @param _amount The amount of base tokens being bridged out.
    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external;

    /// @notice Base-token counterpart of `handleFinalizeBridgingOnL2`.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _amount The amount of base tokens being bridged in.
    function handleFinalizeBaseTokenBridgingOnL2(uint256 _fromChainId, uint256 _amount) external;

    /// @notice Asserts that recovering a failed bridge-out originally destined to `_toChainId`
    /// needs no bookkeeping reversal beyond re-crediting the vault's `bridgedOut`:
    /// `totalWithdrawalsToL1` is append-only (L2 -> L1 withdrawals are never revertable), and the
    /// base token never originates from this chain.
    /// @param _assetId The asset being recovered.
    /// @param _toChainId The original bridge-out destination chain id.
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) external view;

    /// @notice Base-token counterpart of `assertRecoveryIsAccountingNeutral`.
    /// @param _toChainId The original bridge-out destination chain id.
    function assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) external view;
}
