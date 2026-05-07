# protocol-ops — design overview and review principles

## Relevant files

- `protocol-ops/src/main.rs` — top-level CLI dispatcher.
- `protocol-ops/src/commands/ecosystem/` — ecosystem-wide commands (`upgrade-prepare`, `upgrade-prepare-all`, `upgrade-governance`, …).
- `protocol-ops/src/commands/ecosystem/v31_upgrade_inner.rs` — canonical v31 prepare-phase orchestration (`V31UpgradeInner::prepare`).
- `protocol-ops/src/commands/ecosystem/v31_upgrade_full.rs` — `V31UpgradeFull` = Inner + ecosystem precondition (`ensureCtmsAndProxyAdminsOwnedByGovernance`).
- `protocol-ops/src/commands/ecosystem/upgrade.rs` — CLI handlers (`run_upgrade_prepare`, `run_upgrade_prepare_all`, `run_upgrade_governance`) and the free `replay_governance_stages` helper.
- `protocol-ops/src/commands/chain/` — per-chain commands (`chain upgrade`, `chain gateway convert`, `chain gateway migrate-to`, …).
- `protocol-ops/src/commands/dev/execute_safe.rs` — replays a Gnosis Safe Transaction Builder JSON bundle against an anvil fork.
- `protocol-ops/src/common/forge/runner.rs` — `ForgeRunner`: owns the anvil fork lifecycle and records every broadcast tx into `runner.runs()` for per-sender Safe-bundle emission.
- `protocol-ops/src/common/l1_contracts.rs` — auto-resolution helpers (CTM, governance, bytecodes supplier, validator timelock, etc.) — read live state directly from L1.
- `protocol-ops/src/config/forge_interface/script_params.rs` — `ForgeScriptParams` invocation specs for each forge script the CLI invokes.
- `l1-contracts/deploy-scripts/AdminFunctions.s.sol` — Solidity helpers invoked by protocol-ops (e.g. `governanceExecuteCalls`, `ensureCtmsAndProxyAdminsOwnedByGovernance`). Auto-imported via the `IAdminFunctions` interface.
- `l1-contracts/deploy-scripts/upgrade/v31/{CoreUpgrade_v31,CTMUpgrade_v31,EcosystemUpgrade_v31}.s.sol` — Solidity entry points for v31 deploys.

## What protocol-ops is

protocol-ops is a Rust CLI that drives privileged ecosystem operations (upgrades, gateway migrations, validator changes, …) by:

1. Spinning up a local **anvil fork** of L1 (the `ForgeRunner` owns this).
2. Running forge scripts against the fork, with permissioned senders **impersonated** via anvil auto-impersonation (`--sender --unlocked`). protocol-ops never broadcasts against real L1.
3. Recording every broadcast tx forge emits into `runner.runs()`, then splitting them by `from` into per-signer **Safe Transaction Builder JSON bundles** in the requested `--out` directory.
4. Real-world signers (multisig members) later replay those bundles against L1 — that's where state actually changes in production.

So protocol-ops is a **simulator + bundle emitter**, not a broadcaster. The anvil fork is the simulation environment that lets us produce the post-state and verify each step works; the bundles are the durable artifact handed off to humans.

`dev execute-safe` is the symmetric replay tool — given a Safe bundle JSON and a private key, it replays the bundle against an anvil fork (used by tests and local validation).

## High-level architecture

### CLI surface (clap-derived)

- Top-level groups: `ecosystem`, `chain`, `ctm`, `hub`, `dev`.
- Each group is a clap `Subcommand` enum; each variant carries an `*Args` struct derived with `Parser`.
- Handlers in each module are `pub async fn run_*(args) -> anyhow::Result<()>` — thin shells that build inputs, run orchestration, write output.

### Orchestration layer (per command family)

For non-trivial flows (the v31 upgrade in particular) we keep a small library-style struct hierarchy distinct from the CLI shells:

- **`V31UpgradeInner`** — canonical prepare orchestration. `prepare(runner, deployer, inputs)` fires `CoreUpgrade_v31.noGovernancePrepare` once and `CTMUpgrade_v31.noGovernancePrepare` once per target CTM, on a single shared `ForgeRunner`. Returns the per-step output TOML paths.
- **`V31UpgradeFull`** — wraps Inner with the real-world precondition `ensureCtmsAndProxyAdminsOwnedByGovernance`. Has only a `prepare` method — the governance phase is plumbing, not orchestration.
- **Free `replay_governance_stages` helper** in `upgrade.rs` — reads each prepared TOML's hex-encoded `stage{N}_calls`, dispatches `governanceExecuteCalls` per stage on the runner. No struct because there's no state.

The asymmetry (Inner/Full for prepare; free fn for governance) is deliberate: prepare needs orchestration (multiple forge invocations + preconditions); governance is a single ABI-passthrough loop.

### Forge invocation

Forge scripts are described in `script_params.rs` as `ForgeScriptParams` (input TOML, output TOML, script path, ABI handle, ffi flag, rpc flag, gas limit). `ForgeRunner::with_script_call` builds the calldata via the bundled ABI; `ForgeRunner::script_path_from_root` is used when the script path is custom (e.g. test variants).

### Auto-resolution from L1

Helper functions in `common/l1_contracts.rs` resolve secondary addresses (CTM proxy, bytecodes supplier, rollup DA manager, governance, validator timelock, ZK chain diamond, …) by reading live state from the bridgehub. Callers should depend on these helpers, not on user-supplied flags, whenever possible.

## General principle: minimize config in and out, query L1 instead

**Whenever a piece of information can be derived from on-chain state, derive it from on-chain state. Don't accept it as a CLI flag, don't read it from a TOML, and don't write it to a TOML.**

The temptation in upgrade tooling is to plumb a long input TOML / output TOML chain through every step. That model is costly:

- **Inputs that duplicate on-chain state drift.** A flag like `--bytecodes-supplier-address` that the CLI also accepts will get wired to a stale value during a real incident, override the correct on-chain value, and break the upgrade in a way that's hard to spot in a Safe bundle review.
- **Outputs that get re-read between steps create coupling.** If step B's input TOML contains addresses that are derivable from L1 state mutated in step A, then losing the TOML breaks the flow even though L1 has the truth. If the orchestrator re-reads addresses from L1 between steps, both phases stay independently rerunnable.
- **Reviewers can verify on-chain queries.** A reviewer can re-run a `cast call` to confirm `bridgehub.chainTypeManager(chainId)` returns the expected address; they can't re-derive a CLI flag without trusting whoever produced it.

In practice this means:

1. **Move querying into foundry whenever possible.** If a value is only used inside the Solidity script, the script should read it from L1 itself rather than having Rust resolve it and pass it in. Rust-side resolvers should be reserved for values that affect forge invocation itself — sender impersonation (`--sender --unlocked`), script selection, orchestration loop bounds. When in doubt, give the script `bridgehub` and let it derive the rest.
2. **Add an `l1_contracts.rs` resolver before adding a CLI flag.** When a new step needs a contract address, the first instinct should be: "where is this on L1, and how do I read it via the bridgehub graph?" Only fall back to a flag if the value genuinely cannot be derived (e.g. the contract isn't deployed yet, or it's a v30→v31 transition where the v31 getters don't exist).
3. **CLI flags for addresses should be `Option<Address>` overrides, not required params.** When the auto-resolver works, the flag is unset; when the auto-resolver can't (a transitional ecosystem state), the operator passes an explicit override. The default path should never require the flag.
4. **Inputs that exist purely to bridge two steps are a smell.** If step B's `--foo-address` flag is "the address step A printed to stdout", refactor: either put the value on-chain (e.g. as a deployed contract's storage slot you can later read) or derive it deterministically (CREATE2). If neither is possible, write it to a TOML keyed by the L1 chain it pertains to, not a free-floating file path.
5. **Output files should be reproducible artifacts (Safe bundles, governance call TOMLs the next protocol-ops invocation reads), not ad-hoc state-passing files.** Anything that's just "step A's notes for step B" should be eliminated by reading from L1 instead.
6. **Default to L1 truth, not config truth.** When a CLI flag and an L1 read disagree, the L1 read is correct. The flag is for the rare transitional case.

The same principle applies to Solidity scripts: prefer reading state via `IBridgehub.getZKChain(chainId)` / `chain.getAdmin()` / etc. over accepting a long params struct. The fewer fields a script signature carries, the fewer ways it can be invoked with stale data.

## Other patterns / invariants

### One ForgeRunner = one anvil fork = one Safe bundle per signer

Multiple sequential `runner.run(script)` calls on the same `ForgeRunner` accumulate into `runner.runs()`. When `write_output_if_requested` flushes the run log, it groups by `from` and emits one Safe bundle per distinct sender. Sharing one runner across multiple steps (the `V31UpgradeFull::prepare` pattern) is how we keep the deployer's prepare-phase txs consolidated into a single Safe bundle.

### Anvil simulates, bundles persist

Every `runner.run(...)` simultaneously (a) executes the script on the anvil fork right now (so subsequent steps see the post-state) and (b) records broadcasts into the run log for later bundle emission. There is no "deferred queue" — the simulation and the bundle are produced together, and the bundle is the canonical output.

### Permission-gated calls broadcast under the actual EOA

Solidity helpers like `ensureCtmsAndProxyAdminsOwnedByGovernance` use nested `vm.startBroadcast(<owner>)` so that inner permission-gated calls (e.g. `transferOwnership`) are recorded against the EOA that actually controls the contract. The Rust side just signs the outer dispatch call as the deployer; per-sender bundle splitting handles the rest.

### `dev execute-safe` chunking

Replaying Safe bundles against anvil submits txs in chunks of `MAX_INFLIGHT` (10), with concurrent submit + receipt-await within a chunk and sequential chunks. Bounds RPC pressure (vs. unbounded `try_join_all`, which can saturate anvil's event loop with concurrent receipt pollers and stall tx import) without giving up most of the parallelism on bundles of typical size (15-30 txs).

### Forbidden patterns

These all live in `contracts/AGENTS.md` but apply equally to protocol-ops:

- **No `try-catch` / `staticcall` in upgrade scripts.** If a function reverts the script must fail loudly; silent fallback to defaults masks initialization bugs.
- **No `anvil_setStorageAt`.** Use real flows; storage overrides hide bugs and break across version layout changes.
- **Inline ABIs are forbidden in TypeScript.** Import from the centralized `contracts.ts` (or, in Rust, from `abi_contracts.rs`).

## Review checklist

When reviewing a protocol-ops PR:

1. **Does it add a CLI flag for something that's on L1?** Push back — add an `l1_contracts.rs` resolver instead, and make the flag an optional override (or omit it).
2. **Does it write a state-passing output TOML between steps?** Check whether the data is derivable from L1 after the previous step runs. If yes, drop the TOML and read from L1 in the next step.
3. **Is each forge invocation invoked via `ForgeScriptParams` and the corresponding ABI in `abi_contracts.rs`?** Inline calldata construction is a smell.
4. **Does the new flow produce one Safe bundle per signer per phase?** If a single phase emits multiple bundles for the same signer, that's a sign the orchestration logic should be on one shared `ForgeRunner`.
5. **Does the prepare phase rely on data only present in-memory across forge invocations?** If yes, either pass it via TOML written by the previous forge call or use CREATE2 determinism — don't fold separate phases back into one forge process to dodge the question.
6. **Are addresses in the orchestration code resolved via `l1_contracts.rs` or via `script_params` consts?** Hardcoded addresses anywhere in protocol-ops are almost always wrong.
7. **Does the new code touch the legacy monolithic `EcosystemUpgrade_v31` flow?** That flow exists only to keep the v31 fork test in `l1-contracts/test/anvil-interop/` working; new development should target `CoreUpgrade_v31` + `CTMUpgrade_v31` via `upgrade-prepare-all`.
