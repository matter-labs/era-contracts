// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {IInteropCenter} from "./IInteropCenter.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetDeploymentTracker} from "../bridge/interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ICTMDeploymentTracker is IL1AssetDeploymentTracker {
    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _l2Value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function L1_ASSET_ROUTER() external view returns (IAssetRouterBase);

    function INTEROP_CENTER() external view returns (IInteropCenter);

    function registerCTMAssetOnL1(address _ctmAddress) external;

    function calculateAssetId(address _l1CTM) external view returns (bytes32);
}
