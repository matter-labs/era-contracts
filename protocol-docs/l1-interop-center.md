# L1 Interop Center

## Sending requests

L1InteropCenter replaces Bridgehub's public priority-request entry points with
`sendMessage` and an exactly-one-call `sendBundle`. Recipients use ERC-7930 EVM
addresses. Both paths submit a Mailbox priority transaction and return its canonical
hash; fee calculation, refund aliasing and failed-deposit recovery retain their
existing behavior.

The center uses the ERC-7786 send interface, with a priority-transport extension:
`l1ToL2TransactionParams` is required. It does not implement the standard's
empty-attribute send behavior. Callers must choose and fund the destination gas
budget; the interface does not infer these parameters.

| Attribute                                                                                   | Purpose                                                                   | Bundle placement |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------- |
| `l1ToL2TransactionParams(mintValue, l2GasLimit, l2GasPerPubdataByteLimit, refundRecipient)` | Required priority-transaction funding and gas parameters                  | Bundle           |
| `interopCallValue(uint256)`                                                                 | Value delivered on the destination chain                                  | Call             |
| `indirectCall(uint256)`                                                                     | Select a source-side cross-chain sender and the ETH value forwarded to it | Call             |
| `factoryDeps(bytes[])`                                                                      | Bytecode dependencies for a direct call                                   | Bundle           |

`sendMessage` accepts these attributes in one list. `sendBundle` separates call and
bundle attributes and requires exactly one call because the transport delivers one
priority transaction. Duplicate, unknown, misplaced and truncated attributes revert.
Factory dependencies are rejected on indirect sends, even when the array is empty;
the cross-chain sender supplies the dependencies in that case. L1-only attributes
are unsupported by the L2 parser, and L2-only attributes are unsupported on L1.

Direct sends fund the base token and submit the destination call. For indirect sends,
the recipient identifies an L1 cross-chain sender. The center funds the base token,
calls `initiateIndirectCall` to construct the destination call, submits it to the
Mailbox, then calls `confirmL2Transaction` with the canonical hash. The priority
transaction's sender remains the cross-chain sender, including the asset-router
identity used by Prividium. `MessageSent` records the initiating caller and the resolved destination recipient.

ETH funding must be exact:

| Destination base token | Direct send | Indirect send                    |
| ---------------------- | ----------- | -------------------------------- |
| ETH                    | `mintValue` | `mintValue + indirectCall` value |
| ERC20                  | Zero        | `indirectCall` value             |

ERC20 base-token approvals target the NativeTokenVault discovered through the asset
router, which pulls the funding. Governance and chain-admin helpers use the same
caller for approval and message submission.

## Authorization and storage

The L1 center is a transparent upgradeable proxy owned by ecosystem governance.
Sends are permissionless, pausable by the owner and protected against reentry.
The implementation is locked against initialization and initialization rejects a
zero owner.

Bridgehub stores `interopCenter` in the first slot of its reserved gap. Mailbox and
the L1 senders resolve authorization through this registry. The extra lookup avoids
duplicating configuration in every chain's diamond storage. Existing live storage
fields retain their positions.

PermanentRestriction recognizes chain migrations through indirect `sendMessage`
and one-call `sendBundle`, validates the registered chain asset handler and enforces
the migration-admin restriction. A direct message to the asset router is not a
migration. Existing chain-admin restrictions must use this implementation before
chain migrations are re-enabled.

The L2 built-in is renamed to `interop-center/L2InteropCenter`. Its storage-bearing
inheritance and executable runtime are unchanged. L1 and L2 share the send interface;
the L1 implementation keeps its own wrappers and parsing.

## Deployment and migration

Fresh ecosystems deploy and initialize the center, transfer its ownership to
governance, and register it through `Bridgehub.setInteropCenter`. Governance's
ownership-acceptance step completes the pending transfer.

The core upgrade deploys the proxy when absent. Stage 1 upgrades Bridgehub, accepts
the center's ownership and sets the registry before stage 2 submits priority
requests. If Bridgehub is paused when the center is first registered, registration
requires the center to be paused too. Pause the new center before stage 1 in this case;
its owner must explicitly unpause it to resume sends. This check runs at activation,
so a pause imposed after preparation cannot silently be lost.
The per-chain upgrade installs the new Mailbox facet. Sends to an existing chain
are unavailable between the ecosystem upgrade and that chain's Mailbox upgrade.
The current upgrade CLI supports ZKsync OS chains; retained Era chains require a
separately supported Mailbox migration.
A center-introducing upgrade cannot combine `[new_gateway]` preparation: complete
the ecosystem and gateway-chain upgrades, then run
`protocol-ops chain gateway convert` separately.

Core and CTM upgrade inputs must explicitly set `has_l1_interop_center`: use `true` when
the core already has a center, even if its chains have not upgraded yet, and `false`
for historical Bridgehubs without the getter. Discovery retains an existing proxy,
and stage 1 upgrades its implementation.

Deployment and upgrade output records
`bridgehub.l1_interop_center_{implementation,proxy}_addr`; upgrade output also records
`bridgehub.l1_interop_center_new_proxy` to identify an upgrade that introduces the
center. Rust request decoding and simulation recognize the current send format.

The full `ecosystem verify-upgrade` CLI remains scoped to the historical combined
v31 gateway ceremony. It rejects center-bearing artifacts before loading gateway
configuration or contacting RPCs; `--display-upgrade-data` can still print their
calldata without validating it. End-to-end verification of the center migration
requires a separately supported ceremony and is not provided by that legacy CLI.

This migration intentionally breaks the old Bridgehub request and cross-chain sender
APIs. Integrators must discover `interopCenter()` and encode the attributes above;
there are no forwarding shims. L1 senders implement `initiateIndirectCall` and
`confirmL2Transaction`. The nullifier confirmation ABI, failed-transfer recovery data
and `BridgehubDepositFinalized` gateway confirmation event remain unchanged.
`INDIRECT_CALL_MAGIC_VALUE` retains the numeric value
`bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1)`.

L2-to-L1 execution, replacement of priority-queue transport, fee-model changes and
same-base-token funding changes are outside this migration.
