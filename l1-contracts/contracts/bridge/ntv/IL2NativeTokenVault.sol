// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";
import {L2AssetBookkeepingInfo} from "../../common/L2AssetBookkeeping.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVault is INativeTokenVaultBase {
    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event L2TokenBeaconUpdated(address indexed l2TokenBeacon, bytes32 indexed l2TokenProxyBytecodeHash);

    function l2TokenAddress(address _l1Token) external view returns (address);

    /// @notice The base token asset ID
    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice The wrapped base token (WETH) address
    function WETH_TOKEN() external view returns (address);

    /// @notice The chain ID of L1, set during genesis or upgrade.
    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Chain-local bookkeeping of the asset's L1 <-> L2 flows and its pre-tracking
    /// baseline; see {L2AssetBookkeepingInfo}.
    function getAssetBookkeeping(bytes32 _assetId) external view returns (L2AssetBookkeepingInfo memory);

    /// @notice Records an outbound base-token bridge flow under `BASE_TOKEN_ASSET_ID`.
    /// @dev Callable only by BaseTokenHolder, which escrows the base token and therefore observes
    /// its contract-level bridge flows.
    /// @param _toChainId The chain ID which the funds are sent to.
    /// @param _amount The bridged amount.
    function recordBaseTokenBridgingToChain(uint256 _toChainId, uint256 _amount) external;

    /// @notice Records an inbound base-token bridge flow under `BASE_TOKEN_ASSET_ID`.
    /// @dev Callable only by BaseTokenHolder.
    /// @param _fromChainId The source chain ID of the bridging operation.
    /// @param _amount The bridged amount.
    function recordBaseTokenBridgingFromChain(uint256 _fromChainId, uint256 _amount) external;

    /// @notice Eagerly initializes the chain-local bookkeeping for a legacy non-base token.
    /// @dev The base token is rejected: its baseline is recorded by `trackBaseToken` during the
    /// upgrade/genesis, and it has no vault escrow to seed.
    function trackLegacyToken(bytes32 _assetId) external;

    /// @notice Records the base token's pre-tracking baseline, once.
    /// @dev Called during the upgrade/genesis (only the upgrader may call it), before any flow the
    /// holder can report, so the baseline and the recorded flows never overlap.
    function trackBaseToken() external;

    /// @notice Asserts that recovering a failed bridge-out originally destined to `_toChainId`
    /// needs no bookkeeping reversal beyond re-crediting `bridgedOut`: `totalWithdrawalsToL1` is
    /// append-only (L2 -> L1 withdrawals are never revertable), and the base token never
    /// originates from this chain.
    /// @param _assetId The asset being recovered.
    /// @param _toChainId The original bridge-out destination chain id.
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) external view;

    function setLegacyTokenAssetId(address _l2TokenAddress) external;
}
