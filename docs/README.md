# Documentation

- The protocol itself — flows, motivations, security arguments — is documented once in
  [`protocol-docs/`](../protocol-docs/README.md); code comments reference those pages instead of restating them.
  The upgrade coordinator's execution semantics are one of those pages:
  [ecosystem-upgrade-coordination.md](../protocol-docs/ecosystem-upgrade-coordination.md).
- This folder holds design documents for the repository's own machinery:
  - [registry-driven-upgrades.md](./registry-driven-upgrades.md) — the canonical upgrade architecture: write-once
    release / transition / registry / operation objects, the coordinator and domain executors, provenance and
    validation, the bootstrap edge.
  - [upgrade-operations.md](./upgrade-operations.md) — operational policies around upgrade execution: the
    ServerNotifier handover, coordinator succession, monitoring, recovery, the incident-only migration pauses.
  - [upgrade-script-retirement.md](./upgrade-script-retirement.md) — the temporary plan for moving what the prepare
    scripts still decide on-chain.
  - [governance-self-migration.md](./governance-self-migration.md) — how the governance layer upgrades itself.
  - [ai-review/](./ai-review) — review guides for the generated upgrade calldata, protocol-ops and CI.
- The runbook for preparing, verifying and executing an upgrade is
  [`l1-contracts/deploy-scripts/upgrade/README.md`](../l1-contracts/deploy-scripts/upgrade/README.md).
- Historical ZKsync Era contract documentation is maintained in the
  [zksync-era repository](https://github.com/matter-labs/zksync-era/blob/main/docs/src/specs/contracts).
