// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title EmptyContract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The implementation the v32 upgrade installs behind the removed v31 trackers' system
/// proxies (`L2_REMOVED_ASSET_TRACKER_ADDR` / `L2_REMOVED_GW_ASSET_TRACKER_ADDR`), so no retired
/// tracker code stays callable on upgraded ZKsync OS chains. Chains created on v32 deploy nothing
/// at those addresses.
contract EmptyContract {
    // solhint-disable-previous-line no-empty-blocks
}
