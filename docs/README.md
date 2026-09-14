# Documentation

- The protocol itself — flows, motivations, security arguments — is documented once in
  [`protocol-docs/`](../protocol-docs/README.md); code comments reference those pages instead of restating them.
  The upgrade coordinator's stage semantics are one of those pages:
  [ecosystem-upgrade-coordination.md](../protocol-docs/ecosystem-upgrade-coordination.md).
- This folder holds design documents for the repository's own machinery:
  - [registry-driven-upgrades.md](./registry-driven-upgrades.md) — the canonical upgrade architecture: write-once
    release / transition / registry / operation objects, the coordinator and domain executors, provenance and pinning,
    the bootstrap edge.
  - [upgrade-stage-lifecycle.md](./upgrade-stage-lifecycle.md) — operational policies of the on-chain lifecycle:
    pause composition, the ServerNotifier row, the upgrade timer, coordinator succession, recovery.
  - [upgrade-script-retirement.md](./upgrade-script-retirement.md) — the temporary plan for moving what the prepare
    scripts still decide on-chain.
  - [governance-self-migration.md](./governance-self-migration.md) — how the governance layer upgrades itself.
  - [ai-review/](./ai-review) — review guides for the generated upgrade calldata, protocol-ops and CI.
- The runbook for preparing, verifying and executing an upgrade is
  [`l1-contracts/deploy-scripts/upgrade/README.md`](../l1-contracts/deploy-scripts/upgrade/README.md).
- Wider system specs live in the
  [zksync-era repository](https://github.com/matter-labs/zksync-era/blob/main/docs/src/specs/contracts).
