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

## Steps

1. On the new release's branch, merge the outgoing release's branch in first (the script refuses otherwise).
   From the repo root run `yarn new-release <release-name> --previous-release-ref <outgoing release branch>
--dry-run`, show the user the planned changes, then run it without `--dry-run`. What it changes and the
   follow-ups it cannot do are listed in the header of `scripts/new-release.ts` and printed at the end of a run;
   do those follow-ups.

2. Ask the user what the release changes. Only if it needs release-specific preparation (extra contracts, a
   custom per-chain initializer, one-off governance calls), override only what the release needs in the
   generated `CoreUpgrade_v{N}` / `CTMUpgrade_v{N}`; protocol-ops and the upgrade tests already run them.

3. Run `cd protocol-ops && cargo test`, the anvil upgrade test (`yarn ts-node run-upgrade-test.ts` in
   `l1-contracts/test/anvil-interop`) and the foundry upgrade tests
   (`forge test --ffi --match-path 'test/foundry/l1/integration/UpgradeTest*'` in `l1-contracts`).

## Key rules

- NEVER use try-catch or staticcall in upgrade scripts
- Prefer the default upgrade; the release's scripts override the `Default*` ones only where it needs to
- Three-stage governance: stage0 (pause), stage1 (upgrade), stage2 (unpause)
- Never pin the upgrade tests to a release by hand: they follow protocol-ops' defaults (moved by
  `yarn new-release`) and the genesis version
- Test with `forge script` in simulation mode before broadcasting
