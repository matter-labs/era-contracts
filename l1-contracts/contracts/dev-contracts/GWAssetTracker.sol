// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty stub for the removed GWAssetTracker. The real contract was deleted together with
/// the on-chain asset-tracking enforcement, but two consumers still need a producible
/// `GWAssetTracker` artifact, so this empty (revert-on-any-call) contract stands in for both:
///
///   1. Bootloader tests: the zksync-era revision pinned by `system-contracts/bootloader/test_infra`
///      still lists `GWAssetTracker` in its hardcoded system-contract set and reads
///      `l1-contracts/zkout/GWAssetTracker.sol/GWAssetTracker.json` when assembling the test state.
///   2. ZKsync OS genesis: `tools/zksync-os-genesis-gen` deploys this stub at the reserved address
///      `BUILT_IN_CONTRACTS_OFFSET + 0x10` (see its `INITIAL_CONTRACTS`) so new chains keep that slot
///      occupied, matching upgraded chains that retain their old GWAssetTracker bytecode there. The
///      address is reserved and its storage must not be relied upon — this stub holds none.
///
/// @dev Do NOT delete until BOTH consumers are gone: the bootloader test_infra no longer pins an
/// Era-server zksync-era revision listing GWAssetTracker (Era-server integration is being dropped in
/// favour of ZKsync OS from v32 on) AND genesis-gen no longer references it. Then bump the test_infra
/// rev per AGENTS.md.
contract GWAssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
