# Chain management

Chain management is split between the ecosystem-wide L1 Bridgehub, one or more chain type managers
(CTMs), and each chain's diamond:

- **Bridgehub** registers chains and CTMs, records each chain's base-token asset ID and settlement
  layer, routes L1 -> L2 requests, and coordinates the canonical asset and message-root contracts.
- **ChainTypeManager** defines a compatible chain type. It stores chain-creation parameters, deploys
  chain diamonds, publishes protocol versions and their verifier/upgrade data, and enforces upgrade
  deadlines.
- **Chain diamond** is the per-chain L1 settlement contract. Its admin, executor, mailbox, and getter
  facets share storage. The chain admin controls the limited per-chain settings exposed by `AdminFacet`;
  CTM governance controls protocol-level changes.
- **ValidatorTimelock** holds per-chain operator roles and delays batch execution. Its per-chain
  default role administrator is the chain admin reported by that chain's diamond.

The current release creates supported chains on L1. See {protocol-docs/chain-lifecycle.md} for the
complete creation, genesis, interop-registration, and upgrade-onboarding flow.

## Detailed pages

- [Bridgehub](./bridgehub.md)
- [Chain type manager](./chain_type_manager.md)
- [Chain admin](./admin_role.md)
- [Chain genesis](./chain_genesis.md)
- [Upgrade process](./upgrade_process.md)
- [Creating an upgrade](./creating_upgrades.md)
- [Stage 1 considerations](./stage1.md)
