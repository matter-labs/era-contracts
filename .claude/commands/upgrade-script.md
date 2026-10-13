Start a new protocol release and, only if it needs one, its release-specific upgrade preparation.

## Usage

Invoke with: `/upgrade-script <release-name>` (e.g., `/upgrade-script chain-config`)

## What this skill does

Every release is prepared by its own `CoreUpgrade_v{N}` + `CTMUpgrade_v{N}`
(`l1-contracts/deploy-scripts/upgrade/v{N}/`), which `yarn new-release` generates as plain subclasses of
`DefaultCoreUpgrade` / `DefaultCTMUpgrade`: the **default upgrade** unless the release adds release-specific work.
`protocol-ops ecosystem upgrade-prepare-all` runs them by default, targets the protocol version in
`configs/genesis/zksync-os/latest.json`, and reads its local input from the current release's upgrade-env dir
(`current_upgrade_env_dir!` in `protocol-ops/src/common/forge/scripts/mod.rs`). The upgrade tests run exactly
these defaults, so they always cover the release being built.

There is no per-version chain script: every chain crosses through
`AdminFunctions.upgradeChainFromCTM`, which picks the modern cut-reading call or the legacy
handed-cut call from the chain's own protocol version. `DefaultChainUpgrade` remains only as
the Foundry integration harness for the legacy edge.

## Steps

1. On the new release's branch, merge the outgoing release's branch in first (the script refuses otherwise).
   From the repo root run `yarn new-release <release-name> --previous-release-ref <outgoing release branch>
--dry-run`, show the user the planned changes, then run it without `--dry-run`. What it changes and the
   follow-ups it cannot do are listed in the header of `scripts/new-release.ts` and printed at the end of a run;
   do those follow-ups.

2. Ask the user what the release changes. Only if it needs release-specific preparation (extra contracts, a
   custom per-chain initializer, one-off governance calls), override only what the release needs in the
   generated `CoreUpgrade_v{N}` / `CTMUpgrade_v{N}`; protocol-ops and the upgrade tests already run them.
   Use the most recent steady-state version as the template — `v35`, not `v34`:
   - `l1-contracts/deploy-scripts/upgrade/v35/CoreUpgrade_v35.s.sol`
   - `l1-contracts/deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol`

   `v34` is the one-shot registry bootstrap edge and carries a large amount of machinery
   (`RegistryBootstrapMigration`, the authored L2 plan, the declared bootstrap actions) that a
   normal version must NOT copy.

3. Declare the release scope. `changedReleaseMembers()` lists the release members this version
   replaces; anything not listed is reused from the live release, and a member that changes without
   being declared makes the prepare fail. Override it whenever the version changes chain code.

4. Run `cd protocol-ops && cargo test`, the anvil upgrade tests (`yarn test:upgrade-v33-to-v34` and
   `yarn test:upgrade-v34-to-v35` in `l1-contracts/test/anvil-interop`) and the foundry upgrade tests
   (`forge test --ffi --match-path 'test/foundry/l1/integration/UpgradeTest*'` in `l1-contracts`).

## Key rules

- NEVER use try-catch or staticcall in upgrade scripts
- Prefer the default upgrade; the release's scripts override the `Default*` ones only where it needs to
- Three-stage governance: stage0 (pause), stage1 (upgrade), stage2 (unpause)
- Never pin the upgrade tests to a release by hand: they follow protocol-ops' defaults (moved by
  `yarn new-release`) and the genesis version
- Test with `forge script` in simulation mode before broadcasting
