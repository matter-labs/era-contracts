// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {INativeTokenVaultBase} from "./INativeTokenVaultBase.sol";

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

    /// @notice Whether the chain-local bookkeeping for the token has been initialized.
    function isAssetTracked(bytes32 _assetId) external view returns (bool);

    /// @notice The token's net inbound flow (successful deposits minus successful withdrawals)
    /// accumulated before this bookkeeping existed; native tokens offset it by `MAX_TOKEN_BALANCE`.
    function preTrackingTotalSupply(bytes32 _assetId) external view returns (bool isSaved, uint256 amount);

    /// @notice L2-side accounting of L1 <-> L2 flows while this chain settles on L1.
    function interopInfo(
        bytes32 _assetId
    ) external view returns (uint256 totalWithdrawalsToL1, uint256 totalSuccessfulDepositsFromL1);

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
    /// @dev The base token is rejected: it is escrowed in BaseTokenHolder and has no vault escrow
    /// to seed.
    function trackLegacyToken(bytes32 _assetId) external;

    function setLegacyTokenAssetId(address _l2TokenAddress) external;
}
