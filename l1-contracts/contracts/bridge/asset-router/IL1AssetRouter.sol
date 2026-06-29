// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1CrossChainSender} from "../interfaces/IL1CrossChainSender.sol";
import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {TxStatus} from "../../common/Messaging.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouter is IAssetRouterBase, IL1CrossChainSender {
    event ClaimedFailedDepositAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_WETH_TOKEN() external view returns (address);

    function ETH_TOKEN_ASSET_ID() external view returns (bytes32);

    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    function ERA_CHAIN_ID() external view returns (uint256);

    function ERA_DIAMOND_PROXY() external view returns (IZKChain);

    function nativeTokenVault() external view returns (INativeTokenVaultBase);

    function setAssetDeploymentTracker(bytes32 _assetRegistrationData, address _assetDeploymentTracker) external;

    function setNativeTokenVault(INativeTokenVaultBase _nativeTokenVault) external;

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which the deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external;

}
