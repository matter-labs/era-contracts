// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1CrossChainSender} from "../interfaces/IL1CrossChainSender.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {InteropBundle, TxStatus} from "../../common/Messaging.sol";
import {AtomicFlowPreimage} from "../../atomic-interop/IAtomicInterop.sol";

/// @title L1 Asset Router interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 side of asset routing. See {protocol-docs/bridging.md#asset-routing-burn--mint}.
interface IL1AssetRouter is IAssetRouterBase, IL1CrossChainSender {
    event ClaimedFailedDepositAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    /// @notice Emitted when a deposit is committed through interop. It carries everything needed to execute it on
    /// the destination with `L2InteropHandler.executeAtomicBundle`.
    /// @param chainId The destination chain.
    /// @param bundleHash The deposit bundle's hash.
    /// @param l1BatchNumber The batch of L1 the deposit's leg settled in.
    /// @param flowPreimage The deposit's one-leg flow.
    /// @param bundle The deposit bundle.
    event InteropDepositCommitted(
        uint256 indexed chainId,
        bytes32 indexed bundleHash,
        uint256 l1BatchNumber,
        AtomicFlowPreimage flowPreimage,
        InteropBundle bundle
    );

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    function ETH_TOKEN_ASSET_ID() external view returns (bytes32);

    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    function nativeTokenVault() external view returns (INativeTokenVaultBase);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    function setNativeTokenVault(INativeTokenVaultBase _nativeTokenVault) external;

    function setL1InteropHandler(address _l1InteropHandler) external;

    /// @notice Deposits an asset to a ZK chain through interop instead of the priority queue. The deposit becomes a
    /// one-leg atomic flow sourced on L1: its leg is committed to L1's commitment tree in the L1 MessageRoot, reaches
    /// the destination in the next interop root it imports, and is executed there by anyone with
    /// `L2InteropHandler.executeAtomicBundle`, like any other interop transfer.
    /// @dev The destination must settle on L1. The tokens are taken as on the two-bridges path (the native token
    /// vault pulls them from the caller); the destination's base token is not supported.
    /// @param _chainId The destination chain.
    /// @param _assetId The asset id.
    /// @param _transferData The asset handler's transfer data (for the native token vault: amount and receiver).
    /// @param _lowNullifierIndex A hint for the leaf preceding the leg's commit value in L1's commitment tree.
    /// @return bundleHash The deposit bundle's hash.
    function depositViaInterop(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData,
        uint256 _lowNullifierIndex
    ) external payable returns (bytes32 bundleHash);

    /// @notice Confirms the result of an initiated deposit, dispatching it to the asset handler
    /// (on failure the deposited funds are disbursed back to the depositor).
    /// @dev Called by the L1Nullifier after it has verified and cleared the recorded deposit.
    /// @param _chainId The ZK chain id to which the deposit was initiated.
    /// @param _txStatus The status the L1 -> L2 deposit transaction finalized with.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    function bridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external;
}
