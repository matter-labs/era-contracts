// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Build-artifact stub. The GWAssetTracker contract was removed together with the
/// on-chain asset-tracking enforcement, but the zksync-era revision pinned by
/// `system-contracts/bootloader/test_infra` still lists `GWAssetTracker` in its hardcoded
/// system-contract set and reads `l1-contracts/zkout/GWAssetTracker.sol/GWAssetTracker.json`
/// when assembling the bootloader test state. This empty stub keeps that artifact producible.
/// @dev Delete this file (and bump the test_infra zksync-era rev per AGENTS.md) once the
/// era-side system-contract list no longer includes GWAssetTracker.
contract GWAssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
