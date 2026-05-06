# Getting CI green

## Relevant files

- `.github/workflows/lint.yaml` — Solidity / TS lint, codespell, typos, `cargo fmt --check`, `cargo clippy -D warnings` for `protocol-ops`.
- `.github/workflows/l1-contracts-ci.yaml` — l1-contracts build, `check-zkstack-out`, `check-hashes`, `check-selectors`, `check-legacy-bridge-sol`.
- `.github/workflows/l1-contracts-foundry-ci.yaml` — foundry test build + contract-size check.
- `.github/workflows/anvil-interop-ci.yaml` — interop integration test, v29→v31 upgrade test, v30→v31 upgrade test.
- `.github/workflows/l2-contracts-ci.yaml`, `system-contracts-ci.yaml` — peer projects.
- `.github/workflows/update-hashes-on-demand.yaml` — manual workflow to push hash updates back into a PR.
- `recompute_hashes.sh` — one-shot rebuild + recompute + write hashes.
- `package.json`, `l1-contracts/package.json`, `system-contracts/package.json`, `l2-contracts/package.json` — top-level scripts referenced below.

## TL;DR — the order to fix things

CI checks form a dependency chain. Fix in this order:

```
1. Tests       ← foundry, anvil-interop, v29/v30→v31 upgrade. Biggest signal; bytecode-shaping bugs surface here.
2. Linting     ← solhint, eslint, prettier, errors-lint, cargo fmt, cargo clippy, codespell, typos.
3. Selectors   ← yarn l1 selectors --fix. Depends on final bytecode.
4. zkstack-out ← regenerated JSON ABIs. Depends on final compile output.
5. Hashes      ← ./recompute_hashes.sh. Depends on final bytecode hashes — the most sensitive of all.
```

**Why this order matters:** every step further down consumes outputs of an earlier one. Regenerating selectors / zkstack-out / hashes on top of code that still has bugs means doing all three again after each test fix. Linting comes after tests because a real fix often shifts code around, and re-running linters on the stable post-test code is cheaper than re-running them after every test iteration. Hashes go last because they're the most expensive to regenerate and the most fragile to subsequent change.

Doing steps 3-5 before step 1 is the most common time-sink.

## 1. Tests

This is where the bulk of regressions surface — get this green first. Three test suites in CI: **foundry** (per-project), **anvil-interop** (full L1↔L2 flow), and **v29/v30 → v31 upgrade** (real-state replay).

### Install foundry-zksync (the version CI uses)

CI installs `foundry-zksync` via `./.github/actions/install-zksync-foundry`. To match locally:

```bash
mkdir ./foundry-zksync
curl -LO https://github.com/matter-labs/foundry-zksync/releases/download/foundry-zksync-v0.0.30/foundry_zksync_v0.0.30_linux_amd64.tar.gz
tar zxf foundry_zksync_v0.0.30_linux_amd64.tar.gz -C ./foundry-zksync
chmod +x ./foundry-zksync/forge ./foundry-zksync/cast
rm foundry_zksync_v0.0.30_linux_amd64.tar.gz
export PATH="$PWD/foundry-zksync:$PATH"
```

(macOS: swap in the darwin tarball; check the install-zksync-foundry action for the exact pinned version.)

Anvil-interop tests _also_ need vanilla `foundry-toolchain` (matching `foundry-rs/foundry-toolchain@v1` `version: v1.5.1`) because they run anvil directly. If both are on `PATH`, foundry-zksync's `forge`/`cast` win, which is what CI does for the upgrade tests.

### Build artifacts (in this order)

From the repo root:

```bash
yarn da build:foundry   # da-contracts → da-contracts/out
yarn l1 build:foundry   # l1-contracts → l1-contracts/out, zkout, zkstack-out
yarn sc build:foundry   # system-contracts → system-contracts/zkout
yarn l2 build:foundry   # l2-contracts → l2-contracts/zkout
```

Order matters: l1 needs da artifacts, anvil-interop needs all four, and `l1 build:foundry` regenerates `zkstack-out` (see step 4). If `yarn l1 build:foundry` fails, **stop and fix the Solidity** — every later step will fail too.

### 1a. Foundry tests

```bash
cd l1-contracts
yarn test:foundry      # forge test --threads 1 --ffi --match-path 'test/foundry/{l1,zksync-os}/*'

cd ../system-contracts
yarn test:foundry
```

Common foundry test failures and their root causes:

- **"zkout/BeaconProxy.sol/BeaconProxy.json not found"** — you skipped `yarn l2 build:foundry` (or `sc`).
- **"Can't acquire config lock"** — transient; rerun.
- **`L2-context vs L1-context` assertion mismatches** — tests in `l2-tests-in-l1-context` run L2 logic in an L1 environment; some L2 system features don't behave identically. Fix the assertion or move the test, don't paper over it.

### 1b. Anvil-interop tests

These run the full L1↔L2 interop flow against real anvil instances on ports 9545/4050-4053. They need:

- All four foundry builds done above.
- Pre-generated chain states under `l1-contracts/test/anvil-interop/state/` (committed; only regenerate when mock system contracts change — see "Regenerating chain states" below).

```bash
cd l1-contracts
yarn test:hardhat:interop                    # ~180s, uses pre-generated states
ANVIL_INTEROP_PORT_OFFSET=100 yarn test:hardhat:interop  # avoid port collisions
ANVIL_INTEROP_FRESH_DEPLOY=1 yarn test:hardhat:interop   # ~330s, fresh deploy
ANVIL_INTEROP_KEEP_CHAINS=1 yarn test:hardhat:interop    # keep chains running for cast debugging
```

**Cleanup.** Never `pkill -f anvil` / `killall anvil` — other developers may have anvils running on different ports. Use the targeted cleanup script:

```bash
cd l1-contracts/test/anvil-interop
bash cleanup.sh
```

CI runs this in the `if: always()` cleanup step; do the same locally.

**Regenerating chain states.** Only when you've changed mock system contracts (`MockL2ToL1Messenger`, `MockMintBaseTokenHook`, etc.):

```bash
cd l1-contracts
forge build
cd test/anvil-interop
npx ts-node setup-and-dump-state.ts
```

Commit the regenerated `state/` files alongside the contract change. CI doesn't regenerate states — it expects committed states to match the current mock contracts.

### 1c. Upgrade tests (v29→v31, v30→v31)

These exercise the full v31 upgrade flow against captured v29 / v30 chain states. They use protocol-ops's `ecosystem upgrade-prepare` (the legacy monolithic flow — see `protocol-ops.md`) plus `ecosystem upgrade-governance`, then `chain upgrade` per chain.

```bash
cd l1-contracts/test/anvil-interop
npx ts-node run-v29-to-v31-upgrade-test.ts
npx ts-node run-v30-to-v31-upgrade-test.ts
```

Prerequisites: same as anvil-interop tests (all foundry builds done). Plus:

- `protocol-ops` must build (`cd protocol-ops && cargo build`). The test runner shells out to it.
- foundry-zksync on `PATH` (the test runner shells out to `forge --zksync` for L2 deploys).

Common failures:

- **"Script not found: deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol"** — `yarn l1 build:foundry` not run, or run without the test path included.
- **"call to non-contract address 0x0…"** — usually the upgrade script reading an address before the contract is deployed/registered. Use `cast run <txhash>` against the still-running anvil to get the trace; see `AGENTS.md` "Debugging Failed Transactions with cast run" for the recipe.
- **"vm.writeToml: path not allowed"** — script-out path concatenation issue. Check that `vm.projectRoot()` is concatenated once, not twice.

For deeper debugging, run with `ANVIL_INTEROP_KEEP_CHAINS=1` and inspect L1 state with `cast` after the test exits.

## 2. Linting

Run after tests are green. Lint failures are mostly cosmetic, but real fixes from step 1 often shift code around — running linting once on the post-test code is cheaper than re-running it after every test iteration.

From repo root:

```bash
yarn lint:sol --fix --noPrompt   # Solidity
yarn lint:ts --fix               # TypeScript
yarn prettier:fix                # All formats — adds trailing newlines, etc.

# Solidity error-naming convention
yarn l1 errors-lint --check
```

For `protocol-ops` (Rust):

```bash
cd protocol-ops
cargo fmt --check          # CI runs without --check; locally use --check first to see diffs
cargo clippy --all-targets -- -D warnings
```

CI also runs `codespell` and `crate-ci/typos` as separate jobs (see `.github/workflows/lint.yaml`). They are easy to forget locally because neither is wired into `yarn lint:check`. Both must pass independently.

**Important: filter out submodule paths locally.** CI's `actions/checkout@v6` runs without `submodules: true`, so it never sees the contents of `lib/`, `l1-contracts/lib/`, `system-contracts/lib/`, etc. Locally those directories are populated and produce hundreds of false-positive errors that CI doesn't see. Use `typos`'s native `--exclude` (do **not** pipe `git ls-files | xargs typos` — file paths with spaces in submodule audits will silently break the pipeline before scanning starts):

```bash
# typos — exclude submodule paths to match CI's view
typos . \
  --exclude 'lib/**' \
  --exclude 'l1-contracts/lib/**' \
  --exclude 'system-contracts/lib/**' \
  --exclude 'l2-contracts/lib/**' \
  --exclude 'da-contracts/lib/**'

# codespell — `skip` already supports comma-separated paths
codespell . \
  --skip='_typos.toml,*.json,*.lock,*.html,*.map,target,node_modules,venv,dist,report,yarn-error.log,lib,l1-contracts/lib,system-contracts/lib,l2-contracts/lib,da-contracts/lib'

# Quick "did *I* introduce a typo" check: only run on what your branch changed
git diff --name-only main -- ':!lib' ':!*/lib/*' | xargs -d'\n' typos
```

Sanity-check the filter is right: a clean run on the current branch should print **0** errors. If your numbers are in the hundreds you're seeing submodule noise — fix the filter, don't fix the code.

A real-world catch: `typos` splits hyphenated words. A prefix like the three letters "m-i-s" with a dash, then `encoded` (the kind of phrasing you get when adding a hyphenated negation to a verb), tokenizes to two words and the prefix is flagged because it matches a known short typo. Either rephrase the comment to use the verb form (e.g. "encoded incorrectly") or whitelist that prefix in `_typos.toml` under `[default.extend-words]`. Other hyphenated forms (`pre-state`, `co-located`) can fire similarly when the prefix isn't on `typos`'s known-prefix list.

Install once locally:

```bash
# typos (Rust binary) — brew is easiest on macOS
brew install typos-cli
cargo install typos-cli                        # newest, requires recent rustc
cargo install typos-cli --version 1.42.3       # last version that builds on rustc 1.87

# codespell (Python)
brew install codespell
pip install codespell
```

When a real domain word fires:

- For `typos`: add to `[default.extend-words]` in `_typos.toml` (key = lowercased typo, value = canonical replacement; use `word = "word"` to whitelist the word itself).
- For `codespell`: add to `.codespellrc` under `ignore-words-list = ...` (comma-separated).

Don't whitelist actual misspellings — fix them. cSpell warnings shown in the IDE are a separate VS Code extension and **do not run in CI**; ignore those unless `typos` or `codespell` agrees.

## 3. Selectors

`check-selectors` is fast and depends on the current bytecode. Run before zkstack-out so failures are isolated to selector drift, not the larger zkstack-out regeneration noise.

```bash
cd l1-contracts
yarn selectors --fix
git add ../selectors      # exact path varies; follow git status
```

CI runs `yarn l1 selectors --check`; locally run `--fix` first, then `--check` to confirm.

## 4. zkstack-out

CI re-runs `yarn l1 build:foundry` and fails if `zkstack-out/` differs from what's committed.

```bash
cd l1-contracts
forge build
npx ts-node scripts/copy-to-zkstack-out.ts
cd ..
yarn prettier:fix     # required: prettier adds trailing newlines to the JSON files
git add l1-contracts/zkstack-out
```

Most commonly out of date when you've added/changed:

- A function or event on an interface that protocol-ops imports (via `abigen!` in `protocol-ops/src/abi.rs`).
- A new `IFoo.sol` interface that needs to be picked up.

If you forget `yarn prettier:fix`, `check-zkstack-out` will still fail because the committed JSON has trailing newlines and your regenerated file doesn't.

## 5. Hashes (LAST)

Bytecode hashes for genesis system contracts and force-deployed contracts are committed in `system-contracts/SystemContractsHashes.json` and similar. CI regenerates and diffs. **Don't fix until everything else above is green** — every contract change invalidates these, so doing it last avoids redoing work.

> ⚠️ `recompute_hashes.sh` is **strictly version-pinned** to a specific foundry-zksync version (currently `v0.1.5`, commit `807f47ace`). The script refuses to run on any other version. If your local foundry is newer (e.g. `v0.1.9`), you cannot regenerate hashes locally without first downgrading via `foundryup-zksync -i 0.1.5`. For most contributors the easier path is to push your branch and run `update-hashes-on-demand.yaml` (see "When CI is failing on a PR you didn't push" below).

```bash
# Preferred: rebuild artifacts + recompute hashes in one shot (requires the pinned forge version).
./recompute_hashes.sh

# Alternative (also requires the pinned forge version under the hood):
yarn calculate-hashes:fix
git add system-contracts/SystemContractsHashes.json     # plus any other hash files
```

Verify your local result matches CI's expectation:

```bash
yarn calculate-hashes:check
```

If `calculate-hashes:check` reports a long list of mismatches across libraries you didn't touch (e.g. `Address`, `EfficientCall`, `SafeERC20`), that's a sign the committed hashes are already stale on the branch — independent of your changes. Confirm by running `git stash && yarn calculate-hashes:check && git stash pop`. If the mismatches reproduce on stashed `HEAD`, regenerating is a separate maintenance task; don't try to fold it into your PR.

## Practical pre-push checklist

Before pushing, run from repo root:

```bash
# 1. Build everything (catches Solidity break first)
yarn da build:foundry
yarn l1 build:foundry
yarn sc build:foundry
yarn l2 build:foundry

# 2. Tests
cd l1-contracts && yarn test:foundry && cd ..
cd system-contracts && yarn test:foundry && cd ..
# (Only if you touched contracts that affect interop or upgrades)
cd l1-contracts && yarn test:hardhat:interop && cd ..

# 3. Lint
yarn lint:sol --fix --noPrompt
yarn lint:ts --fix
yarn prettier:fix
yarn l1 errors-lint --check
( cd protocol-ops && cargo fmt && cargo clippy --all-targets -- -D warnings )

# 4. Selectors
( cd l1-contracts && yarn selectors --fix )

# 5. zkstack-out
( cd l1-contracts && forge build && npx ts-node scripts/copy-to-zkstack-out.ts )
yarn prettier:fix

# 6. Hashes (LAST — only after everything above is green)
./recompute_hashes.sh

# 7. Verify nothing else changed
git status
```

## When CI is failing on a PR you didn't push

`update-hashes-on-demand.yaml` is a `workflow_dispatch` workflow that regenerates hashes + zkstack-out and pushes to the PR branch. It only works on PRs from the same repo (not forks), and requires `RELEASE_TOKEN`. Use it when a peer's PR is merge-blocked solely on stale artifacts and they don't have time to regenerate locally.

## Things to NOT do when chasing green

- **Don't `pkill -f anvil`** to clean up. Use `cleanup.sh`. (See `AGENTS.md`.)
- **Don't add `try-catch` / `staticcall` to make a script "robust"** to a missing precondition. The CI failure points at a real ordering / initialization bug; fix the precondition.
- **Don't `anvil_setStorageAt`** to skip a flow that's reverting. The reverting flow is the bug.
- **Don't `--no-verify`, `--no-gpg-sign`, `--force-push`, or `--amend` published commits.** All of these turn a CI failure into something worse later. Add a new commit.
- **Don't run a full `cargo update` in `system-contracts/bootloader/test_infra/`.** Use the selective update recipe in `AGENTS.md` — full updates pull in `crc-fast` / `zerocopy` versions that need post-1.89 nightly intrinsics and break the toolchain.
