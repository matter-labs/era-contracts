# Upgrade Scripts

The upgrade model (releases, transitions, executors, the v34 bootstrap edge) is described in
`docs/registry-driven-upgrades.md`; this directory holds the prepare scripts that drive it.

## Layout

- `default-upgrade/` — the version-independent, REGISTRY-DRIVEN prepare pipeline.
  `DefaultCoreUpgrade` (ecosystem side) deploys the new ecosystem implementations and pins them
  in a `CoreRegistry`; it emits no governance call. `DefaultCTMUpgrade` (per-CTM side) deploys
  the release, a `GovernanceUpgradeTimer` bound to the live `CTMUpgradeExecutor` and a
  `CTMTransition` naming the core prepare's registry, and emits exactly three governance calls:
  `CTMUpgradeExecutor.stage0/1/2(transition)`. Anything else a version needs governance (or an
  admin) to do goes through `declareExternalAction` (`ExternalActionsLib`) and is listed in the
  output's `external_actions` — protocol-ops refuses a bundle carrying a call that is neither.
  `DefaultChainUpgrade` is the per-chain leg. A version script inherits these and overrides only
  what its release changes.
- `v35/` — the first registry-driven release: `CoreUpgrade_v35` deploys one fresh
  `L1MessageRoot`; `CTMUpgrade_v35` overrides nothing. This is what a facet/verifier-level
  upgrade costs in script code.
- `v34/` — the bootstrap edge: `CoreUpgrade_v34` and `CTMUpgrade_v34` deploy the
  `EcosystemUpgradeExecutor`, `CTMUpgradeExecutor` and `RegistryBootstrapMigration`, and declare
  every call of the one-time edge (pause/unpause, timer start, the two handovers, `migrate()`,
  the post-state gates, the two join authorizations) as bootstrap external actions.
- `SystemContractsProcessing.s.sol` — builds the L2 force-deployment set shared by genesis and
  upgrades.

One-off scripts of shipped upgrades (the v31 stage emergency tooling, PUH governance one-offs)
live on their release branches, not here.

## Running a prepare

Production and CI prepares run through protocol-ops, which drives the version scripts'
`noGovernancePrepare` on a fork, emits deployer Safe bundles + the three governance stages, and
writes the merged `ecosystem.toml`. The merger copies each prepare's bundles in source order and
composes nothing; its own appends (PUH/Guardians wiring, CTM `acceptOwnership` normalization,
the new-Gateway bundle) join the scripts' declarations under `external_actions`:

```sh
cargo run -p protocol_ops -- ecosystem upgrade-prepare-all --env <env> --l1-rpc-url <rpc>
```

Per-environment inputs live in `upgrade-envs/<version>/<env>.toml` (see
`upgrade-envs/v0.34.0-registry/`), permanent values in `upgrade-envs/permanent-values/`.

## Testing an upgrade end to end

- `test/foundry/l1/integration/UpgradeTestv34_Local.t.sol` — the bootstrap edge through the real
  prepare pipeline, in-forge.
- `test/anvil-interop/run-v33-to-v34-upgrade-test.ts` — the same edge driven end to end by
  protocol-ops against the frozen departing-version chain states, followed on the same chains
  by the v35 registry-driven hop through the real `v35/` prepares: the merged artifact is
  asserted to be exactly the three executor calls.
- `test/anvil-interop/run-v34-to-v35-upgrade-test.ts` — the registry-driven hop through the
  bound executors with the objects deployed by the harness itself (the object-level test).

## Preparing the scripts for a new upgrade

Start from `v35/` as the template: inherit the `Default*Upgrade` bases, override
`deployNew*Contracts` with the contracts the release changes, and keep everything else derived.
A release whose L2 built-ins change must also author the L2 remainder
(`transitionAuthoredL2Plan`: the delegate's unsafe deployment, the pinned composer, the published
factory dependencies — the v34 bootstrap shows the shape) because the release-pair derivation
puts the changed built-ins in the L2 leg. See the Transition sections of
`docs/registry-driven-upgrades.md` and `docs/upgrade-stage-lifecycle.md` §4.7.
