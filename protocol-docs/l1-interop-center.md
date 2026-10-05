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

`sendMessage` accepts these attributes in one list. `sendBundle` separates call and
bundle attributes and requires exactly one call because the transport delivers one
priority transaction. Duplicate, unknown, misplaced and truncated attributes revert.
There is no factory-dependencies attribute: priority transactions cannot carry them
(see {protocol-docs/bridging.md#priority-transaction-factory-dependencies}). L1-only
attributes are unsupported by the L2 parser, and L2-only attributes are unsupported on L1.

Direct sends fund the base token and submit the destination call; as on L2, they need a
non-zero recipient. For indirect sends,
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
zero owner. Pausing the Bridgehub no longer stops priority requests: pause the center
(or the L1 asset router) to halt sends.

`L1Bridgehub` stores `interopCenter` after the shared Bridgehub storage, so the L2
Bridgehub is unchanged. Mailbox and the L1 senders resolve authorization through this
registry. The extra lookup avoids duplicating configuration in every chain's diamond
storage. Existing live storage fields retain their positions.

PermanentRestriction recognizes chain migrations through indirect `sendMessage`
and one-call `sendBundle`, validates the registered chain asset handler and enforces
the migration-admin restriction. A direct message to the asset router is not a
migration. The restriction consults the registry only for interop sends, so it can be
upgraded before or after the Bridgehub; existing chain-admin restrictions must use this
implementation before chain migrations are re-enabled.

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

Core upgrade inputs must explicitly set `has_l1_interop_center`: use `true` when the
core already has a center, even if its chains have not upgraded yet, and `false` for
historical Bridgehubs without the getter. Discovery retains an existing proxy, and stage
1 upgrades its implementation; `false` on an ecosystem that already has a center would
deploy and register a replacement. The CTM upgrade does not use the center and never
reads the getter.

Deployment and upgrade output records
`bridgehub.l1_interop_center_{implementation,proxy}_addr`; upgrade output also records
`bridgehub.l1_interop_center_new_proxy` to identify an upgrade that introduces the
center. Rust request decoding and the governance simulator recognize `sendMessage`.

`ecosystem verify-upgrade` only verifies ceremonies prepared before the center. Every
upgrade prepared from this release on records the center outputs, and the verifier
rejects such an artifact before loading gateway configuration or contacting RPCs;
`--display-upgrade-data` can still print its calldata without validating it. Verifying
the center's deployment and stage-1 calls needs verifier support that does not exist yet.

This migration intentionally breaks the old Bridgehub request and cross-chain sender
APIs. Integrators must discover `interopCenter()` and encode the attributes above;
there are no forwarding shims. L1 senders implement `initiateIndirectCall` and
`confirmL2Transaction`. The nullifier confirmation ABI, failed-transfer recovery data
and `BridgehubDepositFinalized` gateway confirmation event remain unchanged.
`INDIRECT_CALL_MAGIC_VALUE` retains the numeric value
`bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1)`.

L2-to-L1 execution, replacement of priority-queue transport, fee-model changes and
same-base-token funding changes are outside this migration.
