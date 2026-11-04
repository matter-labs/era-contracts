---
name: v31-calldata-review
description: Use when generating, replaying, PUVT-checking, or manually reviewing v31 upgrade calldata in era-contracts. Covers the generate calldata -> verify with protocol-ops PUVT -> perform manual/AI calldata review flow.
---

# V31 Calldata Review

Use this skill for v31 upgrade calldata work in `era-contracts`: generation,
fork replay, PUVT verification, and manual/AI review.

## Core Rule

The reviewed object is the provided calldata package. Regeneration, fork
replay, and PUVT output are supporting evidence; they do not replace checking
the provided bytes.

Before semantic review, read:

- `docs/ai-review/docs/v31-calldata-review.md`
- `protocol-ops/README.md`, section "Running the Protocol Upgrade Verification Tool (PUVT)"

## Minimal Inputs

Start from:

- reviewed calldata package or the command that generates it;
- reviewed `era-contracts` commit and submodule state;
- L1 RPC URL and exact review block hash when live-state/full review is in
  scope;
- requested scope: local/fork/stage/prod and pre-signing/post-execution.

Derive everything else from the calldata, reviewed source, fork replay, or
block-pinned RPC reads. Do not ask for signer maps, token lists, CREATE2 salts,
or chain inventories up front if they can be derived.

## Workflow

1. Build `protocol_ops` from the reviewed commit/tool commit.
2. If calldata is not already provided, generate it with the reviewed
   `protocol_ops` command or `l1-contracts/test/anvil-interop/regen-upgrade-calldata.sh`.
3. Preserve the exact generated/provided package as the object under review.
4. Replay prepare bundles on an Anvil fork when `executed-bundles.json` is
   needed for CREATE2 provenance.
5. Run `protocol_ops ecosystem verify-upgrade` against the reviewed package,
   replay log, RPC, chain ID, genesis mode, CREATE2 salt set, and ZK token
   asset ID.
6. Follow `docs/ai-review/docs/v31-calldata-review.md` step by step.
7. Produce an evidence table, exact commands/RPC calls, PUVT output summary,
   blockers/gaps, and a sign-off statement only if justified.

## Review Discipline

- Use the guide's Value Source Matrix whenever a step says "expected".
- Use one pinned L1 state point for live reads.
- Decode nested calldata recursively; do not accept labels in JSON/TOML as
  proof.
- For raw calls to the standard CREATE2 factory
  `0x4e59b44847b379578588920ca78fbf26c0b4956c`, treat calldata as
  `salt ++ init_code`, not selector calldata.
- If a check cannot be derived from calldata, reviewed source, fork replay, or
  block-pinned state, record it as a gap. For stage/prod signing, unresolved
  gaps are blockers.
