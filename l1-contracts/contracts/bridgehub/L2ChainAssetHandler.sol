// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev Important: L2 contracts are not allowed to have any constructor. This is needed for compatibility with ZKsyncOS.
contract L2ChainAssetHandler is ChainAssetHandlerBase {
    /// @dev The assetId of the base token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 private ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 private L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    IBridgehub private BRIDGEHUB;

    /// @dev The message root contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    IMessageRoot private MESSAGE_ROOT;

    /// @dev The asset router contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address private ASSET_ROUTER;

    /// @notice One-time initializer (replaces constructor on L2).
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) external reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();

        updateL2(_l1ChainId, _bridgehub, _assetRouter, _messageRoot);

        _transferOwnership(_owner);
    }

    function updateL2(
        uint256 _l1ChainId,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) external onlyUpgrader {
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
