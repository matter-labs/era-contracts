// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Empty stub for the removed L2AssetTracker. The real contract was deleted after the
/// withdrawal unification: its write-only bookkeeping now lives in the L2NativeTokenVault (ERC20
/// tokens) and the BaseTokenHolder (base token). See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
///
/// The stub is retained only so a `L2AssetTracker` artifact stays producible while downstream consumers
/// transition away from the retired contract; nothing in this repository deploys or calls it. The
/// bootloader `test_infra` consumer that pinned a zksync-era revision listing `L2AssetTracker` was
/// removed together with the Era-server test harness, and `AllContractsHashes.json` drops its entry on
/// the next regeneration because `l1-contracts/contracts/dev-contracts` is excluded from the manifest.
///
/// ZKsync OS genesis intentionally does not deploy this stub. The former address remains an
/// unoccupied, reserved gap; the generator no longer needs a tracker artifact.
///
/// @dev Safe to delete once no external consumer reads
/// `l1-contracts/{out,zkout}/L2AssetTracker.sol/L2AssetTracker.json` any more.
contract L2AssetTracker {
    // solhint-disable-previous-line no-empty-blocks
}
