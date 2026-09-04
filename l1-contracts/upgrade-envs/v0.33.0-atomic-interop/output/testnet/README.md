# v33 (`v0.33.0-atomic-interop`) upgrade calldata — TESTNET

Public ZKsync OS testnet on Sepolia. Bridgehub `0xc4FD2580C3487bba18D63f50301020132342fdbD`,
governed by the ProtocolUpgradeHandler `0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D`.

## Scope: one CTM, not two

Two CTMs are registered on this bridgehub:

| CTM                                          | kind              | chains        | version before |
| -------------------------------------------- | ----------------- | ------------- | -------------- |
| `0x54D55e74De9c6003E7a68a1fE70E633f05761eb5` | ZKsync OS (Atlas) | 25            | `0x1f00000001` |
| `0x3Cc81628a14C824057a97C1B4Ab17758E5D18864` | EraVM             | 1 (chain 301) | `0x1f00000000` |

**Only the ZKsync OS CTM is upgraded.** v33 is a ZKsync OS-only release — there is no Era
counterpart to `V32UpgradeZKsyncOS`, and `CTMUpgrade_v33.noGovernancePrepare` refuses an
EraVM CTM outright. `upgrade-prepare-all` logs `skipping Era CTM 0x3cc81628…` and emits
nothing for it, so chain 301 stays on v31.

The `[create2_factory_salts]` table in `../../testnet.toml` has a single entry for the same
reason.

## What is committed here

| file                          | what it is                                                                                                                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ecosystem.toml`              | **The artifact.** Merged `[governance_calls]` (stage 0/1/2 hex) plus every new address. This is what reviewers diff and what every downstream tool reads.                           |
| `transactions.txt`            | Real-Sepolia tx hashes for the deployer bundle (see "Deployed contracts").                                                                                                          |
| `extra-verification-logs.txt` | One `forge verify-contract` line per deployed contract, with constructor args.                                                                                                      |
| `sim-inputs/`                 | Machine-independent inputs the simulator emit consumes: a normalized `manifest.json` plus the Camp-B `*.safe.json` bundles. Camp-A (deployer) bundles are excluded by construction. |
| `simulator/`                  | The transaction-simulator scenario JSON.                                                                                                                                            |

Not committed (git-ignored): `prepare/` (per-run Safe bundles + manifest), `fork-rehearsal/`,
`anvil.log`, `sepolia-deploy-executed.json`, `manifest-deployer-only.json`.

## The governance ceremony

Decoded from `ecosystem.toml`. Every call is executed by the PUH.

**Stage 0** — 2 calls

1. `L1ChainAssetHandler.pauseMigration()`
2. `GovernanceUpgradeTimer.startTimer()` — arms a `governance_upgrade_timer_initial_delay`
   (1200 s) gate

**Stage 1** — 20 calls: `pauseMigration()` re-asserted, 12 × `ProxyAdmin.upgrade(proxy, impl)`
(bridgehub, nullifier, asset router, NTV, message root, CTM deployment tracker, chain asset
handler, chain registration sender, and the CTM-side proxies), `L1Nullifier` +
`L1AssetRouter` `.setL1InteropHandler(...)`, `GovernanceUpgradeTimer.checkDeadline()`,
`UpgradeStageValidator.checkMigrationsPaused()`, and finally on the CTM:
`setDefaultUpgrade(DefaultUpgradeZKsyncOS)`, `setChainCreationParams(...)`,
`setNewVersionUpgrade(cut, 0x1f00000001, ∞, 0x2100000000, ZKsyncOSTestnetVerifier)`.

**Stage 2** — 3 calls: `unpauseMigration()`,
`UpgradeStageValidator.checkProtocolUpgradePresence()`, `.checkMigrationsUnpaused()`.

> **Two upgrade contracts, and they are not interchangeable.** The diamond cut delegates to
> `V32UpgradeZKsyncOS` (`0xe5Ba13e1…`), this release's one-shot payload — it requires a recorded
> priority-op lower bound and a fully executed batch queue. What the CTM _stores_ as its
> `defaultUpgrade` is the generic `DefaultUpgradeZKsyncOS` (`0x7Ce89dd4…`), because that is what
> later upgrades reuse when they need no custom logic (a verifier-only patch, say). Storing the
> one-shot contract there would make every such upgrade revert on preconditions that only ever
> held during v31 -> v33.

> **Stages 0 and 1 are two separate ceremonies, ≥ 20 minutes apart.** Stage 0 arms the
> `GovernanceUpgradeTimer`; stage 1's `checkDeadline()` only passes once `INITIAL_DELAY` has
> elapsed. They cannot be replayed on one anvil fork — the simulator scenario handles this
> with a `timeIncrease` field, which is why the simulator, not `ecosystem
upgrade-governance`, is the validation path for this artifact.

After stage 2 the per-chain diamond cuts follow (`chain upgrade`, one bundle per chain,
preceded by `chain record-priority-op-lower-bound` and `chain set-upgrade-timestamp`);
those are per-chain-admin actions and are not part of this ecosystem artifact.

## Deployed contracts

The 30 new L1 contracts in `extra-verification-logs.txt` are **live on Sepolia** and
**source-verified on Etherscan**. They were deployed by the deployer bundle described under
"Camp A / Camp B" below — 32 transactions, ~72.4M gas total, whose hashes are in
`transactions.txt`.

Deploying them does not change the ecosystem: they are inert CREATE2 deployments until the
governance ceremony points the proxies at them. Nothing in `transactions.txt` touches live
state.

## Validation

| check                                                                                | result                                                               |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| Fork rehearsal — every prepare bundle replayed under impersonation on a Sepolia fork | 33/33 txs pass                                                       |
| Simulator scenario — all 26 txs against a Sepolia fork                               | 26/26 pass                                                           |
| `setNewVersionUpgrade` args                                                          | `0x1f00000001 -> 0x2100000000`, verifier = `ZKsyncOSTestnetVerifier` |
| `setChainCreationParams` `zkTokenAssetId`                                            | byte-identical to the live v31 value                                 |
| Etherscan verification                                                               | 30/30                                                                |

### Two scenario files

| file                     | contents                                                                                                                 | produced by                                                                            |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `…-1-ecosystem.json`     | Camp-B ChainAdmin bundle, governance stages 0/1/2, `test_create_chain_zkos`, and an `ack_test_upgrade_chain_zkos` marker | `ecosystem governance-toml-to-simulator --ack test_upgrade_chain_zkos`                 |
| `…-2-chain-8022833.json` | `set-upgrade-timestamp` then the diamond cut, for one chain                                                              | `chain set-upgrade-timestamp` + `chain upgrade`, via `ecosystem manifest-to-simulator` |

The transaction-simulator shares **one fork across every scenario file** and walks them in
alphabetical order, so the chain file runs on the state the ecosystem file left behind. Hence
the `-1-` / `-2-` prefixes: sorted the other way the chain file would revert, because
`ServerNotifier.setUpgradeTimestamp` requires `ctm.upgradeCutHash(oldVersion)` to exist and only
stage 1 puts it there.

### Why the per-chain upgrade is not in the artifact

Earlier releases had the CTM prepare emit a `test_upgrade_chain` smoke call into
`[test_upgrade_calls]`, and the simulator scenario carried it. v33 opts out
(`CTMUpgrade_v33.TESTONLY_emitsTestUpgradeChainCall() == false`).

A single generated call cannot stand for this release's per-chain upgrade. `V32UpgradeZKsyncOS`
requires a **recorded priority-op lower bound** and **all batches executed**, and the real
rollout sets an upgrade timestamp first. Emitting one call would either revert or — worse — pass
while silently skipping the preconditions. So the artifact says nothing about it, and
`protocol_ops chain upgrade` produces the real per-chain bundle as its own scenario.

The ecosystem scenario then carries `ack_test_upgrade_chain_zkos`: an empty-calldata marker
recording that the per-chain upgrade is deliberately elsewhere. The transaction-simulator's
provenance check validates the claim rather than trusting it — the acknowledged tag must be a
real checked tag, it must genuinely not be derivable from the TOML (so an ack can never hide a
dropped transaction), and the calldata must be exactly `0x`. The simulator skips it at replay
and re-checks the calldata rule there.

### Preconditions that live on chain, not in the calldata

`PriorityOpLowerBound.lowerBoundPriorityOp(chain)` must have been called for a chain before it
can take the cut. It is permissionless and first-call-wins, and pinning it while the chain's
priority queue is drained fixes a bound that `firstUnprocessed` already satisfies — and only
ever grows past. This has been done on Sepolia for all 9 eligible chains.

Eligibility is `baseTokenSupportsTotalSupply()`, which is true for exactly the 9 ZKsync OS chains
already on v31. The other 16 are still on v29/v30, where the getter does not exist, and **cannot
take this upgrade at all** until they go to v31 first.

The cut also needs all batches executed. A live chain normally has a few committed-but-unexecuted
batches, so the scenario carries `emulateAllBatchesExecuted`; a real rollout waits for them.

## PUVT: not yet green for v33

`regen-upgrade-calldata.sh` runs `ecosystem verify-upgrade` as its last step, but **PUVT does
not pass for this artifact yet.**

The module is named `upgrade_verification/versions/v31/`, which reads as "a verifier for v31"
— it is not. It is the verifier for the upgrade _out of_ v31, written while this release was
still numbered v32, and it says so: `EXPECTED_NEW_PROTOCOL_VERSION_STR = "0.32.0"` against a
genesis that now declares `0.33.0`. So it targets this release; it just has not been carried
across the v32 -> v33 renumbering, and it still assumes the shape v31 stage/mainnet had.

Nine assumptions have been fixed (see the commit that renamed the module and the one after it);
PUVT now runs from config load through to stage-1 call verification with 68 checks passing. Two
classes remain, and neither is more of the same:

**1. The bytecode registry and the deployment are built under different profiles.** Provenance
matches a deploy by hashing its creation code and looking it up in `AllContractsHashes.json`.
The artifact is built under `FOUNDRY_PROFILE=anvil-interop` (`cbor_metadata = false`) so CREATE2
addresses are reproducible across machines; `AllContractsHashes.json` is generated under the
default profile, _with_ metadata. For `L1Bridgehub` the deployed runtime is 18824 bytes and the
registry records 18878 — a 54-byte CBOR blob — so no deployment ever matches and all 29 land as
"not present in the create2 deployments". Reconciling this is a decision, not a patch:

- regenerate the registry under `anvil-interop` (but `check-hashes` CI builds the default
  profile), or
- deploy from a default-profile build (but then CREATE2 addresses stop being reproducible,
  which is the entire reason `anvil-interop` exists), or
- teach the matcher to compare metadata-stripped creation code (weakens the check slightly,
  changes bytecode provenance tool-wide).

**2. The stage-0/1/2 expected-call tables still describe v31's ceremony.** Stage 1 expects
`transparent_proxy_admin.upgrade(...)` at call #0 where v33 has `pauseMigration()`,
`upgradeAndCall` where v33 uses `upgrade`, and a `ChainRegistrationSender.acceptOwnership()` v33
does not emit; it has no notion of `setDefaultUpgrade` at all. This is a rewrite of the
expectation tables against v33's actual 2/20/3-call shape, not a set of small gates.

Until both are addressed, validation rests on the fork rehearsal (every prepare bundle
replayed under impersonation) and the simulator scenario (every governance call executed
against a Sepolia fork). Use `SKIP_PUVT=1` to stop before the failing step.

## Reproducing

```bash
# 0. Toolchain: foundry-zksync v0.1.5 (.github/actions/install-zksync-foundry) on PATH,
#    plus `cd protocol-ops && cargo build --release`.
#    Build with the DEFAULT profile — see "Why the default profile" below. Do NOT set
#    FOUNDRY_PROFILE=anvil-interop here, even though other anvil-interop tooling does.
yarn da build:foundry && yarn sc build:foundry && yarn l1 build:foundry

# 1 + 2. Prepare against a Sepolia fork, then rehearse the bundles on it.
cd l1-contracts/test/anvil-interop
DEPLOYER_PK_FILE=<path> L1_FORK_URL="$SEPOLIA_RPC" ./regen-upgrade-calldata.sh testnet

# 3. Broadcast the DEPLOYER bundle (Camp A) to real Sepolia. Filter the manifest first —
#    upgrade-broadcast wants a --key per distinct signer, and the other bundle is signed by
#    an EOA we do not hold. Idempotent: re-run to resume, deployed CREATE2 targets are skipped.
protocol_ops ecosystem upgrade-broadcast \
  --manifest <out>/prepare/manifest-deployer-only.json \
  --l1-rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --key "0x<deployer>=0x<key>" --out <out>/sepolia-deploy-executed.json

# 4. Emit the simulator scenario + the committed sim-inputs.
protocol_ops ecosystem governance-toml-to-simulator --env testnet \
  --camp-a-signers 0x<deployer> --skip-test-upgrade-calls \
  --out <out>/simulator/<date>-v33-atomic-interop-testnet.json
protocol_ops ecosystem governance-toml-to-simulator --env testnet \
  --camp-a-signers 0x<deployer> --emit-sim-inputs <out>/sim-inputs

# 5. Rehearse the scenario (forks Sepolia; needs the step-3 deploys to be on chain).
yarn --cwd <transaction-simulator> simulate --file <scenario.json>
```

### Why the default profile

`anvil-interop` sets `cbor_metadata = false`, stripping the trailing metadata blob so CREATE2
addresses come out identical on any machine. This artifact deliberately does **not** use it.

PUVT resolves each deployment by hashing its creation code and looking the hash up in
`AllContractsHashes.json`, which is generated under the default profile. A metadata-stripped
build is ~54 bytes shorter per contract (measured on `L1Bridgehub`: 18824 vs 18878), so no
deployment ever matches and provenance reports every contract as "not present in the create2
deployments" — the check silently verifies nothing.

The cost is that CREATE2 addresses now depend on the metadata hash, which embeds source paths.
A reviewer re-running the prepare from a different checkout path will get **different
addresses**. Verify the artifact by its contents and by the on-chain deployments listed in
`transactions.txt`, not by diffing addresses against your own run.

### Salts must be rotated per regen

`[contracts] create2_factory_salt` and the `[create2_factory_salts]` entry in
`../../testnet.toml` were minted fresh for this run. CREATE2 returns the _previously
deployed_ contract for a repeated (salt, initcode) pair, so a regen that reuses a salt
silently keeps old bytecode. Mint new ones before re-running:

```bash
python3 -c "import secrets; print('0x'+secrets.token_hex(32))"
```

## Camp A / Camp B

Every tx in the prepare has a signer, and there are exactly two camps:

- **Camp A — we hold the key.** The deployer EOA's bundle (32 CREATE2 deploys +
  `BytecodesSupplier.publishBytecodes`). Broadcast to real Sepolia in step 3; **never** put
  into the simulator scenario, whose fork inherits the effect from chain tip. Re-running it
  there fails with `AddressAlreadySet(...)`.
- **Camp B — we do not hold the key.** Here: one `ChainAdmin.multicall` from
  `0x5555555590930f501c88B73Ea43B3EEb5A71643c` (owner of the CTM admin
  `0x7cbdDA00285de05a1353803db38770043e359B6d`) wrapping
  `ProxyAdmin.upgrade(serverNotifierProxy, newImpl)`. It goes into the scenario with
  `from = bundle.target`, and the simulator impersonates it.
