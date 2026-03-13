// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteropCenter} from "./InteropCenter.sol";
import {PrivateInteropValueNotZero} from "./InteropErrors.sol";

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

        require(_zkTokenAssetId != bytes32(0));
        ZK_TOKEN_ASSET_ID = _zkTokenAssetId;

        require(_owner != address(0));
        L1_CHAIN_ID = _l1ChainId;
        ZK_INTEROP_FEE = 10e18;
        _transferOwnership(_owner);
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
        uint256,
        bytes32,
        uint256,
        uint256,
        bool,
        uint256
    ) internal override {
        // No base-token value collection for private interop.
    }

    /// @notice Sends only hash + callCount to L1 instead of full bundle data.
    function _sendBundleToL1(
        bytes memory _interopBundleBytes,
        uint256 _callCount
    ) internal override returns (bytes32) {
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodePacked(PRIVATE_BUNDLE_IDENTIFIER, keccak256(_interopBundleBytes), _callCount)
        );
        return bytes32(0);
    }
}
