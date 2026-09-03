# HANDOFF — EVM-1656: on-chain upgrade preconditions in `ServerNotifier`

Branch: `vg/evm-1656-server-notifier-upgrade-preconditions`, based on `draft/v0.34.0` @ `ae2941eaf`.
All work is local per request — nothing was pushed, no PR opened, no Linear/Slack writes.
A ready-to-paste PR body lives in the last section of this file.

## 1. What was delivered

`ServerNotifier.setUpgradeTimestamp` now consults a pluggable per-protocol-version precondition
checker (owner-registered, magic-value validated), so release-specific prerequisites fail at
scheduling time with the same errors as at execution time; a non-reverting
`previewUpgradePreconditions` view gives operators and CI a dry-run. The first concrete checker,
`V33UpgradePreconditionChecker`, mirrors `V32UpgradeZKsyncOS`'s prerequisite triple, and the
release scripts deploy it and register it through the CTM-admin call set. protocol-ops
`chain set-upgrade-timestamp` fails fast with a readable message via the preview; the v31 upgrade
verification pins the checker bytecode; the anvil-interop v31→v32 test and the local foundry
integration test both assert scheduling is blocked before `RecordPriorityOpLowerBound` and passes
after. Design note with rejected alternatives: `protocol-docs/upgrade-scheduling.md`.

## 2. Decisions a reviewer should challenge

1. **Always-on, no bypass** (the issue sketched `notify(chainId, bool checkPreconditions)`).
   `setUpgradeTimestamp` keeps its exact ABI and always runs a registered checker; the escape hatch
   is the CTM admin deregistering the checker (auditable `UpgradePreconditionCheckerSet` event with
   checker = 0). Rejected: a per-call bypass flag or `setUpgradeTimestampUnchecked` — a
   chain-admin-controlled bypass defeats the footgun protection for exactly the operator who needs
   it, and the ABI stays frozen for protocol-ops / partner runbooks.
2. **Registry on ServerNotifier keyed by old protocol version**, not the upgrade contract itself
   (delegate-called, reads `s.*`, CTM pointer not per-version) and not hardcoded checks
   (ServerNotifier is a long-lived proxy shared across releases). See the design note.
3. **Checker name `V33UpgradePreconditionChecker`** while the sibling upgrade contract is
   `V32UpgradeZKsyncOS`. The plan mandated naming after the release the upgrade-env fixtures
   exercise (genesis v32.0.0, fixture upgrade v32→v33); the mismatch is explained in the NatSpec
   and the design note. An adversarial review pass flagged that every sibling artifact of this
   release (`V32UpgradeZKsyncOS`, `L2V32Upgrade`) is named after the production target version and
   that the v31 provenance tooling now pins a `V33…` artifact inside a v31→v32 rollout — renaming
   to `V32UpgradePreconditionChecker` is a one-commit change if you agree; the plan's naming was
   kept deliberately pending your call.
4. **Preview returns `bytes4[]` error selectors** (collecting every failed check) instead of a
   bool/bytes32 pair. Since `try`/`catch` is forbidden repo-wide, the checker interface carries
   both a reverting check and a non-reverting preview built on shared internal predicates.
5. **Fresh ecosystems get no checker** — a fresh CTM starts at the target version with
   `DefaultUpgradeZKsyncOS`; there is no from-version to guard. `DeployCTM` is untouched.
6. **Gateway out of scope for registration** — the setter works there (owner is the aliased
   governance) but no Gateway release flow registers a checker; Gateway is soft-deprecated.
7. **No batch-drain check in the checker** — `totalBatchesCommitted == totalBatchesExecuted` is
   time-sensitive and would flap at scheduling time (documented in the design note).
8. **protocol-ops preview degrades gracefully but narrowly**: only an empty-data revert (the
   deployed implementation has no preview selector; an old chain whose facets predate the
   checker's getters bubbles the same empty revert) is treated as "no preview available".
   Transport failures and reverts carrying data are propagated as real errors. The preview also
   queries `runner.rpc_url` (the anvil fork the simulation runs against), like every other
   resolver in the command, so fork-mutating prepare flows see the upgraded notifier.

## 3. Not verified locally / left to CI

- **`AllContractsHashes.json` is deliberately left at the base version** and `check-hashes` will
  fail until the "Update Hashes in PR" workflow is dispatched on the PR (it commits the delta
  computed in CI's own environment). Investigation: a local regeneration moved every l1-contracts
  row (155/155) while all 17 da-contracts rows reproduced byte-exactly; a control rebuild of the
  **pristine base tree** on the same machine (pinned forge v1.5.1/b0a9dd9ce, recursive submodules,
  frozen lockfile) diverged from the committed manifest on the same 155 rows — so this macOS
  environment cannot reproduce CI's l1 metadata, and committing a locally computed manifest would
  have rewritten the recorded hashes of the audited surface on unverifiable grounds. Lengths match
  on unaffected rows (e.g. OZ `Address`, 85 bytes both sides); only the metadata blob differs.
  The rows the workflow should actually move: one new (`l1-contracts/V33UpgradePreconditionChecker`)
  plus the importers of the changed sources (ServerNotifier and its metadata closure — e.g.
  AdminFacet, GatewayCTMDeployer\* — and every importer of `L1ContractErrors.sol`).
- **anvil-interop chain states**: regenerated on this branch with the CI recipe
  (`FOUNDRY_PROFILE=anvil-interop` builds + `setup-and-dump-state.ts`) because the
  `state-generation-check` gate compares deployed code exactly and the ServerNotifier bytecode
  changed (its CREATE2 proxy address, and the CTM/diamond addresses that embed it, cascade). The
  macOS-vs-linux caveat from the hash manifest does **not** apply here: this profile strips the
  CBOR metadata (`cbor_metadata=false`, `bytecode_hash="none"`), and the CI-generated v0.31.0
  fixture reproduced byte-identically in the same local run — direct evidence the profile is
  cross-platform deterministic. If CI still disagrees, the "Regenerate Anvil Interop Chain States"
  workflow is the fallback.
- **`zkstack-out`**: `IServerNotifier.json` was regenerated locally via `yarn copy-to-zkstack-out`;
  ABI-only, so it is platform-independent and the strict CI check should agree.
- The first local v31→v32 interop run failed with an unrelated L2-relay revert
  (`forceDeployAndUpgradeUniversal`) on one chain; a clean rerun of the identical code passed
  end-to-end, and the same job was green on other PRs the same day — treated as a local
  port/parallel-anvil flake, not investigated further.

## 4. Validation (clean tree at final commit)

- `yarn da build:foundry && yarn l1 build:foundry` — clean rebuild, success (run three times over
  the branch's life: initial, frozen-lockfile control, final).
- `yarn l1 test:foundry` — full suite: 297 suites, **2504 passed, 0 failed, 0 skipped** — run twice
  (before and after the adversarial-review fix round; 70.7s / 63.1s).
- Targeted: `V33UpgradePreconditionChecker.t.sol` 9/9, `ServerNotifierPreconditions.t.sol` 14/14
  (incl. 5 `vm.load` storage-layout locks), pre-existing `ServerNotifier.t.sol` 14/14 unmodified,
  `UpgradeChainFromVersion.t.sol` 9/9 untouched, `UpgradeIntegrationTest_Local` +
  `UpgradeIntegrationTest_LocalProductionVerifier` both pass (`--ffi --gas-limit 20000000000`).
- anvil-interop: `yarn test:v31-to-v32` — full pass, run twice (167s first round; rerun after the
  harness rework). Per chain (10 and 11): "scheduling blocked with 0x5c25a57b
  (LowerBoundNotRecorded, read from the on-chain preview) before the prerequisite" and
  "upgrade scheduled once the prerequisite holds". `yarn test:hardhat:interop` — 9/10 parallel
  workers passed; worker 1 (`01-deployment-verification`) was signal-killed under the 10-way
  parallel anvil load ("exit code unknown" = killed by signal, no mocha output), and the same spec
  passes in isolation: 60/60 in 473ms. Treated as local resource pressure, not a regression.
- protocol-ops: `cargo fmt --check` OK, `cargo clippy --all-targets -- -D warnings` clean,
  `cargo test` 28/28.
- `yarn lint:sol` (0 warnings), `yarn lint:ts`, `yarn prettier:check`, `markdownlint` on touched
  docs — all clean. `yarn errors-lint --fix` and `yarn selectors --fix` outputs committed.
- `yarn calculate-hashes:check` — fails by design against the base-pinned manifest (see §3); the
  local recomputation itself is self-consistent across clean rebuilds (two independent
  regenerations agreed on every row).
- Storage layout: `forge inspect ServerNotifier storage-layout` diffed against a worktree at the
  base commit — slots 0–3 identical, one appended mapping at slot 4.

## 5. Follow-up candidates (out of scope)

- **"Generic chain-readiness view on the CTM"** — a single view aggregating upgrade-cut presence,
  precondition status, and batch state per chain, for dashboards; today it is spread across CTM,
  ServerNotifier, and Getters.
- **"Bulk-refresh stale selector tables in docs/ai-review"** — Step 16 was fixed here, but other
  steps still carry selectors frozen at v31-rollout time; a sweep with `cast sig` against current
  interfaces would catch the rest.
- **"anvil-interop: assert the scheduling path in the fresh-deploy interop suite too"** — the
  hardhat interop suite never touches ServerNotifier; a cheap smoke call would catch ABI drift
  against `chain-states`.
- **"Fresh ecosystems leave ServerNotifier ownership pending with the deployer"** — `DeployCTM`
  initializes the notifier with `config.deployerAddress` as owner (`DeployCTMUtils.s.sol`
  `getInitializeCalldata`) and then calls `transferOwnership(chainAdmin)`
  (`DeployCTM.s.sol` `updateOwners`), but ServerNotifier is `Ownable2Step` and nothing accepts —
  so `owner()` stays the deployer EOA with the chain admin stuck as pending. Surfaced by a
  prepare-time owner assertion this PR briefly carried (removed again: both call-set executors
  resolve the signer per target, so the divergence routes rather than reverts, and the assertion
  broke the legitimate fixture state). Either an acceptance step is missing from the fresh flow
  or the pending transfer is intentional and undocumented; worth its own issue.
- **"l1-contracts hash manifest is not reproducible on macOS"** — a pristine base-tree rebuild on
  macOS (pinned forge, recursive submodules, frozen lockfile) moves every l1-contracts row of
  `AllContractsHashes.json` while da-contracts reproduces byte-exactly; only the CBOR metadata blob
  differs (lengths match). Contributors on macOS silently regenerate a manifest CI then disagrees
  with; worth pinning down the metadata delta (remappings serialization? solc build?) or making
  `recompute_hashes.sh` refuse on non-linux.

## 6. Instructions for the human

- **Commits are unsigned** (GPG signing was disabled locally to keep the run non-interactive).
  Before pushing, re-sign them, e.g.:
  `git rebase --exec 'git commit --amend --no-edit -n -S' ae2941eaf`.
- Commit-hygiene note: `AllContractsHashes.json` was regenerated in one commit and reverted to the
  base version inside the chain-states commit (it was staged when that commit was made), so it
  bounces across history; the final tree deliberately matches base (see §3). Squash if you care.
- Review first: `l1-contracts/contracts/governance/ServerNotifier.sol` (the one production-contract
  behaviour change), then `V33UpgradePreconditionChecker.sol`, then the CTM-admin call ordering in
  `DefaultCTMUpgrade.s.sol` / `CTMUpgrade_v31.s.sol` (the setter call must stay after the
  implementation upgrade in the same `Call[]`).
- On PR: open as **draft** against `draft/v0.34.0` with the body below, then dispatch the
  "Update Hashes in PR" workflow — `AllContractsHashes.json` is intentionally at the base version
  (see §3) and `check-hashes` stays red until the bot commits CI's delta. Chain-states are
  regenerated on the branch; selectors/zkstack-out are committed and ABI-derived, so they should
  come back unchanged.
- Natural reviewers: Protocol team — Kalman Lajko and Stanislav Bezkorovainyi (Stas filed
  EVM-1656 and the always-on-vs-flag decision in §2.1 deliberately deviates from his sketch).
- Linear: EVM-1656 can move to "In Review" once the PR is up; no comment needed beyond the PR link.

---

## PR body (ready to paste)

## EVM-1656: on-chain upgrade preconditions in `ServerNotifier` (PR title: drop the leading "EVM-1656: " if preferred)

### What

`ServerNotifier.setUpgradeTimestamp` — the call that schedules a chain upgrade and arms the
validator execution path — now consults a pluggable, per-protocol-version precondition checker, so
release-specific prerequisites fail at _scheduling_ time with the same error they would produce at
execution time.

- `IUpgradePreconditionChecker` (magic value + reverting `checkUpgradePreconditions` +
  non-reverting `previewUpgradePreconditions`), modeled on `IRestriction`.
- `ServerNotifier`: an owner-managed `upgradePreconditionChecker[oldProtocolVersion]` registry
  (registration validates the magic value; zero deregisters), the checker call in
  `setUpgradeTimestamp`, and a `previewUpgradePreconditions(chainId)` dry-run view for operators
  and CI. Storage is append-only (new mapping at slot 4; layout diff below).
- `V33UpgradePreconditionChecker`: the first concrete checker, enforcing the exact prerequisite
  triple of `V32UpgradeZKsyncOS.upgrade` (backfill flag, recorded priority-op lower bound, queue
  processed past it) through `IGetters` + the same `PriorityOpLowerBound` registry, reusing the
  same errors so the scheduling failure reads identically to the execution failure.
- Release flow: `CTMUpgrade_v31` deploys the checker and appends its registration to the CTM-admin
  call set (`ctm_admin_calls.server_notifier_upgrade`), after the ServerNotifier implementation
  upgrade in the same in-order `Call[]`; the upgrade output serializes
  `upgrade_precondition_checker_addr`. Fresh ecosystems deploy/register nothing (they start at the
  target version; documented).
- protocol-ops: `chain set-upgrade-timestamp` dry-runs the preview and fails fast with a readable
  list of failed checks (graceful fallback on pre-v34 notifiers); v31 upgrade verification pins the
  checker's bytecode + constructor arg.
- anvil-interop: the v31→v32 upgrade test asserts scheduling is blocked before
  `RecordPriorityOpLowerBound` (`LowerBoundNotRecorded`) and succeeds after, per chain.
- Docs: new `protocol-docs/upgrade-scheduling.md` (design, operator flow, rejected alternatives);
  fixed the stale 3-arg `setUpgradeTimestamp` selectors in
  `docs/ai-review/docs/v31-calldata-review.md` Step 16 and documented the registration call in
  Step 12; scheduling-time enforcement noted in `genesis-and-upgrades.md` and `ci-green.md`.

### Why

Scheduling is the moment a chain commits to its upgrade being executable by its validator, but the
only precondition verified was "the CTM has an upgrade cut". Release-specific prerequisites (the
v31 base-token backfill plus the recorded priority-op lower bound) were enforced only at execution
time and by runbook discipline, so an operator could schedule an upgrade guaranteed to fail.
`ServerNotifier` is the right host: an operationally-upgradeable proxy outside the audited
diamond/CTM surface, with an existing footgun-check precedent (`migrateToGateway`'s
`isReadyForMigration`). Linear: EVM-1656.

### Behavioural changes in production contracts

Exactly one:

1. `ServerNotifier.setUpgradeTimestamp` reverts when a checker is registered for the chain's
   current protocol version and the chain fails it. Locked by
   `ServerNotifierPreconditions.t.sol` (each precondition individually; mapping not written on
   revert) and, end to end through the real release scripts, by
   `UpgradeTestv31_Local.t.sol::beforeChainUpgrade` and the anvil-interop v31→v32 test.
   With no checker registered (every existing deployment, fresh ecosystems, and any version the
   release flow registers none for) behaviour is unchanged — locked by the pre-existing
   `ServerNotifier.t.sol` suite, which passes unmodified.

The `UpgradeTimestampUpdated` event, the `protocolVersionToUpgradeTimestamp` mapping, and the
`setUpgradeTimestamp(uint256,uint256)` ABI consumed by the server watcher, protocol-ops, and
partner runbooks are unchanged. New externals (`setUpgradePreconditionChecker` — `onlyOwner`,
`previewUpgradePreconditions` — `view`) are additive. `AllContractsHashes.json` is deliberately
left at the base version: local (macOS) regeneration proved non-reproducible against CI for every
l1-contracts row — including on a pristine base tree — so the manifest delta must come from the
"Update Hashes in PR" workflow rather than an environment nobody can verify. Expect it to add the
`V33UpgradePreconditionChecker` row and move the importers of the changed sources (ServerNotifier's
metadata closure and every importer of `L1ContractErrors.sol`, whose error addition shifts their
metadata). Note `AdminFacet` now transitively pulls `IUpgradePreconditionChecker` into its metadata
closure (bytecode-metadata only, no behaviour) and will need re-verification on explorers.

### Storage layout (`ServerNotifier`, base `ae2941eaf` vs this branch)

```
slot 0: _owner (address)                                              unchanged
slot 1: _pendingOwner (address) | _initialized (uint8, offset 20)
        | _initializing (bool, offset 21)                             unchanged
slot 2: chainTypeManager (IChainTypeManager)                          unchanged
slot 3: protocolVersionToUpgradeTimestamp
        mapping(uint256 => mapping(uint256 => uint256))               unchanged
slot 4: upgradePreconditionChecker
        mapping(uint256 => IUpgradePreconditionChecker)               APPENDED
```

Also locked at runtime by `ServerNotifierStorageLayoutTest` (`vm.load`-based slot pins).

### Validation

See HANDOFF.md §4 (full commands and counts): full foundry suite 2504/2504; new unit suites 9/9 +
14/14 (+5 layout locks); pre-existing ServerNotifier suite unmodified and green; v31 local
integration tests green (`--ffi`); anvil-interop v31→v32 upgrade test green end to end with the
new scheduling assertions; protocol-ops fmt/clippy(-D warnings)/tests green; all linters green.
Chain-states regenerated on the branch with the CI recipe.

### Checklist

- [x] Happy/unhappy/edge-path tests for every new external
- [x] `errors-lint --fix`, `selectors --fix`, `copy-to-zkstack-out` outputs committed
- [x] Chain-states regenerated (CI `state-generation-check` recipe)
- [x] Storage layout append-only, diffed against the base commit
- [x] No changes to audited diamond/CTM surfaces; server-facing event/ABI frozen
- [ ] Dispatch "Update Hashes in PR" — `AllContractsHashes.json` is at base by design (see PR
      description); `check-hashes` is red until the bot commits CI's delta
