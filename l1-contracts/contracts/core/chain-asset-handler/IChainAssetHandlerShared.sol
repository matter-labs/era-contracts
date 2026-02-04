// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";

/// @author Matter Labs
/// Shared functions that are not inherited to avoid double inheritance.
/// @custom:security-contact security@matterlabs.dev
interface IChainAssetHandlerShared {
    /*//////////////////////////////////////////////////////////////
                            EXTERNAL GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The asset ID of ETH token
    function ETH_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice The chain ID of L1
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice The bridgehub contract
    function BRIDGEHUB() external view returns (IL1Bridgehub);

    /// @notice The message root contract
    function MESSAGE_ROOT() external view returns (IMessageRoot);

    /// @notice The asset router contract
    function ASSET_ROUTER() external view returns (IAssetRouterBase);
}
