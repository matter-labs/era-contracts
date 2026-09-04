# Documentation

- The protocol itself — flows, motivations, security arguments — is documented once in
  [`protocol-docs/`](../protocol-docs/README.md); code comments reference those pages instead of restating them.
- This folder holds design documents for the repository's own machinery:
  - [registry-driven-upgrades.md](./registry-driven-upgrades.md) — the upgrade model: write-once release / transition
    objects, bound executors, the bootstrap edge, verification.
  - [governance-self-migration.md](./governance-self-migration.md) — how the governance layer upgrades itself.
  - [ai-review/](./ai-review) — review guides for the generated upgrade calldata and CI.
- Wider system specs live in the
  [zksync-era repository](https://github.com/matter-labs/zksync-era/blob/main/docs/src/specs/contracts).
