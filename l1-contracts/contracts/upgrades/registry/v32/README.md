# v32 upgrade registries — GENERATED FILES, DO NOT EDIT

`CoreRegistryV32.sol` and `ZKsyncOSCTMRegistryV32.sol` are **generator output**: every value in
them is a compile-time constant emitted by `scripts/gen-registry.ts` from the audited manifest
`scripts/registry-manifests/v32-local.json`. No human writes a constant here — auditors verify
these files by re-running the generator on the manifest and diffing the source.

## What environment do these addresses belong to?

The **local anvil chain-states environment**
(`test/anvil-interop/chain-states/v0.32.0`): the deterministic ecosystem the anvil-interop
harness boots for the registry-driven upgrade test. The "old" addresses are the live contracts
inside the committed chain-state dumps; the "new" implementation addresses are
nonce-deterministic — the test deployer key and its starting nonce are fixed by the committed
states and the deploy order is fixed in
`test/anvil-interop/src/helpers/registry-upgrade-test-runner.ts`. Pinned codehashes come from
the `registry-deterministic` foundry profile (CBOR-metadata-free, byte-identical across
platforms).

These registries are consumed (never regenerated) by the anvil registry-driven upgrade test
(`test/anvil-interop/run-registry-driven-upgrade-test.ts`), which deploys them and asserts
`verifyAll()` against the live deployment. If that check fails, the files here are stale.

## Regenerating

```bash
cd l1-contracts/test/anvil-interop
yarn regen:v32-registries   # = REGEN_REGISTRIES=1 ts-node run-registry-driven-upgrade-test.ts
```

This rewrites the manifest + both `.sol` files in place (prettier-formatted, byte-stable under
repeated regeneration) and then runs the full upgrade test against the regenerated registries.
Review the diff and commit it together with `scripts/registry-manifests/v32-local.json`.

## Other environments

Per-environment production registries (stage / testnet / mainnet) are generated the exact same
way — `ts-node scripts/gen-registry.ts <manifest.json> <output-dir>` — from their respective
upgrade-env manifests once those exist, and get committed alongside this directory.
