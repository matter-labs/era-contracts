# v32 upgrade registries

v32 registries are **storage-backed, write-once contracts**, not generated Solidity. The
registry code is the general-purpose `CTMRelease` / `CTMTransition` (and `CoreRegistry`) in the
parent directory; a v32 registry is one of those contracts deployed and then `initialize`-d once
from an audited manifest. There is no per-version generated `.sol` file and no `gen-registry.ts`.

## Where the data lives

- **Manifest (source of truth):** `scripts/registry-manifests/v32-local.json` — the audited
  values (facets, DiamondInit, base-system hashes, force-deployments, genesis params for the
  release; version, verifier, facet transitions, L2 deployments for the transition; codehash
  pins). Auditors verify a deployed registry by re-deriving its `manifestHash` from this file.
- **On-chain shape:** a `CTMRelease` describes the version-independent post-upgrade chain state;
  a `CTMTransition` pins `fromRelease -> newRelease` and `oldProtocolVersion -> newProtocolVersion`
  plus the verifier and facet swaps. Both expose `validate()` (reverts on any codehash-pin drift,
  called on every execution path) and `verifyAll()` (returns `bool`, for off-chain tooling).

## How they are consumed

The anvil registry-driven upgrade test
(`test/anvil-interop/run-registry-driven-upgrade-test.ts`) deploys the registries from the
manifest against the deterministic local ecosystem
(`test/anvil-interop/chain-states/v0.32.0`) and drives the upgrade through the on-chain
executor/module path, asserting `validate()` succeeds against the live deployment. Pinned
codehashes come from the `registry-deterministic` foundry profile (CBOR-metadata-free, so
byte-identical across macOS and CI).

## Regenerating the manifest

```bash
cd l1-contracts/test/anvil-interop
yarn regen:v32-registries   # = REGEN_REGISTRIES=1 ts-node run-registry-driven-upgrade-test.ts
```

This re-derives `scripts/registry-manifests/v32-local.json` from a fresh deployment and re-runs
the full upgrade test against it. Review and commit the manifest diff. If the test's `validate()`
check fails on committed data, the manifest is stale — regenerate it.

## Other environments

Per-environment production registries (stage / testnet / mainnet) use the same contracts and the
same manifest shape, built from their respective upgrade-env inputs and committed as manifests —
never as generated Solidity.
