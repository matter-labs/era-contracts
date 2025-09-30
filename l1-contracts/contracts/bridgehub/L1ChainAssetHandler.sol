// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IL1Bridgehub} from "./IL1Bridgehub.sol";
import {IBridgehubBase} from "./IBridgehubBase.sol";
import {IMessageRoot} from "./IMessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase {
    /// @dev The assetId of the base token.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 internal immutable L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    IL1Bridgehub internal immutable BRIDGEHUB;

    /// @dev The message root contract.
    IMessageRoot internal immutable MESSAGE_ROOT;

    /// @dev The asset router contract.
    address internal immutable ASSET_ROUTER;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (IBridgehubBase) {
        return BRIDGEHUB;
    }
    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }
    function _assetRouter() internal view override returns (address) {
        return ASSET_ROUTER;
    }

    constructor(
        uint256 _l1ChainId,
        address _owner,
        IL1Bridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }
}
