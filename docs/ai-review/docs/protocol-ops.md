# protocol-ops — design overview and review principles

## Relevant files

- `protocol-ops/src/main.rs` — top-level CLI dispatcher.
- `protocol-ops/src/commands/ecosystem/` — ecosystem-wide commands (`upgrade-prepare-all`, `upgrade-governance`, `verify-bootstrap`, `list-ctms`, `governance-toml-to-simulator`, …).
- `protocol-ops/src/commands/ecosystem/upgrade_inner.rs` — canonical prepare-phase orchestration (`UpgradeInner::prepare`: core prepare, then the per-CTM prepare).
- `protocol-ops/src/commands/ecosystem/upgrade_full.rs` — `UpgradeFull` = Inner + ecosystem precondition (`ensureCtmsAndProxyAdminsOwnedByGovernance`) + the ServerNotifier handover calls after the prepares (bootstrap only).
- `protocol-ops/src/commands/ecosystem/upgrade.rs` — CLI handlers (`run_upgrade_prepare_all`, `run_upgrade_governance`, `run_list_ctms`), the merge (`write_merged_ecosystem_toml`) and the free `replay_governance_calls` helper.
- `protocol-ops/src/commands/ecosystem/simulator.rs` — converts prepared governance TOMLs into transaction-simulator JSON.
- `protocol-ops/src/commands/chain/` — per-chain commands (`chain init`, `chain upgrade`, `chain set-da-validator-pair`, …).
- `protocol-ops/src/commands/dev/execute_safe.rs` — executes a Gnosis Safe Transaction Builder JSON bundle by signing each tx with a supplied private key and sending raw transactions to the given RPC URL.
- `protocol-ops/src/common/forge/runner.rs` — `ForgeRunner`: owns the anvil fork lifecycle and records every broadcast tx into `runner.runs()` for per-sender Safe-bundle emission.
- `protocol-ops/src/common/l1_contracts.rs` — auto-resolution helpers (CTM, governance, bytecodes supplier, validator timelock, etc.) — read live state directly from L1.
- `protocol-ops/src/common/forge/scripts/mod.rs` — `ForgeScriptParams` invocation specs for each forge script the CLI invokes, and the `ScriptCall` table binding each typed call to its script.
- `l1-contracts/deploy-scripts/AdminFunctions.s.sol` — Solidity helpers invoked by protocol-ops (e.g. `governanceExecuteCalls`, `ensureCtmsAndProxyAdminsOwnedByGovernance`). Auto-imported via the `IAdminFunctions` interface.
- `l1-contracts/deploy-scripts/upgrade/v35/{CoreUpgrade_v35,CTMUpgrade_v35}.s.sol` — the bootstrap edge's prepares; `v36/` the first registry-driven release's.
- The core prepare deploys the Core-domain `ProxyUpgradeTransition`, the CTM prepare the CTM-domain one and/or the `CTMTransition`, and the merge derives the executor legs (`applyL1Upgrade`, `applyInfrastructureUpgrade`, `applyCTMUpgrade`) from the objects and executors they report — there is no compose step. The merged package carries ONE governance bundle, `[governance_calls] calls`: the merge's extras (PUH/Guardians wiring, CTM `acceptOwnership()` normalization), the core prepare's declared calls, the derived legs in canonical order (none for a bootstrap or a replacement), then the CTM prepare's declared calls. The runbook is `l1-contracts/deploy-scripts/upgrade/README.md`.

## Verifying a package before it is signed

One verifier, `ecosystem verify-bootstrap` (alias `verify-package`,
`upgrade_verification/registry/`). It decides from the package itself which kind it drives — an
UPGRADE (one to three executor legs), the one-time BOOTSTRAP edge onto the registry model, or the
REPLACEMENT of a committed transition (one `CTMUpgradeExecutor.forward([replaceUpgradeTransition(...)])`,
see "Replacing a committed transition" in `protocol-docs/ecosystem-upgrade-coordination.md`) — and
refuses a package that is none of them or mixes them rather than verifying it as the nearest
match. It needs only the merged prepare TOML and an L1 RPC: the registry model moved the reviewable content off the
calldata and onto write-once objects, so objects are identified against the reviewed commit's own
artifacts rather than reconstructed from a CREATE2 deployment history.

> Pre-registry calldata packages are verified by the `ecosystem verify-upgrade` of the release
> branches that shipped them, not here. A registry-driven upgrade is reviewed the same way for
> every release, so a release does NOT get a verifier module of its own: `v36` needs no code here —
> its prepare (`CTMUpgrade_v36`) only declares its changed members and the standard L2 side, an
> ordinary upgrade, and the upgrade path verifies it as one. If a future release ever seems to need version-specific handling, it
> belongs as an INPUT to the general path, not as a new module.

It answers two questions and keeps them apart.

**What does this upgrade do?** is answered by reviewing the objects, never by reconstructing them
from calldata:

- **Construction.** The check that carries object trust (why: "Provenance and validation" in
  `docs/registry-driven-upgrades.md`). Each object's address is re-derived from the reviewed
  creation code and the arguments it was constructed with, and compared with the address the package
  uses. For a write-once object the arguments are the manifest it serves; for both domain executors
  they are the original constructor arguments their records state, and for the bootstrap sequence
  the reviewed migration and core transition — never the object's own getters. The current owner
  and nomination are checked separately against the reviewed governance. The creation-code bytes
  come from the local build (`l1-contracts/out`, so the reviewed commit must be built), held against the committed `evmBytecodeHash`. The salts are
  per prepare leg: each prepare records the one it deployed under (`create2_factory_salt`, merged
  under `[core]` / `[ctms.*]`) and `--create2-salt` adds more; with no salt the check cannot run,
  and that is an ERROR rather than a silent pass. An executor is re-derived from its
  `[upgrade_executors]` record — salt and ORIGINAL constructor arguments, written by the run that
  deployed it (`ecosystem init`, `ctm init` or the bootstrap prepares) and read from the package or
  `--executor-record` — so one whose owner moved since still verifies. The record is mandatory: an
  executor without one is unverified, which is an error.
- **Code identity** (`provenance.rs`) — the live code at an address against the reviewed build's
  deployed bytecode of each contract its role admits, byte for byte outside the artifact's
  immutable slots (`immutableReferences`), with the build's bytes held against the committed
  `evmDeployedBytecodeHash`. Code that is a _different_ contract is an ERROR, and so is code that
  is NO reviewed contract: the reviewer cannot say what is deployed there, and an unresolved
  deployment must not ride along with an otherwise successful review. (The usual cause is an
  un-regenerated hash file, which makes every lookup miss at once — fixed before the review
  concludes, not annotated in it.) Masking proves the CODE, not the values the constructor wrote
  into the masked slots: for the write-once objects their construction covers those, and the
  executors are identified by construction alone — getters answering the reviewed values would
  admit any counterfeit that answers them too.
- **Members** (`members.rs`) — every member an object names runs the reviewed build's code for its
  role: a release's genesis facets (one of the six facets), `DiamondInit`, `L1GenesisUpgrade`, its
  verifier (a top-level verifier) and every sub-verifier the verifier names through its
  `*_VERIFIER()` getters; a transition's engine `DefaultUpgrade`, the bootstrap migration's
  `BootstrapUpgrade`, an L2 plan's `L2DefaultDelegateCalldataComposer`. The one exception is the
  verifier already in force where the upgrade departs from (the departing release's, or the one the
  CTM's chains run for the bootstrap), which a release carries over without redeploying and an
  earlier build may have produced. `ZiskVerifier`'s snarkJS Plonk backend is outside the
  repository's build, so the code at its `PLONK_VERIFIER()` must hash to a runtime pinned in
  `tools/verifier-gen/data/ZiSK_plonk_backend.toml` (`external_backends.rs`); no code, no applicable
  pin or another hash fails the run. L2 members are ZKsync OS bytecode infos held against the
  reviewed hashes' `(blake2s, length, keccak256)`: each L2 table row the contract of its
  `L2EcosystemContract` slot, the shell `SystemContractProxy`, a plan's delegate `L2DefaultUpgrade`,
  each extra bytecode some reviewed contract.
- **Member construction** (`member_construction.rs`) — every L1 member a package NEWLY installs (a
  release member the departing release does not name — at the bootstrap anything but the verifier
  the chains run and its tree — every engine and composer, each row's `implNew`, the implementation
  behind a proxy the package introduces) is re-derived from the prepare's `[member_deployments]`
  record: the reviewed creation code on the recorded, exactly-ABI-encoded arguments under the
  recorded salt through the deterministic factory must land at the member. Each argument is held
  against the source the prepare read (`CONSTRUCTOR_EXPECTATIONS`): the RPC's chain id, the env's
  `testnet_verifier`, the reviewed Bridgehub (the env's `bridgehub_proxy_addr` or
  `--expected-bridgehub`, which the package's CTM and `bridgehub_proxy_addr` must agree with) and
  the proxies, WETH token, owner and chain cap read through it, the rollup DA manager of a chain on
  the CTM (and the env's, which must agree), a deployed reviewed `EIP7702Checker`, the sub-verifiers
  the walk read, the CTM immutables the row check established — never a package value. A missing
  record, a record that does not re-derive, a wrong or unestablished argument, a parameter without
  an expectation all fail. What this cannot cover: the values in a CARRIED-OVER member's immutable
  slots, accepted by the review that installed it (none for a release `ctm init` deployed), and
  the `initialize` calldata of a proxy the package introduces.
- **Inventory slots** (`rows.rs`) — every participating proxy row names the proxy of its slot
  (`L1EcosystemContract` / `CTMContract` member `i`), discovered on chain through the Bridgehub and
  the getters it links (asset router, nullifier, NTV, message root, CTM deployment tracker, chain
  asset handler, chain registration sender, interop handler) or through the CTM (itself, its
  validator timelock, bytecodes supplier, permissionless validator, server notifier), and its
  `implNew` runs the slot's contract. A row in a slot that is no proxy of its domain fails. Before
  that, the inventory must be exactly its enum's length with at least one participating row, and
  every participating row a real edge: nonzero `proxy` and `expectedOldImpl`, an `implNew` other
  than `expectedOldImpl`, no proxy twice. A new `ChainTypeManager` implementation's constructor
  immutables, which code identity masks, are held by value against the live CTM, else the
  inventory row of their slot, else a proxy the package introduces that runs the reviewed
  `TransparentUpgradeableProxy` with the CTM-domain ProxyAdmin in its EIP-1967 admin slot and the
  slot's reviewed contract behind it (`BRIDGE_HUB` has no fallback) — through its getters, and
  again through its construction record (its `_bridgehub` against the reviewed Bridgehub), as is
  every `implNew` (member construction above).
- **Bound authority** — the domain executors the legs run through (the CTM executor's immutable
  CTM and `ProxyAdmin` held against the package's independently reviewed CTM and `ProxyAdmin`, the
  core executor's against the ecosystem `ProxyAdmin`), the CTM and both ProxyAdmins, and the
  governance owner the whole lifecycle answers to, with no ownership nomination outstanding on any
  of them; for a bootstrap also the owner of the CTM's Bridgehub, which the CTM takes chain freezes
  from too. The reviewed owner is what the executors' current ownership is checked against, so for
  an upgrade package `--expected-governance-owner` is not optional: without it that ownership is
  unverifiable, which is an error.
- **Departing state** — the version and release edge against live, and every proxy row's
  `expectedOldImpl` against the implementation actually live behind that proxy, read through the
  domain's bound `ProxyAdmin` and accepting a row already at its `implNew`. For a bootstrap, every
  chain on the CTM below the departing version is listed as a warning, not an error (the legacy
  `protocolVersionVerifier` getter keeps them upgradeable).
- **Genesis** — on the upgrade and bootstrap paths, a release's genesis batch hash against the
  reviewed commit's genesis config (`configs/genesis/zksync-os/latest.json`), its index against
  zero, and every field of its force-deployments data against an independent expectation: the L1
  chain id, the live Bridgehub's asset router, chain cap and (aliased) chain-registration sender,
  the aliased reviewed governance, the reviewed ZK token asset id (the `zk_token_asset_id` of the
  `--env` permanent values; without `--env` the run stops), zero for the legacy fields, and the
  release's own table for the bytecode fields; the package's `force_deployments_data` remains a
  cross-check. A replacement lands on an existing release and is exempt.
- **System-proxy shell** — on the upgrade and replacement paths, the arriving release's shell
  against the departing release's, compared with the compiler metadata stripped (why: "What the
  derivation guarantees" in `docs/registry-driven-upgrades.md`). The code comes from the reviewed
  genesis image or the CTM supplier's `EVMBytecodePublished` log; a shell in neither is an ERROR. A
  logic change is an ERROR when the edge's delegate is absent, the stock `L2DefaultUpgrade` or code
  the reviewed commit does not build, and a WARN naming any other delegate.
- **Readiness**, reported apart from anything about value: the transition's or the bootstrap
  migration's L2 factory dependencies published on the CTM's supplier.
- **Release validity** — the arriving release's own `validate()`, called before the vote. It
  depends only on the code at the addresses it names, so a revert here is the release failing every
  on-chain check that runs it (a transition's construction, the bootstrap, the install).

**Does the signed transaction invoke the reviewed upgrade, at the reviewed addresses, in the
reviewed order?** For an upgrade that is the whole of it (`verify_upgrade_calls`): each leg is
re-encoded here from the reviewed executor and object, and the run — core, then CTM
infrastructure, then CTM transition, each only when present — must appear exactly once,
contiguous and in that order. With no coordinator on chain, the order the bundle states is the
order the domains apply in; the one governance execution keeps them atomic. Every other call must
be a declared governance external action, matched one for one and in declared order, and none may
reach the upgrade's authorities (the executors, the objects, the CTM, either ProxyAdmin) whether
declared or not. The legs' INTERNAL calls are deliberately not re-derived — the executors derive
them on chain from the same pinned objects, and a second derivation in the tool would be a second
implementation to keep in sync.

A bootstrap edge is the exception, because its executors do not yet hold their domains: governance
executes a LIST of ordinary calls that `RegistryBootstrapSequence.actions()` derives, so the
submitted bundle must END with exactly that list, and only declared calls outside the edge's
authorities (the merge's extras) may precede it. The list's last call is `validateApplied()` on the
migration, so a bootstrap that does not complete reverts the whole bundle. That list comparison is
transitional scaffolding for the
bootstrap alone, and nothing new should be built on it. A replacement's bundle carries one
`forward` to the CTM's executor and nothing else that reaches the CTM or its executor.

It deliberately does NOT re-derive facet cuts, L2 transactions or proposals — those come from the
audited on-chain derivation. Of the objects' own `validate()` it calls only the arriving
release's; what the others check, its other checks cover.

```bash
cargo run --release --bin protocol_ops -- ecosystem verify-bootstrap \
  --ecosystem-toml <out>/prepare/ecosystem.toml \
  --l1-rpc-url $L1_RPC \
  --expected-governance-owner 0x... \
  --env <env> \
  --executor-record <the package or init output that deployed the executors> \
  --create2-salt 0x...
```

`--contract-hashes <path>` replaces the committed `AllContractsHashes.json`; only the anvil upgrade
runner (`yarn test:upgrade`) uses it, with the hashes of the build it deployed from, because the
committed file is regenerated last. The runner verifies the bootstrap and each registry-driven hop
with `--env local` and the bootstrap package as `--executor-record` before it replays governance.

In every kind the executing objects are recovered from the CALLDATA governance will run — each
leg's (executor, object) pair for an upgrade, the bundle's `migrate()` call for a bootstrap, the
replacing `forward` for a replacement — and the prepare's summary fields (`core_transition_addr`,
`core_upgrade_executor_addr`, `ctm_infrastructure_transition_addr`, `ctm_transition_addr`,
`ctm_upgrade_executor_addr`, `bootstrap_migration_addr`) are cross-checks against them. A
disagreement is an ERROR: the reviewer read one upgrade and governance would sign another. For an
upgrade the legs and the summaries must match one for one, so a reported object without its leg, a
leg without its reported object, a substituted object or executor and a duplicated leg are refused
when the package loads.

**Did the bundle land?** is not this verifier's question but `ecosystem upgrade-governance`'s: it
replays the bundle on a fork and fails unless the fork is left in the state the package describes
(`registry/applied.rs`): the CTM's version, release and committed transition, the CTM domain and the
notifier held by the CTM executor, both executors owned by governance, no nomination outstanding,
every row's proxy at its `implNew`. On chain, the bootstrap's `validateApplied()` and
`applyCTMUpgrade`'s check of its own commit assert part of it in the same transaction.

## What protocol-ops is

protocol-ops is a Rust CLI that drives privileged ecosystem operations (upgrades, chain bring-up, validator changes, …) by:

1. Spinning up a local **anvil fork** of L1 (the `ForgeRunner` owns this).
2. Running production forge-script commands against the fork, with permissioned senders **impersonated** via anvil auto-impersonation (`--sender --unlocked`).
3. Recording every broadcast tx forge emits into `runner.runs()`, then splitting them by `from` into per-signer **Safe Transaction Builder JSON bundles** in the requested `--out` directory.
4. Operators later execute those bundles through the real signer path (Safe UI / approved executor / owner flow) — that's where state actually changes outside the fork.

So the main protocol-ops commands are **simulator + bundle emitters**, not direct broadcasters. The anvil fork is the simulation environment that lets us produce the post-state and verify each step works; the bundles are the durable artifact handed off to operators.

`dev execute-safe` is a developer replay helper. Given a Safe bundle JSON, an RPC URL, and a private key, it signs and submits every transaction from that key's address. It is intended for anvil/local validation unless someone deliberately points it at a live testnet RPC.

`ecosystem governance-toml-to-simulator` is the transaction-simulator bridge: it reads a prepared protocol-ops governance TOML, decodes `[governance_calls] calls`, and emits the simulator's JSON transaction list (one `governance`-tagged transaction per call, the sender funded on the first).

`upgrade-prepare-all` writes the canonical merged artifact to `<env-out>/ecosystem.toml`.
Both `upgrade-governance --env` and `governance-toml-to-simulator --env` discover that path; use
`--governance-toml` only to replay an explicitly selected artifact.

## High-level architecture

### CLI surface (clap-derived)

- Top-level groups: `ecosystem`, `chain`, `ctm`, `hub`, `dev`.
- Each group is a clap `Subcommand` enum; each variant carries an `*Args` struct derived with `Parser`.
- Handlers in each module are `pub async fn run_*(args) -> anyhow::Result<()>` — thin shells that build inputs, run orchestration, write output.

### Orchestration layer (per command family)

For non-trivial flows (the ecosystem upgrade in particular) we keep a small library-style struct hierarchy distinct from the CLI shells:

- **`UpgradeInner`** — canonical prepare orchestration. `prepare(runner, deployer, inputs)` fires the version's core script `noGovernancePrepare` once and its CTM script `noGovernancePrepare` once per ZKsync OS CTM, on a single shared `ForgeRunner`. Each prepare deploys its own domain's objects; on the bootstrap edge the CTM prepare takes the core executor from the core prepare's output. Returns the per-step output TOML paths.
- **`UpgradeFull`** — wraps Inner with the real-world precondition `ensureCtmsAndProxyAdminsOwnedByGovernance` before and the ServerNotifier handover calls (bootstrap only) after. Has only a `prepare` method — the governance phase is plumbing, not orchestration.
- **Free `replay_governance_calls` helper** in `upgrade.rs` — reads each prepared TOML's hex-encoded `[governance_calls] calls`, dispatches one `governanceExecuteCalls` for legacy Governance or `governanceExecuteCallsDirect` for PUH-governed environments. No struct because there's no state.

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

Multiple sequential `runner.run(script)` calls on the same `ForgeRunner` accumulate into `runner.runs()`. When `write_output_if_requested` flushes the run log, it groups by `from` and emits one Safe bundle per distinct sender. Sharing one runner across multiple steps (the `UpgradeFull::prepare` pattern) is how we keep the deployer's prepare-phase txs consolidated into a single Safe bundle.

### Anvil simulates, bundles persist

Every `runner.run(...)` simultaneously (a) executes the script on the anvil fork right now (so subsequent steps see the post-state) and (b) records broadcasts into the run log for later bundle emission. There is no "deferred queue" — the simulation and the bundle are produced together, and the bundle is the canonical output.

### Permission-gated calls broadcast under the actual EOA

Solidity helpers like `ensureCtmsAndProxyAdminsOwnedByGovernance` use nested `vm.startBroadcast(<owner>)` so that inner permission-gated calls (e.g. `transferOwnership`) are recorded against the EOA that actually controls the contract. The Rust side just signs the outer dispatch call as the deployer; per-sender bundle splitting handles the rest.

### `dev execute-safe` replay

Replaying Safe bundles submits txs sequentially: estimate gas, sign locally, send the raw tx, await its receipt, then continue. This is intentional because later bundle txs may depend on state created by earlier txs. Safe Transaction Builder JSON does not contain the broadcasting Safe address, so the broadcaster is always the address derived from `--private-key`.

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
7. **Does the new code reintroduce a monolithic prepare, or author governance calldata in Rust?** Push back. Current work targets the `Default*Upgrade` version scripts (`v35/`, `v36/`) via `upgrade-prepare-all`; the merger copies bundles and authors nothing — the only calldata it produces is the executor legs, each a pure function of an (executor, object) pair the prepares report — and anything that is not an executor leg must be a declared external action.
