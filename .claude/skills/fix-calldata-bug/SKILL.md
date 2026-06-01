---
name: fix-calldata-bug
description: Use when fixing a bug in the v31 upgrade calldata (the protocol-ops regen code, the zk-governance deploy scripts, or the env config) and the committed artifacts need regenerating. Encodes the two-machine loop — fix + dry-run locally, run the real reproducible regen on a Linux VPS, hand off artifacts through git, finish the sim locally — using two Claude agents (local + VPS) that coordinate only through git, never a direct link.
---

# Fix a bug in the v31 calldata (local ⇄ VPS loop)

You fix and verify the **code** on your dev box, but the committed **artifacts**
(`ecosystem.toml` + the sim-inputs set) must come from a **Linux** machine so
they're bit-identical with CI. macOS-built Foundry artifacts diverge from Linux
just enough to change CREATE2 addresses. So the work splits across two machines,
and — when a Claude runs on each — across two agents.

The companion skills carry the mechanics this one orchestrates:
- `regenerate-v31-stage-calldata` — the prepare → fork-broadcast → PUVT → sim-emit cycle.
- `v31-calldata-review` — generate → PUVT → manual/AI review.

## Core principle: split by reproducibility

| Step | Output | Where | Why |
| --- | --- | --- | --- |
| Edit code | source diffs | **local** | author + read |
| Dry-run regen | throwaway fork artifacts | **local** | prove the fix compiles + PUVT-passes; macOS addresses, **never committed** |
| Real regen | `ecosystem.toml` + `sim-inputs/` | **VPS (Linux)** | bit-identical with CI; the committed artifacts |
| Emit sim | tx-simulator JSON | **local** | a deterministic transform of committed inputs — portable, cheap |

Anything that depends on **compiled bytecode** (CREATE2 addresses → `ecosystem.toml`,
the Camp-B `*.safe.json`) must be produced on the VPS. Anything that's a **pure
transform of already-committed inputs** (the sim JSON from `ecosystem.toml` +
`sim-inputs/`) is done locally.

## Why the sim needs `sim-inputs/` (the handoff artifact)

`governance-toml-to-simulator` builds the sim from **two** sources: the Camp-B
setup bundles (`transferOwnership(PUH)`, ChainAdmin multicalls, ServerNotifier
upgrade — the sim impersonates these) **then** the PUH stage 0/1/2 ceremony.

The ceremony lives in the committed `ecosystem.toml`. The Camp-B bundles do
**not** — they live in `prepare/manifest.json` + its `*.safe.json`, which are
per-run, gitignored, and only exist where `prepare` ran (the VPS). Emit without
them and the sim reverts at stage-1 `acceptOwnership` (`Ownable2Step: caller is
not the new owner`).

So the VPS regen produces a **curated, git-portable** copy:

```
protocol_ops ecosystem governance-toml-to-simulator --env <env> \
  --emit-sim-inputs l1-contracts/upgrade-envs/v0.31.0-interopB/output/<env>/sim-inputs
```

This writes `output/<env>/sim-inputs/` = a normalized `manifest.json` (only
`bundles[]` — **no `metadata[]`**, which would leak local paths / the RPC URL /
timestamps) + the Camp-B `*.safe.json` (Camp-A/deployer bundles dropped). Bundle
`file`s are bare filenames, so the set is machine-independent. `.gitignore`
tracks exactly this path (the broader `manifest.json` / `*.safe.json` stay
ignored). A local emit auto-prefers `sim-inputs/manifest.json` over `prepare/`.

## The loop

```
local: fix code ──push code──▶ VPS: pull, regen ──push artifacts──▶ local: pull, emit sim ──push sim
        + dry-run                 ecosystem.toml + sim-inputs/        tx-simulator JSON
```

### Phase 1 — fix + dry-run (local)
1. Edit the code. Common spots: `protocol-ops/src/commands/ecosystem/*` (prepare,
   puh_guardians, simulator), `protocol-ops/src/upgrade_verification/**` (PUVT must
   stay in lockstep with the deploy scripts — e.g. a member-count truncation in the
   Solidity deploy needs the matching truncation in `deployed_addresses.rs`), the
   zk-governance deploy scripts, or `upgrade-envs/**`.
2. **Build the binary** — `cargo build` (not `cargo check`; check produces no
   binary, and the regen runs the compiled `target/debug/protocol_ops`). Confirm
   with `strings target/debug/protocol_ops | grep <new-flag-or-env-var>`.
3. Dry-run on a Sepolia fork to prove the fix: `regen-and-verify-stage.sh`
   (`L1_FORK_URL=…`, `DEPLOYER_PK_FILE=…`). Goal = prepare succeeds + PUVT green.
   **Discard its `ecosystem.toml`** — macOS addresses aren't the committed ones.
4. Commit + push the **code** branches (era-contracts; zk-governance if its deploy
   scripts changed). The VPS regen pulls these — the artifacts are reproducible
   because the code was already checked here.

### Phase 2 — real regen (VPS)
The VPS agent (or you, over ssh):
1. `git pull` the exact code commits pushed in phase 1 (verify HEAD matches — the
   commit sha is the contract between the agents).
2. Run the canonical regen (`regenerate-v31-stage-calldata`, native on Linux or
   its Docker path) → fresh `ecosystem.toml` + `prepare/`.
3. Emit the handoff set: `governance-toml-to-simulator --env <env> --emit-sim-inputs <…>/sim-inputs`.
4. Refresh CI-derived artifacts (selectors, zkstack-out, AllContractsHashes.json) per
   `regenerate-v31-stage-calldata`'s CI table.
5. Commit **artifacts only** (`ecosystem.toml`, `sim-inputs/`, the CI-derived files) —
   **no code** (it came from local). Push.

### Phase 3 — finish the sim (local)
1. `git pull` the artifact commit.
2. Emit the sim from the committed inputs:
   `governance-toml-to-simulator --env <env> --out ../transaction-simulator/transactions/<dated>.json`
   (auto-uses the pulled `ecosystem.toml` + `sim-inputs/manifest.json`).
3. Rehearse locally: `yarn --cwd ../transaction-simulator simulate --file <…>`.
4. Commit + push the sim JSON to the transaction-simulator repo.

## Agent coordination: git is the only channel

Two Claude agents (local + VPS) do **not** talk directly. They coordinate through
git plus a human relay of turn-taking:

- **Shared branches.** Both pull/push the same era-contracts branch (code + artifacts)
  and the tx-simulator branch (sim).
- **The commit sha is the handshake.** Phase 1 prints the pushed sha; the VPS agent
  pulls and verifies HEAD == that sha before regenerating. Phase 2 prints the artifact
  sha; the local agent pulls that before emitting.
- **Turn-taking is relayed by the human** ("VPS: wait for a push" → local pushes →
  "VPS: pull + regen + push" → "local: wait for that push" → local pulls). Each agent
  waits for the expected sha rather than guessing timing.
- **This skill is committed**, so both agents share one playbook — pull the repo and
  you have the protocol.

### Guardrails
- **Never commit a macOS-produced `ecosystem.toml`** — only the VPS's is canonical.
- **Code is pushed from local; artifacts are pushed from the VPS.** Don't regenerate
  artifacts on macOS for commit, and don't edit code on the VPS (it would diverge from
  the reviewed local commit).
- **`cargo build`, not `cargo check`**, before any regen — and re-verify with `strings`.
- **Keep PUVT in lockstep** with the deploy scripts; a deploy-side change with no
  matching verification change fails phase-1 PUVT (that's the point — let it catch you
  locally before the VPS run).
- Don't push to `matter-labs/era-contracts` directly — use the fork (`origin`).
