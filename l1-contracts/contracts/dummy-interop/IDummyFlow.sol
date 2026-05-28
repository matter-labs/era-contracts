// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Per-`(flowId, specHash)` lifecycle state on each L2 escrow. Both source and
/// destination sides of a leg share this enum; transitions differ per role.
///
///   Source: `Unset -> Committed -> Executable -> Executed` (happy),
///           `Unset -> Committed -> Revertable -> Reverted` (timeout).
///   Destination: `Unset -> Executable -> Executed`.
///
/// States are mutually exclusive. The same `(flowId, specHash)` has independent state per
/// chain — i.e. a single chain can simultaneously be the source of one spec and the
/// destination of another within the same flow.
enum SpecState {
    Unset,
    Committed,
    Executable,
    Executed,
    Revertable,
    Reverted
}

/// @notice Declarative description of one cross-chain asset transfer. Identical instance
/// known to source and destination; hashed once at commit time and re-hashed at execute
/// time to gate L1-authorized settlement.
///
/// `assetId` is derived externally as
/// `keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken))`
/// (the canonical NTV assetId formula); not stored in the struct to keep it minimal.
///
/// `depositor` carries the source-side payer's address so the escrow does not need a
/// separate depositor mapping — the per-`(flowId, specHash)` state on chain is just
/// `SpecState`.
struct SendSpec {
    uint256 destChainId;
    address recipient;
    uint256 originChainId;
    address originToken;
    uint256 amount;
    bytes erc20Data;
    address depositor;
}

/// @dev Tag prepended to every L2→L1 commit log so the linker can recognize them. Versioned
/// so future commit-log schema changes can coexist without selector collisions. The log
/// payload after this tag is `abi.encode(flowId, destChainId, specHash)`; the escrow's
/// address is pinned by the L2 messenger as `L2Message.sender` (not encoded in payload).
bytes4 constant COMMIT_LOG_TAG = bytes4(keccak256("DummyFlow.commit.v2"));
