// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1CrossChainSender} from "../interfaces/IL1CrossChainSender.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {InteropCallStarter, TxStatus} from "../../common/Messaging.sol";

/// @title L1 Asset Router interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 side of asset routing. See {protocol-docs/bridging.md#asset-routing-burn--mint}.
interface IL1AssetRouter is IAssetRouterBase, IL1CrossChainSender {
    event ClaimedFailedDepositAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    /// @notice The L1 interop center was set.
    event L1InteropCenterSet(address indexed l1InteropCenter);

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    function ETH_TOKEN_ASSET_ID() external view returns (bytes32);

    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    function nativeTokenVault() external view returns (INativeTokenVaultBase);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    function setNativeTokenVault(INativeTokenVaultBase _nativeTokenVault) external;

    function setL1InteropHandler(address _l1InteropHandler) external;

    /// @notice The L1 interop center, the only caller of {initiateIndirectCall}.
    function l1InteropCenter() external view returns (address);

    /// @notice Sets the L1 interop center. Callable by the owner and by the upgrade authority. It can be replaced:
    /// see {protocol-docs/interop.md#replacing-the-counterparts}.
    /// @param _l1InteropCenter The address of the L1 interop center.
    function setL1InteropCenter(address _l1InteropCenter) external;

    /// @notice Burns or locks an asset for a chain that settles on this chain and returns the call that mints it
    /// there, for a one-way bundle of the L1 interop center. Never the destination's base token, and no value.
    /// See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
    /// @param _chainId The destination chain.
    /// @param _originalCaller The sender of the bundle, whose asset is taken.
    /// @param _data The same data as the second-bridge data of an asset deposit through the Bridgehub.
    /// @return interopCallStarter The call to the destination chain's asset router.
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        bytes calldata _data
    ) external returns (InteropCallStarter memory interopCallStarter);

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
