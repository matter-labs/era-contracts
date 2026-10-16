// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";
import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";

/// @notice A governance-provided amount of an asset a chain held before its deposits and withdrawals were
/// recorded. See {protocol-docs/interop-gating.md#backfill}.
/// @param amount The backfill amount.
/// @param set Whether governance set the backfill, which tells a zero backfill from none.
struct ChainBalanceBackfill {
    uint256 amount;
    bool set;
}

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface IL1NativeTokenVault is INativeTokenVaultBase, IL1AssetDeploymentTracker {
    /// @notice The L1Nullifier contract
    function L1_NULLIFIER() external view returns (IL1Nullifier);

    /// @notice The base token asset ID
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Deprecated per-chain balance getter, kept for backwards compatibility only; it will
    /// revert in the next release. Use `bridgedOut` instead.
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Registers ETH token. Should be called once on local/new deployments.
    /// ETH token is expected to have been already initialized in production.
    function registerEthToken() external;

    /// @notice Net amount of the given L1-native asset currently bridged out of L1.
    function bridgedOut(bytes32 _assetId) external view returns (uint256);

    /// @notice Whether the pre-upgrade amount of `_assetId` has already been folded into `bridgedOut`.
    function bridgedOutPopulated(bytes32 _assetId) external view returns (bool);

    /// @notice The removed V31 `L1AssetTracker`, which holds the legacy per-chain accounting that
    /// `populateBridgedOut` reads. Zero on ecosystems deployed after the tracker was removed.
    function legacyL1AssetTracker() external view returns (address);

    /// @notice Net amount of `_assetId` that the pre-upgrade accounting had bridged out of L1.
    /// @dev Reverts with `AssetNotNativeToL1` unless the asset's origin chain is L1: the legacy sources only
    /// answer this question for L1-native assets.
    /// @param _assetId The asset to read the legacy amount of.
    /// @return amount The legacy amount; zero on an ecosystem with no legacy accounting left.
    function legacyBridgedOut(bytes32 _assetId) external view returns (uint256 amount);

    /// @notice Folds the pre-upgrade amount the legacy accounting recorded for each asset into
    /// `bridgedOut`, once per asset.
    /// See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
    /// @param _assetIds The L1-native assets to populate; assets already populated are skipped.
    /// @return populatedAmounts Per entry of `_assetIds`, the amount added to that asset's
    /// `bridgedOut`; zero for assets that were skipped or had no legacy amount.
    function populateBridgedOut(bytes32[] calldata _assetIds) external returns (uint256[] memory populatedAmounts);

    /// @notice Total amount of `_assetId` deposited into `_chainId` through this vault while the chain had
    /// no interop. For `INTEROP_POOL_CHAIN_ID`, the total deposited into the chains with interop, moved chain
    /// balances included. See {protocol-docs/interop-gating.md#per-chain-balance-cap}.
    function chainTotalDeposited(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Total amount of `_assetId` withdrawn from `_chainId`, failed-deposit claims included, while
    /// the chain had no interop. For `INTEROP_POOL_CHAIN_ID`, the total withdrawn from the chains with interop,
    /// moved chain balances included.
    function chainTotalWithdrawn(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Governance-provided amount of `_assetId` the chain held before its deposits and withdrawals
    /// were recorded, and whether it was set. See {protocol-docs/interop-gating.md#backfill}.
    function chainBalanceBackfill(uint256 _chainId, bytes32 _assetId) external view returns (uint256 amount, bool set);

    /// @notice Whether the balance of `_chainId` in `_assetId` was moved to the interop pool.
    /// See {protocol-docs/interop-gating.md#interop-pool}.
    function chainBalanceInInteropPool(uint256 _chainId, bytes32 _assetId) external view returns (bool);

    /// @notice Sets the backfill of `_chainId` for each asset, once per chain and asset.
    /// See {protocol-docs/interop-gating.md#backfill}.
    /// @param _chainId The chain to set the backfill for.
    /// @param _assetIds The assets to set the backfill for.
    /// @param _amounts The backfill amounts, one per entry of `_assetIds`.
    function setChainBalanceBackfill(
        uint256 _chainId,
        bytes32[] calldata _assetIds,
        uint256[] calldata _amounts
    ) external;

    /// @notice Moves the balance of `_chainId` in `_assetId`, its backfill included, to the interop pool.
    /// Callable by anyone once the chain has interop and its backfill for the asset is set.
    /// See {protocol-docs/interop-gating.md#interop-pool}.
    /// @param _chainId The chain with interop.
    /// @param _assetId The asset to move.
    function moveChainBalanceToInteropPool(uint256 _chainId, bytes32 _assetId) external;

    event TokenBeaconUpdated(address indexed l2TokenBeacon);

    /// @notice Emitted with the new backfill of `assetId` on `chainId`.
    event ChainBalanceBackfilled(uint256 indexed chainId, bytes32 indexed assetId, uint256 amount);

    /// @notice Emitted when the balance of `chainId` in `assetId` moves to the interop pool.
    event ChainBalanceMovedToInteropPool(
        uint256 indexed chainId,
        bytes32 indexed assetId,
        uint256 deposited,
        uint256 withdrawn
    );

    /// @notice Emitted for every asset folded into `bridgedOut`, including zero amounts.
    event BridgedOutPopulated(bytes32 indexed assetId, uint256 amount);
}
