# Mutation testing

Mutation testing changes a contract on purpose (a flipped comparison, a removed check, a storage write
set to zero) and runs the tests. A change no test notices, a _surviving mutant_, marks code the tests run
without pinning down. `yarn l1 mutation` wraps Foundry's `forge test --mutate` for this repository.

It grades the tests of code that exists. It cannot point at a check that was never written.

## Requirements

- **Foundry v1.8.0 or later.** The repository pins v1.5.1 (`.github/foundry-versions.env`), which has no
  `--mutate`, so point `FORGE` at a newer `forge`. Stable 1.8.x skips sibling mutants depending on timing,
  so identical runs score differently; builds that include
  [foundry-rs/foundry#17423](https://github.com/foundry-rs/foundry/pull/17423) (nightlies from 2026-10-06)
  give the same result every run.
- Node dependencies installed (`yarn`). No build step: forge compiles every mutant itself.

## Usage

```bash
# One contract; paths may be relative to the repository root or to l1-contracts/
FORGE=/path/to/forge yarn l1 mutation contracts/common/libraries/Merkle.sol

# Contracts changed on this branch, statement-level operators only; survivors on changed lines only
FORGE=/path/to/forge yarn l1 mutation --base origin/draft/v0.35.0 --operators statement

# Every in-scope contract: hours, see "Cost and memory"
FORGE=/path/to/forge yarn l1 mutation --all --json mutation.json
```

`yarn l1 mutation --help` lists the other options. The report goes to stdout and, in GitHub Actions, to
the job summary.

## How it works

1. **Targets.** Contracts under `contracts/`, minus interfaces, error files, `Config.sol`,
   `dev-contracts/`, generated verifiers and Gateway code (`TARGET_EXCLUDES` in
   `l1-contracts/scripts/mutation/config.ts`).
2. **Tests.** Suites that need `ffi` or read outside the project cannot run in forge's mutant workspaces
   (`TEST_EXCLUDES`). The contract's own tests, named after it or listed in `NARROW_TEST_OVERRIDES`, run
   first. The broad set is every runnable test that imports the contract.
3. **Forge pass.** `forge test --mutate` under the `mutation` profile in `l1-contracts/foundry.toml`:
   optimizer off, `deploy-scripts/` copied into each mutant workspace, a fixed fuzz seed. Forge compiles
   all of `contracts/` and every test helper for each mutant, so the wrapper passes `--skip` for every
   source the selected tests never import. That cut a mutant from ~9 to ~1–3 CPU-seconds.
4. **Guard removal.** Most checks here are written `if (cond) { revert ...; }`, and forge has no operator
   that removes one. The wrapper adds a mutant per guard with the condition replaced by `false`.
5. **Re-check.** Guard mutants, and forge's survivors from the contract's own tests, run against the
   broad set. Persistent workspaces under `l1-contracts/cache/mutation-work/` compile incrementally, so
   a mutant there costs one recompile of the files that depend on the contract.
6. **Triage.** Survivors are matched against `l1-contracts/mutation-exceptions.json`.

## Triaging survivors

A survivor means that change passes every runnable test. Either tighten a test (assert the storage
write, the event or the revert the mutant breaks) or, when the mutant cannot change behaviour, record it:

```json
[
  {
    "file": "contracts/common/libraries/Merkle.sol",
    "source": "for (uint256 i; i < pathLength; ++i) {",
    "original": "++i",
    "mutant": "i++",
    "reason": "equivalent: loop increment"
  }
]
```

`source` is the trimmed source line, so an entry survives edits elsewhere in the file. Most equivalent
mutants come from `binary-op`: `x == 0` → `x <= 0` on an unsigned value, `i < n` → `i != n` as a loop
bound. Statement-level and guard survivors are the strongest signal. `--check` exits 1 on untriaged
survivors, and, after a full run of a file, on entries that no longer match anything.

## Cost and memory

Measured on 8 cores in October 2026:

- **Forge pass.** ~1–3 CPU-seconds per mutant against a contract's own tests. A contract has roughly
  1–3.5 mutants per line of code.
- **Re-check.** 4–27 seconds per mutant against the broad set, longest for libraries that most tests
  import.
- **Memory.** Unoptimized compilation peaks at ~4 MB per source file: 0.2 GB for a library's own tests,
  ~2.5 GB for the whole runnable suite. Workers default to what fits in free memory less 3 GB; `--jobs`
  overrides that.
