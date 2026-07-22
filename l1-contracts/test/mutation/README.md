# Atomic-interop mutation testing suite

A focused [mutation testing](https://en.wikipedia.org/wiki/Mutation_testing) harness for the atomic
interop feature. It systematically introduces small faults ("mutants") into the atomicity contracts
and checks whether the atomicity-focused test suite catches each one. A mutant that slips through
("survives") points at a specific behaviour the tests do not actually assert.

It is self-contained (no Gambit/Vertigo needed) and uses the repo's own `@solidity-parser/parser`,
so mutations are placed precisely on the atomicity code rather than the whole tree.

## What it mutates

Scoped to the atomicity feature (see `config.js`, `TARGETS`), tiered so the report separates the
score of the logic proper from its substrate and entry points:

| tier         | files                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| `core`       | `AtomicFlowManager.sol`, `AtomicInteropProof.sol`, `L2InteropCommitmentTree.sol`, `ChainBatchRootTree.sol` |
| `substrate`  | `IndexedMerkleTree.sol` (the IMT engine the tree/proofs delegate to)                                       |
| `entrypoint` | atomic-only functions of `InteropCenter.sol` and `L2InteropHandler.executeAtomicBundle`                    |

For the two large entry-point contracts only the atomic functions are mutated (via `functions:` in
the target config); everything else in those files is out of scope.

## The kill signal

A mutant is **killed** iff at least one of the atomicity-focused foundry tests fails against it —
the exact file list is `KILL_SIGNAL_TESTS` in `config.js` (the AtomicFlowManager unit suites incl.
finalize/refund, the proof/tree/IMT suites, and the atomic send/refund + execute/finalize
integration tests).

Scoping the kill signal this tightly is deliberate: a survivor here is a gap in the _atomicity_ test
suite, even if some unrelated test elsewhere would happen to catch it.

## Operators

| code  | operator                    | example                                                                                        |
| ----- | --------------------------- | ---------------------------------------------------------------------------------------------- |
| `ROR` | relational replacement      | `<=` → `<`, `==` → `!=`, `a > b` → `true`/`false`                                              |
| `COR` | conditional/logical         | `&&` ↔ `\|\|`, remove unary `!`                                                                |
| `AOR` | arithmetic/bitwise/shift    | `+` ↔ `-`, `*` ↔ `/`, `>>` ↔ `<<`                                                              |
| `LVR` | literal value               | `0` → `1`, `true` ↔ `false`, `3` → `2`/`4`                                                     |
| `ICR` | increment/decrement         | `++` ↔ `--`                                                                                    |
| `GRD` | guard disabling             | `if (cond) revert` → `if (false) …`; `require(cond)` → `require(true)`                         |
| `SDL` | statement deletion          | delete an assignment / `emit` / standalone call                                                |
| `RVR` | boolean return              | `return true` ↔ `return false`                                                                 |
| `SWP` | domain-specific symbol swap | `IMT_BEGIN_ROOT_LEAF_INDEX` ↔ `IMT_END_ROOT_LEAF_INDEX`; `LegState.Committed` ↔ `Revertable` … |

`SWP` is the atomicity-specific operator: it targets the exact semantic pivots of the feature — the
batch begin/end leaf selection and the leg state machine.

## Usage

Run from the `l1-contracts` directory (module resolution walks up to the repo-root `node_modules`):

```bash
node test/mutation/mutate.js generate   # parse targets -> out/mutants.json (the mutant catalog)
node test/mutation/mutate.js run        # apply each mutant, build + test -> out/results.json (resumable)
node test/mutation/mutate.js report     # render out/report.md
node test/mutation/mutate.js all        # all three
```

The runner:

- generates the `script-out/diamond-selectors.toml` fixture the integration test's `setUp` needs;
- verifies a **green baseline** before mutating (aborts otherwise, so the kill signal is trustworthy);
- mutates one file at a time in place and **always restores it** (even on crash / Ctrl-C);
- is **resumable** — already-classified mutants in `out/results.json` are skipped, so you can stop
  and restart.

Environment overrides:

- `MUT_FORGE_BIN` — forge binary (default `forge`)
- `MUT_FORGE_PATH` — directory prepended to `PATH` (default `<repo>/foundry-zksync`, the CI build)

## Interpreting results

```
mutation score = killed / (killed + survived)
```

**Uncompilable** mutants (the change is rejected by the compiler, not the tests) are excluded from
the score — this is standard practice, since the tests never get a chance to catch them.

Every **survivor** is either:

1. a **test gap** — the tests do not assert the behaviour the mutation broke → add/strengthen a test; or
2. an **equivalent mutant** — semantically identical to the original (e.g. a redundant bound) → no
   action, worth a one-line note.

`out/report.md` lists every survivor with its file:line, operator, and the exact source change, so
each can be triaged directly. **`FINDINGS.md`** is the curated write-up of the latest campaign — the
triaged survivors (real gaps vs equivalent mutants) and the headline result.

## Latest campaign

**94.0%** mutation score (406 killed / 26 survived / 5 uncompilable). The initial run scored 74.8%
and exposed the finalize/execute path (`L2InteropHandler.executeAtomicBundle`,
`AtomicFlowManager.requireFlowFinalized`) as having **no foundry coverage at all** (0% file score);
37 gap-closure tests brought every real gap down. All 26 residual survivors are triaged in
`FINDINGS.md`: 10 equivalent mutants (no observable behaviour change) and 16 mutants in generic
send-path code whose behaviour is covered by dedicated non-atomic suites outside this kill signal.
