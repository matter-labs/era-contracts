// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2AssetRouter} from "./L2AssetRouter.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {InteropRoute} from "../../common/Messaging.sol";
import {EmptyAddress, Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title PrivateL2AssetRouter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of L2AssetRouter. Deployed at user-space addresses,
/// uses private NTV/InteropCenter/InteropHandler instead of system contract addresses.
contract PrivateL2AssetRouter is L2AssetRouter {
    address private _privateNtv;
    address private _privateInteropCenter;
    address private _privateInteropHandler;

    /// @notice Maps destination chain ID to the PrivateL2AssetRouter address on that chain.
    /// Required when private interop contracts have different addresses across chains.
    mapping(uint256 chainId => address router) public remoteRouterAddress;

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

    /// @notice Registers the PrivateL2AssetRouter address on a remote chain.
    /// @param _chainId The destination chain ID.
    /// @param _router The PrivateL2AssetRouter address on that chain.
    function setRemoteRouter(uint256 _chainId, address _router) external onlyOwner {
        remoteRouterAddress[_chainId] = _router;
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

    /// @notice Returns the AssetRouter address on the destination chain.
    /// If a remote router is registered for that chain, returns it.
    /// Otherwise falls back to address(this) (works when all chains share the same address).
    function _l2AssetRouterAddress(uint256 _destinationChainId) internal view override returns (address) {
        address remote = remoteRouterAddress[_destinationChainId];
        require(remote != address(0), EmptyAddress());
        return remote;
    }

    /// @notice Accepts messages from registered remote AssetRouters in addition to self.
    function _validateAssetRouterCounterpart(uint256 _senderChainId, address _senderAddress) internal view override {
        if (_senderAddress == address(this)) return;
        address registered = remoteRouterAddress[_senderChainId];
        require(registered != address(0) && registered == _senderAddress, Unauthorized(_senderAddress));
    }
}
