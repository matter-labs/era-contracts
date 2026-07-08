// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Build-artifact stub. The GWAssetTracker contract was removed together with the
/// on-chain asset-tracking enforcement, but the zksync-era revision pinned by
/// `system-contracts/bootloader/test_infra` still lists `GWAssetTracker` in its hardcoded
/// system-contract set and reads `l1-contracts/zkout/GWAssetTracker.sol/GWAssetTracker.json`
/// when assembling the bootloader test state. This empty stub keeps that artifact producible.
/// @dev Delete this file once the bootloader test_infra no longer pins an Era-server
/// zksync-era revision that lists GWAssetTracker (Era-server integration is being dropped in
/// favour of ZKsync OS from v32 on), or once that list drops the entry — then bump the
/// test_infra rev per AGENTS.md.
contract GWAssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
