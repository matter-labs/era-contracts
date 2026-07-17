// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty stub for the removed L2AssetTracker. The real contract was deleted after the
/// withdrawal unification: its write-only bookkeeping now lives in the L2NativeTokenVault (ERC20
/// tokens) and the BaseTokenHolder (base token). Two consumers still need a producible
/// `L2AssetTracker` artifact, so this empty (revert-on-any-call) contract stands in for both:
///
///   1. Bootloader tests: the zksync-era revision pinned by `system-contracts/bootloader/test_infra`
///      still lists `L2AssetTracker` in its hardcoded system-contract set and reads
///      `l1-contracts/zkout/L2AssetTracker.sol/L2AssetTracker.json` when assembling the test state.
///   2. ZKsync OS genesis: `tools/zksync-os-genesis-gen` deploys this stub at the reserved address
///      `BUILT_IN_CONTRACTS_OFFSET + 0x0f` (see its `INITIAL_CONTRACTS`) so new chains keep that slot
///      occupied, matching upgraded chains that retain their old L2AssetTracker bytecode there. On
///      upgraded chains the retained tracker also holds the bookkeeping recorded before the removal
///      (historic data); this stub holds none, so its storage must not be relied upon.
///
/// @dev Do NOT delete until BOTH consumers are gone: the bootloader test_infra no longer pins an
/// Era-server zksync-era revision listing L2AssetTracker (Era-server integration is being dropped in
/// favour of ZKsync OS from v32 on) AND genesis-gen no longer references it. Then bump the test_infra
/// rev per AGENTS.md.
contract L2AssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
