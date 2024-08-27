// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner, IBridgehub} from "./IBridgehub.sol";
import {IAssetRouterBase} from "../bridge/interfaces/IAssetRouterBase.sol";
import {IL1AssetDeploymentTracker} from "../bridge/interfaces/IL1AssetDeploymentTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ISTMDeploymentTracker is IL1AssetDeploymentTracker {
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function L1_ASSET_ROUTER() external view returns (IAssetRouterBase);

    function registerSTMAssetOnL1(address _stmAddress) external;

    function getAssetId(address _l1STM) external view returns (bytes32);
}
