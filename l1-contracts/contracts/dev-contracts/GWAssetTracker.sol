// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty (revert-on-any-call) stub for the removed GWAssetTracker, kept only so a
/// `GWAssetTracker` artifact remains producible.
/// @dev Do NOT delete while either consumer remains: the zksync-era rev pinned by
/// `system-contracts/bootloader/test_infra` (reads `zkout/GWAssetTracker.sol/GWAssetTracker.json`),
/// and `tools/zksync-os-genesis-gen` (deploys it at the reserved slot `BUILT_IN_CONTRACTS_OFFSET + 0x10`).
contract GWAssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
