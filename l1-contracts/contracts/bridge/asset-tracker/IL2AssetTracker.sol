// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev A token's total-supply snapshot; `isSaved` distinguishes "not captured yet" from a zero amount.
struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

/// @title L2 Asset Tracker interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Chain-local asset bookkeeping hooks called by the NTV, BaseTokenHolder and L2BaseToken.
/// See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
interface IL2AssetTracker {
    struct InteropL2Info {
        // Amount withdrawn to L1 while the chain settled on L1.
        uint256 totalWithdrawalsToL1;
        // Amount successfully finalized from L1 while the chain settled on L1.
        // For base token, failed deposits are refunded on L2 to the refundRecipient rather than
        // later claimed on L1, so the gap between initiated deposits and this counter should not
        // be interpreted as uniformly "claimable on L1" across all asset types.
        uint256 totalSuccessfulDepositsFromL1;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice The asset ID of the chain's base token, set during genesis or the v31 upgrade.
    // solhint-disable-next-line func-name-mixedcase
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Whether the token's pre-tracking supply snapshot is initialized.
    function isAssetRegistered(bytes32 _assetId) external view returns (bool);

    /// @notice The asset's L1 deposit/withdrawal counters; see {InteropL2Info}.
    function interopInfo(
        bytes32 _assetId
    ) external view returns (uint256 totalWithdrawalsToL1, uint256 totalSuccessfulDepositsFromL1);

    /// @notice The asset's total-supply snapshot, captured before its first tracked bridge operation.
    function totalPreV31TotalSupply(bytes32 _assetId) external view returns (bool isSaved, uint256 amount);

    /// @notice Initializes the tracker at genesis.
    /// @param _l1ChainId The chain ID of the L1 network.
    /// @param _baseTokenAssetId The asset ID of the chain's base token.
    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external;

    /// @notice Registers the base token, snapshotting its current supply. No-op if already registered.
    /// @dev Called during the upgrade/genesis (only the upgrader may call it), before any flow the
    /// BaseTokenHolder can report, so the snapshot and the recorded flows never overlap.
    function trackBaseToken() external;

    /// @notice Registers a token registered on the vault after the tracker, which by construction has
    /// no pre-tracking flows. No-op if already registered.
    /// @param _assetId The asset ID of the token.
    /// @param _originChainId The chain ID the token is native to.
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external;

    /// @notice Registers a token that predates the tracker, capturing its pre-tracking supply
    /// snapshot. No-op if already registered.
    /// @dev Must be called before the triggering operation changes the token's supply or the
    /// vault's escrow, both of which the snapshot is derived from. The vault drives this (rather
    /// than the tracker exposing it directly) so that the snapshot and the vault's `bridgedOut`
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
