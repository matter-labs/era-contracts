// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {InvalidCaller} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2ChainAssetHandler is ChainAssetHandlerBase {
    /// @dev The assetId of the ETH.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public override ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public override L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public override BRIDGEHUB;

    /// @dev The message root contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public override MESSAGE_ROOT;

    /// @dev The asset router contract.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public override ASSET_ROUTER;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (address) {
        return BRIDGEHUB;
    }

    function _messageRoot() internal view override returns (address) {
        return MESSAGE_ROOT;
    }

    function _assetRouter() internal view override returns (address) {
        return ASSET_ROUTER;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        address _bridgehub,
        address _assetRouter,
        address _messageRoot
    ) external reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();

        updateL2(_l1ChainId, _bridgehub, _assetRouter, _messageRoot);

        _transferOwnership(_owner);
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2ChainAssetHandler on existing chains during
    /// the upgrade.
    function updateL2(
        uint256 _l1ChainId,
        address _bridgehub,
        address _assetRouter,
        address _messageRoot
    ) public onlyUpgrader {
        BRIDGEHUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
    }
}
