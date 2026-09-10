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
/// @notice Chain-local token bookkeeping hooks called by the NTV, BaseTokenHolder and L2BaseToken.
/// See {protocol-docs/bridging.md#l2-asset-tracker}.
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

    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Balance tracked only for tokens native to this chain; write-mostly bookkeeping that no
    /// bridging decision consults. May be removed in the future — don't rely on it.
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Whether the token's `chainBalance` and pre-v31 supply snapshot are initialized.
    function isAssetRegistered(bytes32 _assetId) external view returns (bool);

    /// @notice Registers a token on its first bridge operation, initializing its `chainBalance` and
    /// pre-v31 total-supply snapshot. No-op if already registered.
    /// @param _assetId The asset ID of the token.
    /// @param _originChainId The chain ID the token is native to.
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external;

    /// @notice Initializes the tracker at genesis.
    /// @param _l1ChainId The chain ID of the L1 network.
    /// @param _baseTokenAssetId The asset ID of the chain's base token.
    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external;

    /// @notice Records an outgoing transfer from this chain (L2 -> L1 withdrawal or L2 -> L2 interop).
    /// @param _toChainId The destination chain id of the transfer.
    /// @param _assetId The bridged asset id.
    /// @param _amount The transferred amount.
    /// @param _tokenOriginChainId Origin chain id of the bridged token.
    function handleInitiateBridgingOnL2(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external;

    /// @notice Base-token counterpart of `handleInitiateBridgingOnL2`.
    /// @param _maybeToBlockChainId The destination chain id of the transfer.
    /// @param _amount The amount of base tokens being bridged out.
    function handleInitiateBaseTokenBridgingOnL2(uint256 _maybeToBlockChainId, uint256 _amount) external;

    /// @notice Asserts that recovering a failed bridge-out originally destined to `_toChainId` needs no
    /// bookkeeping reversal beyond the `chainBalance` re-credit `handleFinalizeBridgingOnL2` performs:
    /// `totalWithdrawalsToL1` is append-only (L2 -> L1 withdrawals are never revertable), and the base
    /// token never originates from this chain (so it has no `chainBalance` at all).
    /// @param _assetId The asset being recovered.
    /// @param _toChainId The original bridge-out destination chain id.
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) external view;

    /// @notice Base-token counterpart of `assertRecoveryIsAccountingNeutral`, called when a failed/
    /// timed-out base-token bridge-out's escrow is returned via `BaseTokenHolder.recoverBaseToken`.
    /// @param _toChainId The original bridge-out destination chain id.
    function assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) external view;

    /// @notice Base-token counterpart of `handleFinalizeBridgingOnL2`.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _amount The amount of base tokens being bridged in.
    function handleFinalizeBaseTokenBridgingOnL2(uint256 _fromChainId, uint256 _amount) external;

    /// @notice Records an incoming transfer into this chain.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _assetId The asset ID of the token being bridged in.
    /// @param _amount The amount of tokens being bridged in.
    /// @param _tokenOriginChainId The chain ID where the token was originally created.
    /// @param _tokenAddress The contract address of the token on this chain.
    function handleFinalizeBridgingOnL2(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external;

    /// @notice Eagerly registers a pre-v31 (legacy) token, storing its total-supply snapshot before its
    /// first post-v31 bridge operation. Permissionless; no-op if already registered.
    function registerLegacyToken(bytes32 _assetId) external;
}
