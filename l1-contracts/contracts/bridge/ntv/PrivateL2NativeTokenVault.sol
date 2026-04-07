// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";

import {L2NativeTokenVaultZKOS} from "./L2NativeTokenVaultZKOS.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {IAssetTrackerBase} from "../asset-tracker/IAssetTrackerBase.sol";
import {TokenBridgingData, TokenMetadata} from "../../common/Messaging.sol";
import {EmptyAddress, EmptyBytes32} from "../../common/L1ContractErrors.sol";

/// @title PrivateL2NativeTokenVault
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of L2NativeTokenVault. Deployed at user-space addresses,
/// uses private AssetRouter and AssetTracker instead of system contract addresses.
/// Inherits from L2NativeTokenVaultZKOS for standard EVM CREATE2 token deployment.
contract PrivateL2NativeTokenVault is L2NativeTokenVaultZKOS {
    address private _privateAssetRouter;
    address private _privateAssetTracker;

    /// @notice Initializes the private native token vault.
    function initialize(
        uint256 _l1ChainId,
        address _assetRouter,
        address _assetTracker,
        address _bridgedTokenBeacon,
        bytes32 _l2TokenProxyBytecodeHash,
        address _wethToken,
        TokenBridgingData calldata _baseTokenBridgingData,
        TokenMetadata calldata _baseTokenMetadata
    ) external reentrancyGuardInitializer {
        _disableInitializers();

        _privateAssetRouter = _assetRouter;
        _privateAssetTracker = _assetTracker;

        require(_wethToken != address(0), EmptyAddress());
        require(_bridgedTokenBeacon != address(0), EmptyAddress());
        require(_l2TokenProxyBytecodeHash != bytes32(0), EmptyBytes32());

        WETH_TOKEN = _wethToken;
        BASE_TOKEN_ASSET_ID = _baseTokenBridgingData.assetId;
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ORIGIN_TOKEN = _baseTokenBridgingData.originToken;
        BASE_TOKEN_NAME = _baseTokenMetadata.name;
        BASE_TOKEN_SYMBOL = _baseTokenMetadata.symbol;
        BASE_TOKEN_DECIMALS = _baseTokenMetadata.decimals;

        L2_TOKEN_PROXY_BYTECODE_HASH = _l2TokenProxyBytecodeHash;
        bridgedTokenBeacon = IBeacon(_bridgedTokenBeacon);

        _transferOwnership(msg.sender);
    }

    function _assetRouter() internal view override returns (IAssetRouterBase) {
        return IAssetRouterBase(_privateAssetRouter);
    }

    function _assetTracker() internal view override returns (IAssetTrackerBase) {
        return IAssetTrackerBase(_privateAssetTracker);
    }
}
