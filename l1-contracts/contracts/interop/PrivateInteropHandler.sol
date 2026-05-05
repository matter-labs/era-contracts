// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteropHandler} from "./InteropHandler.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";

import {PRIVATE_BUNDLE_IDENTIFIER, BundleStatus, InteropBundle, MessageInclusionProof} from "../common/Messaging.sol";

/// @title PrivateInteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of InteropHandler. Verifies bundles using hash + callCount
/// instead of full bundle data. Deployed at user-space addresses.
contract PrivateInteropHandler is InteropHandler {
    address private _privateInteropCenter;
    address private _privateNtv;

    /// @notice Initializes the private interop handler.
    function initialize(uint256 _l1ChainId, address _interopCenter, address _ntv) external reentrancyGuardInitializer {
        L1_CHAIN_ID = _l1ChainId;
        _privateInteropCenter = _interopCenter;
        _privateNtv = _ntv;
    }

    function _interopCenterAddr() internal view override returns (address) {
        return _privateInteropCenter;
    }

    function _nativeTokenVault() internal view override returns (IL2NativeTokenVault) {
        return IL2NativeTokenVault(_privateNtv);
    }

    /// @notice Returns private message format: PRIVATE_BUNDLE_IDENTIFIER + hash + callCount.
    function _getBundleMessageData(bytes memory _bundle) internal pure override returns (bytes memory) {
        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        return abi.encodePacked(PRIVATE_BUNDLE_IDENTIFIER, keccak256(_bundle), uint256(interopBundle.calls.length));
    }
}
