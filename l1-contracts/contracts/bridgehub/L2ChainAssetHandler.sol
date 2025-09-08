// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/// @dev L2 version – no immutables; values are stored and set once in `initL2`.
contract L2ChainAssetHandler is ChainAssetHandlerBase {
    bytes32 private ethTokenAssetId;
    uint256 private l1ChainId;
    IBridgehub private bridgehub;
    IMessageRoot private messageRoot;
    address private assetRouter;

    /// @notice One-time initializer (replaces constructor on L2).
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) external reentrancyGuardInitializer {
        _disableInitializers();

        updateL2(_l1ChainId, _bridgehub, _assetRouter, _messageRoot);

        _transferOwnership(_owner);
    }

    function updateL2(
        uint256 _l1ChainId,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) public {
        bridgehub = _bridgehub;
        l1ChainId = _l1ChainId;
        assetRouter = _assetRouter;
        messageRoot = _messageRoot;
        ethTokenAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ethTokenAssetId;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return l1ChainId;
    }
    function _bridgehub() internal view override returns (IBridgehub) {
        return bridgehub;
    }
    function _messageRoot() internal view override returns (IMessageRoot) {
        return messageRoot;
    }
    function _assetRouter() internal view override returns (address) {
        return assetRouter;
    }
}
