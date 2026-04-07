// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteropCenter} from "./InteropCenter.sol";
import {PrivateInteropValueNotZero, ZKTokenNotAvailable} from "./InteropErrors.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";

import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {PRIVATE_BUNDLE_IDENTIFIER} from "../common/Messaging.sol";

/// @title PrivateInteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of InteropCenter. Sends only bundleHash + callCount to L1,
/// keeping bundle contents hidden. Deployed at user-space addresses.
contract PrivateInteropCenter is InteropCenter {
    address private _privateAssetRouter;
    address private _privateNtv;

    /// @notice Configurable base token asset IDs for destination chains.
    /// Used on pre-v31 chains where L2Bridgehub doesn't know about other chains.
    mapping(uint256 chainId => bytes32 assetId) public destinationBaseTokenAssetIds;

    /// @notice Initializes the private interop center.
    function initialize(
        uint256 _l1ChainId,
        address _owner,
        bytes32 _zkTokenAssetId,
        address _assetRouter,
        address _ntv
    ) external reentrancyGuardInitializer {
        _disableInitializers();

        _privateAssetRouter = _assetRouter;
        _privateNtv = _ntv;

        require(_zkTokenAssetId != bytes32(0), ZKTokenNotAvailable());
        ZK_TOKEN_ASSET_ID = _zkTokenAssetId;

        require(_owner != address(0), ZeroAddress());
        L1_CHAIN_ID = _l1ChainId;
        ZK_INTEROP_FEE = 10e18;
        _transferOwnership(_owner);
    }

    /// @notice Registers a destination chain's base token asset ID.
    /// @dev Only needed on pre-v31 chains where L2Bridgehub.baseTokenAssetId() returns 0.
    function setDestinationBaseTokenAssetId(uint256 _chainId, bytes32 _assetId) external onlyOwner {
        destinationBaseTokenAssetIds[_chainId] = _assetId;
    }

    function _assetRouterAddr() internal view override returns (address) {
        return _privateAssetRouter;
    }

    function _nativeTokenVault() internal view override returns (IL2NativeTokenVault) {
        return IL2NativeTokenVault(_privateNtv);
    }

    /// @notice Rejects any call with interopCallValue > 0.
    function _validateCallStarterValue(uint256 _interopCallValue) internal pure override {
        require(_interopCallValue == 0, PrivateInteropValueNotZero());
    }

    /// @notice Private interop does not collect base-token value (no interopCallValue allowed).
    function _handleValueCollection(
        uint256 /* _destinationChainId */,
        bytes32 /* _destinationBaseTokenAssetId */,
        uint256 /* _totalBurnedCallsValue */,
        uint256 /* _totalIndirectCallsValue */,
        bool /* _useFixedFee */,
        uint256 /* _callCount */
    ) internal override {
        // No base-token value collection for private interop.
    }

    /// @notice Skip gateway mode check — private interop works on any chain.
    function _validateGatewayMode() internal view override {
        // No-op: private interop doesn't require gateway mode.
    }

    /// @notice Returns destination base token asset ID from local mapping or falls back to L2Bridgehub.
    function _getDestinationBaseTokenAssetId(uint256 _destinationChainId) internal view override returns (bytes32) {
        bytes32 assetId = destinationBaseTokenAssetIds[_destinationChainId];
        if (assetId != bytes32(0)) {
            return assetId;
        }
        // Fall back to the default behavior
        return super._getDestinationBaseTokenAssetId(_destinationChainId);
    }

    /// @notice Sends only hash + callCount to L1 instead of full bundle data.
    function _sendBundleToL1(bytes memory _interopBundleBytes, uint256 _callCount) internal override returns (bytes32) {
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodePacked(PRIVATE_BUNDLE_IDENTIFIER, keccak256(_interopBundleBytes), _callCount)
        );
        return bytes32(0);
    }
}
