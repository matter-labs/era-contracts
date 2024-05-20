// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner, IBridgehub} from "./IBridgehub.sol";
import {IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";

interface ISTMDeploymentTracker {
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    ) external returns (L2TransactionRequestTwoBridgesInner memory request);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function SHARED_BRIDGE() external view returns (IL1SharedBridge);

    function registerSTMAssetOnL1(address _stmAddress) external;
}
