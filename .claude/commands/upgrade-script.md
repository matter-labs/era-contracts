Start a new protocol release and, only if it needs one, its release-specific upgrade scripts.

## Usage

Invoke with: `/upgrade-script <release-name>` (e.g., `/upgrade-script chain-config`)

## What this skill does

Every release is prepared by the **default upgrade** unless it needs release-specific work:
`protocol-ops ecosystem upgrade-prepare-all` runs `DefaultCoreUpgrade` + `DefaultCTMUpgrade`
(`l1-contracts/deploy-scripts/upgrade/default-upgrade/`), targets the protocol version in
`configs/genesis/zksync-os/latest.json`, and reads its local input from the current release's upgrade-env dir
(`current_upgrade_env_dir!` in `protocol-ops/src/common/forge/scripts/mod.rs`). The upgrade tests run exactly
these defaults, so they always cover the release being built.

## Steps

1. From the repo root, run `yarn new-release <release-name> --dry-run`, show the user the planned changes, then
   run it without `--dry-run`. It bumps the genesis minor version, scaffolds
   `l1-contracts/upgrade-envs/v0.<N>.0-<release-name>/local.toml`, repoints protocol-ops' current upgrade-env dir,
   and rotates the anvil fixtures (`config/anvil-config.json`).

2. Do the follow-ups it prints: regenerate the new release's anvil chain states (the 'Regenerate Anvil Interop
   Chain States' workflow) and add per-environment inputs (`stage.toml`, `mainnet.toml`, ...) when preparing for
   those environments.

3. Ask the user what the release changes. Only if it needs release-specific preparation (extra contracts, a
   custom per-chain initializer, one-off governance calls):
   - Read the base classes: `DefaultCoreUpgrade.s.sol`, `DefaultCTMUpgrade.s.sol`, `CTMUpgradeBase.sol`.
   - Add thin subclasses of the `Default*` scripts under `l1-contracts/deploy-scripts/upgrade/v{N}/` (e.g.
     `CTMUpgrade_v{N}`), overriding only what the release needs.
   - Point protocol-ops' `upgrade-prepare-all` `--core-script-path` / `--ctm-script-path` defaults at them, so the
     upgrade tests pick them up.

4. Run `cd protocol-ops && cargo test`, the anvil upgrade test (`yarn ts-node run-upgrade-test.ts` in
   `l1-contracts/test/anvil-interop`) and the foundry upgrade tests
   (`forge test --ffi --match-path 'test/foundry/l1/integration/UpgradeTest*'` in `l1-contracts`).

## Key rules

- NEVER use try-catch or staticcall in upgrade scripts
- Prefer the default upgrade; release-specific scripts extend the `Default*` ones with minimal overrides
- Three-stage governance: stage0 (pause), stage1 (upgrade), stage2 (unpause)
- Never pin the upgrade tests to a release: they follow protocol-ops' defaults and the genesis version
- Test with `forge script` in simulation mode before broadcasting
