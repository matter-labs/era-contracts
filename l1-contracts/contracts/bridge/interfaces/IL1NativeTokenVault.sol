// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IL1SharedBridge} from "./IL1SharedBridge.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1NativeTokenVault {
    function L1_SHARED_BRIDGE() external view returns (IL1SharedBridge);

    function registerToken(address _l1Token) external;

    function getAssetInfoFromLegacy(address l1TokenAddress) external view returns (bytes32);

    function getAssetInfo(address l1TokenAddress) external view returns (bytes32);
}
