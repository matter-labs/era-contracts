// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2AssetTracker} from "./L2AssetTracker.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {AssetIdNotRegistered} from "./AssetTrackerErrors.sol";

/// @title PrivateL2AssetTracker
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Private interop variant of L2AssetTracker. Deployed at user-space addresses,
/// uses private NTV instead of system contract address.
contract PrivateL2AssetTracker is L2AssetTracker {
    address private _privateNtv;

    /// @notice Initializes the private asset tracker.
    function initialize(uint256 _l1ChainId, bytes32 _baseTokenAssetId, address _ntv) external {
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        _privateNtv = _ntv;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return INativeTokenVaultBase(_privateNtv);
    }

    function _nativeTokenVaultAddress() internal view override returns (address) {
        return _privateNtv;
    }

    /// @notice Private interop does not participate in Token Balance Migration,
    /// so skip the migration number check entirely.
    function _checkAssetMigrationNumber(bytes32 /* _assetId */) internal view override {
        // No-op: private interop has its own asset tracking lifecycle.
    }

    /// @notice Override to use the private NTV instead of the hardcoded system NTV.
    /// The base L2AssetTracker uses L2_NATIVE_TOKEN_VAULT directly, which doesn't
    /// know about tokens bridged through the private interop stack.
    function _tryGetTokenAddress(bytes32 _assetId) internal view override returns (address tokenAddress) {
        tokenAddress = _nativeTokenVault().tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));
    }
}
