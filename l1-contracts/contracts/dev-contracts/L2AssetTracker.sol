// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty stub for the removed L2AssetTracker. The real contract was deleted after the
/// withdrawal unification: its write-only bookkeeping now lives in the L2NativeTokenVault (ERC20
/// tokens) and the BaseTokenHolder (base token). Two consumers still need a producible
/// `L2AssetTracker` artifact, so this empty (revert-on-any-call) contract is retained for:
///
/// 1. Bootloader tests: the zksync-era revision pinned by `system-contracts/bootloader/test_infra`
/// still lists `L2AssetTracker` in its hardcoded system-contract set and reads
/// `l1-contracts/zkout/L2AssetTracker.sol/L2AssetTracker.json` when assembling the test state.
///
/// 2. Repository hash tooling: `AllContractsHashes.json` still names the artifact while downstream
/// consumers transition away from the retired contract.
///
/// ZKsync OS genesis intentionally does not deploy this stub. The former address remains an
/// unoccupied, reserved gap; the generator no longer needs a tracker artifact.
///
/// @dev Do NOT delete until BOTH consumers are gone: remove the hash-manifest entry, and wait until
/// bootloader test_infra no longer pins an Era-server zksync-era revision listing L2AssetTracker
/// (Era-server integration is being dropped in favour of ZKsync OS from v32 on). Then bump the
/// test_infra rev per AGENTS.md.
contract L2AssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
