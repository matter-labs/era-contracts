// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2AssetRouter} from "./L2AssetRouter.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "../interfaces/IL2SharedBridgeLegacy.sol";
import {IL2NativeTokenVault} from "../ntv/IL2NativeTokenVault.sol";
import {InteropRoute} from "../../common/Messaging.sol";
import {EmptyAddress} from "../../common/L1ContractErrors.sol";

/// @title PrivateL2AssetRouter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of L2AssetRouter. Deployed at user-space addresses,
/// uses private NTV/InteropCenter/InteropHandler instead of system contract addresses.
contract PrivateL2AssetRouter is L2AssetRouter {
    address private _privateNtv;
    address private _privateInteropCenter;
    address private _privateInteropHandler;

    /// @notice Initializes the private asset router.
    function initialize(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        IL1AssetRouter _l1AssetRouter,
        bytes32 _baseTokenAssetId,
        address _ntv,
        address _interopCenter,
        address _interopHandler
    ) external reentrancyGuardInitializer {
        _disableInitializers();

        _privateNtv = _ntv;
        _privateInteropCenter = _interopCenter;
        _privateInteropHandler = _interopHandler;

        require(address(_l1AssetRouter) != address(0), EmptyAddress());
        L1_CHAIN_ID = _l1ChainId;
        L1_ASSET_ROUTER = _l1AssetRouter;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        ERA_CHAIN_ID = _eraChainId;

        _setAssetHandler(_baseTokenAssetId, _ntv);
        _transferOwnership(msg.sender);
    }

    function _nativeTokenVaultAddr() internal view override returns (address) {
        return _privateNtv;
    }

    function _interopCenterAddr() internal view override returns (address) {
        return _privateInteropCenter;
    }

    function _interopHandlerAddr() internal view override returns (address) {
        return _privateInteropHandler;
    }

    function _expectedInteropRoute() internal pure override returns (InteropRoute) {
        return InteropRoute.Private;
    }

    function _l2AssetRouterAddress() internal view override returns (address) {
        return address(this);
    }
}
