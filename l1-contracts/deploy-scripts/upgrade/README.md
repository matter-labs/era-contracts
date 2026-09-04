# Upgrade Scripts

The upgrade model (releases, transitions, executors, the v34 bootstrap edge) is described in
`docs/registry-driven-upgrades.md`; this directory holds the prepare scripts that drive it.

## Layout

- `default-upgrade/` — the version-independent prepare pipeline: `DefaultCoreUpgrade`
  (ecosystem side), `DefaultCTMUpgrade` (per-CTM side), `DefaultGatewayUpgrade`,
  `DefaultChainUpgrade` (per-chain leg), plus their composition libraries. A version script
  inherits these and overrides only what its release changes.
- `v34/` — the current release's scripts: `CoreUpgrade_v34` and `CTMUpgrade_v34` (the bootstrap
  edge: deploys the `CTMUpgradeExecutor` + `RegistryBootstrapMigration` and collapses the
  stage-1 CTM leg to four governance calls).
- `SystemContractsProcessing.s.sol` — builds the L2 force-deployment set shared by genesis and
  upgrades.

One-off scripts of shipped upgrades (the v31 stage emergency tooling, PUH governance one-offs)
live on their release branches, not here.

## Running a prepare

Production and CI prepares run through protocol-ops, which drives the version scripts'
`noGovernancePrepare` on a fork, emits deployer Safe bundles + the three governance stages, and
writes the merged `ecosystem.toml`:

```sh
cargo run -p protocol_ops -- ecosystem upgrade-prepare-all --env <env> --l1-rpc-url <rpc>
```

Per-environment inputs live in `upgrade-envs/<version>/<env>.toml` (see
`upgrade-envs/v0.34.0-registry/`), permanent values in `upgrade-envs/permanent-values/`.

## Testing an upgrade end to end

- `test/foundry/l1/integration/UpgradeTestv34_Local.t.sol` — the bootstrap edge through the real
  prepare pipeline, in-forge.
- `test/anvil-interop/run-v33-to-v34-upgrade-test.ts` — the same edge driven end to end by
  protocol-ops against the frozen departing-version chain states.
- `test/anvil-interop/run-v34-to-v35-upgrade-test.ts` — the registry-driven hop through the
  bound executors.

## Preparing the scripts for a new upgrade

Start from `v34/` as the template: inherit the `Default*Upgrade` bases, override
`deployNew*Contracts` with the contracts the release changes, and keep everything else derived.
From v35 on the edge is a `CTMTransition` — see the Transition sections of
`docs/registry-driven-upgrades.md`.
