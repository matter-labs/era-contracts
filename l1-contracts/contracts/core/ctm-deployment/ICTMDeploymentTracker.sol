// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetDeploymentTracker} from "../../bridge/interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ICTMDeploymentTracker is IL1AssetDeploymentTracker {
    function BRIDGE_HUB() external view returns (IBridgehubBase);

    function L1_ASSET_ROUTER() external view returns (IAssetRouterBase);

    function registerCTMAssetOnL1(address _ctmAddress) external;

    function calculateAssetId(address _l1CTM) external view returns (bytes32);
}
