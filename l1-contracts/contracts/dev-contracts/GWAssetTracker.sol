// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty (revert-on-any-call) stub for the removed GWAssetTracker, kept only so a
/// `GWAssetTracker` artifact remains producible.
/// @dev Do NOT delete while its consumer remains: the zksync-era rev pinned by
/// `system-contracts/bootloader/test_infra` reads `zkout/GWAssetTracker.sol/GWAssetTracker.json`.
/// The genesis generator no longer deploys this stub — the reserved
/// `BUILT_IN_CONTRACTS_OFFSET + 0x10` address holds an `EmptyContract`-backed system proxy on
/// every v32 chain (installed by genesis and the upgrade alike).
contract GWAssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
