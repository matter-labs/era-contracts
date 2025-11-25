// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IL1Bridgehub} from "./IL1Bridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1ChainAssetHandler {
    function isMigrationInProgress(uint256 _chainId) external view returns (bool);
}
