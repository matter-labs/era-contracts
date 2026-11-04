// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title EmptyContract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The implementation installed behind the removed v31 GWAssetTracker's system proxy
/// (`L2_REMOVED_GW_ASSET_TRACKER_ADDR`) — by the v32 upgrade on pre-existing ZKsync OS chains (so no
/// retired tracker code stays callable) and by genesis on chains created on v32, keeping both
/// ancestries identical at that address.
contract EmptyContract {
    // solhint-disable-previous-line no-empty-blocks
}
