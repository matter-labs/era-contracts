# Settlement-layer and Gateway machinery

> **Release status:** production chain migrations are disabled by
> `CHAIN_MIGRATIONS_ENABLED = false` in `l1-contracts/contracts/common/Config.sol`. Supported chains
> settle on L1. The contracts and interfaces described in this section remain in the repository so
> the settlement-layer architecture can be tested and evolved, but these pages are not instructions
> for an active production migration.

The settlement-layer abstraction allows a ZK chain to settle through another ZK chain instead of
directly on L1. Gateway is the historical proof-aggregation design built on that abstraction. Enabling
it changes the routing of priority operations, batch-root propagation, asset custody, DA verification,
and the chain's trust boundary, so migration is modeled as an asset-router operation with explicit
source and destination settlement layers.

The current implementation retains:

- chain burn/mint handlers and migration records;
- Bridgehub settlement-layer routing and Gateway mailbox relay entry points;
- nested chain-batch-root proof formats;
- settlement-layer DA validators and version-coordination hooks;
- recovery logic for a migration that had already started.

The release-level constant prevents starting or completing a new chain migration through
`bridgeBurn`/`bridgeMint`. Recovery is deliberately still callable because returning an in-flight
chain to L1 must not be disabled.

## Documents

- [Chain migration design](./chain_migration.md)
- [L1 -> settlement layer -> L2 messaging](./messaging_via_gateway.md)
- [Nested L2 -> settlement layer -> L1 proofs](./l2_gw_l1_messaging.md)
- [Protocol-version coordination](./gateway_protocol_upgrades.md)
- [Data availability on a settlement layer](./gateway_da.md)
- [Additional trust assumptions](./trust_assumptions.md)

For normative current behavior and the exact migration gates, see
{protocol-docs/chain-lifecycle.md#settlement-layer-migration-chainassethandler}.
