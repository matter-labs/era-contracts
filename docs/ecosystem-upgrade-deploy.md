# Ecosystem upgrade: generate → deploy

> **Scope.** The v0.35.0 upgrade, `upgrade-envs/v0.35.0-upgrade-system/`: the default `upgrade` of
> the generate workflow and of `rehearse-upgrade`, and the only directory that may use
> `prepare = "prepare-all"`. The v31 rollout (PUVT, `ecosystem verify-upgrade`,
> `upgrade-envs/v0.31.0-interopB/`) is run from the `draft-v31` branch and its copy of this guide.

The ecosystem upgrade is produced and shipped in **two steps**, each runnable
locally and in CI:

1. **Generate the calldata** — deploy nothing; on a fork, compute the upgrade
   artifacts (`ecosystem.toml`, `sim-inputs/`, `transaction-simulator.json`) and
   the _deployer bundles_ that step 2 will broadcast.
2. **Deploy** — broadcast the deployer bundles to a real L1, producing
   `transactions.txt`, then verify the deployed contracts on Etherscan.

The same `protocol_ops` binary drives both locally and in CI — CI is only a
wrapper around the commands below.

**Step 1 output is a handoff, not a recipe.** Solidity output is not byte-stable
across build environments (the default foundry profile embeds path-dependent CBOR
metadata), so the bytecode — and therefore every CREATE2 address and all the
governance calldata — belongs to the machine that compiled it. Re-running step 1
somewhere else does not "reproduce" the addresses; it produces a different,
equally valid upgrade. What travels is the **deploy bundle**: the deployer
transactions carry the CREATE2 init code verbatim, so whoever broadcasts them
deploys that exact bytecode at the addresses the reviewed `ecosystem.toml` names,
without compiling anything. See
[Deploying + verifying from a deploy bundle](#deploying--verifying-from-a-deploy-bundle).

```
             ┌────────────────────── step 1: GENERATE (fork) ──────────────────────┐
 fork L1 ──▶ upgrade-prepare-all ──▶ ecosystem.toml + prepare/ bundles + verify log
                     │                         │
                     ▼                         ▼
             governance-toml-to-simulator   (deployer bundles = manifest targets == deployer)
                     │
                     ▼
             sim-inputs/ + transaction-simulator.json
             ┌────────────────────── step 2: DEPLOY (real L1) ─────────────────────┐
 prepare/ bundles ──▶ upgrade-broadcast (deployer key, --skip-unkeyed) ──▶ transactions.txt
                                          │
                                          ▼
                              forge verify-contract (Etherscan)
```

Then `ecosystem verify-bootstrap` (the registry verifier) holds `ecosystem.toml`
against the on-chain result before governance signs (step 3).

---

## Step 1 — generate the calldata

**What it does.** Forks L1, runs `upgrade-prepare-all` (deploys every new
ecosystem contract _on the fork_ to compute deterministic CREATE2 addresses),
replays the prepare bundles, runs `verify-bootstrap`, and emits the git-portable calldata set.
Nothing touches real L1 — the deployer is impersonated.

**Outputs** (under `l1-contracts/upgrade-envs/v0.35.0-upgrade-system/output/<env>/`):

| Artifact                                        | Purpose                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| `ecosystem.toml`                                | merged addresses + the governance bundle (verifier input)          |
| `sim-inputs/`                                   | Camp-B manifest + bundles for the transaction simulator            |
| `transaction-simulator.json`                    | ready-to-paste simulator input (Camp-B + governance + smoke tests) |
| `prepare/manifest.json` + `prepare/*.safe.json` | **the bundles step 2 broadcasts**                                  |
| `extra-verification-logs.txt`                   | `forge verify-contract` commands for step 2                        |
| `deploy-bundle/`                                | the above, packed with provenance for handoff (see below)          |

**Locally:**

```bash
# 1a) fork + prepare + verify-bootstrap (writes ecosystem.toml + prepare/ + extra-verification-logs.txt)
# Build with the upstream Foundry pinned in .github/foundry-versions.env (AGENTS.md).
yarn && yarn l1 build:foundry
cd protocol-ops && cargo build --release && cd ..
./protocol-ops/target/release/protocol_ops ecosystem rehearse-upgrade --env mainnet \
  --fork-url <l1-rpc> --deployer-address <deployer-eoa>

# 1b) emit the sim-inputs + transaction-simulator.json
OUT=l1-contracts/upgrade-envs/v0.35.0-upgrade-system/output/mainnet
./protocol-ops/target/release/protocol_ops ecosystem governance-toml-to-simulator \
  --env mainnet --include-manifest "$OUT/prepare/manifest.json" \
  --camp-a-signers <deployer-eoa> --emit-sim-inputs "$OUT/sim-inputs"
./protocol-ops/target/release/protocol_ops ecosystem governance-toml-to-simulator \
  --env mainnet --out "$OUT/transaction-simulator.json"
```

A zk-governance checkout (`ZK_GOVERNANCE_DIR`, `--zk-governance-commit`) is needed only by a
release whose input declares `redeploy_zk_governance = true`; no v0.35.0 input does.

**In CI:** run the **`Ecosystem Upgrade Calldata: Regenerate + Verify`**
workflow (`generate-ecosystem-upgrade-calldata.yaml`). It does 1a + 1b and
uploads two artifacts: `ecosystem-upgrade-calldata-<env>` (the review set) and
`ecosystem-upgrade-deploy-inputs-<env>` (the deploy bundle for step 2 / for a
local deploy + verify). Its second job, `verify-bundle-handoff`, then re-deploys
and re-verifies that bundle from scratch with nothing but the artifact and a
contract build of the commit it names (the verifier needs the creation code),
which is the standing proof that the artifact is self-sufficient.

### Which ecosystems this runs for

`environment` is just the basename of a config pair — `permanent-values/<env>.toml`
plus `v0.35.0-upgrade-system/<env>.toml` — and the L1 to fork is read from that env's
`l1_chain_id` (`1` → mainnet, `11155111` → Sepolia). Adding an ecosystem therefore
needs no workflow edit: commit the config pair, add its anvil port to
`ENV_ANVIL_PORTS` in `protocol-ops/src/commands/ecosystem/bundle.rs` if it needs its own fork. The
verifier takes its reviewer inputs from the env config (the upgrade input's `owner_address` and
CREATE2 salts, the permanent values' `bridgehub_proxy_addr`, the reviewed Bridgehub, and
`zk_token_asset_id`), so the env must declare them. Committed today: `stage`, `testnet`,
`mainnet`. The check must pass for both the generate job and the independent bundle-handoff
verification job.

`adi` (single-chain ZKsync OS on L1 mainnet, owned by a legacy `Governance.sol` with a real
security council and a three-day `minDelay()`) has a v31 config pair
(`v0.31.0-interopB/adi.toml`) and none for v0.35.0 yet.

> **Already-deployed ecosystems.** Re-running the prepare against the chain tip
> of an ecosystem whose upgrade is already live reverts (the deployer no
> longer owns the ecosystem contracts). Pass `fork_block` = a block _before_ the
> deployment; CREATE2 addresses are deterministic, so the output is identical.

---

## Step 2 — deploy (broadcast) + verify

**What it does.** Broadcasts **only the deployer bundles** (the ones whose
`manifest.bundles[].target` is the deployer EOA) to a real L1 — the legacy-Gov /
ProtocolUpgradeHandler (Camp-B) bundles are the governance ceremony and are run
separately by their multisig, so `--skip-unkeyed` drops them. Every deployer tx
is broadcast **one at a time** and confirmed, then the deployed contracts are
verified on Etherscan.

The sender (`submit_and_confirm` in
`protocol-ops/src/commands/dev/execute_safe.rs`) is robust to real-L1 hazards:

- **Stuck (underpriced) tx** — if no receipt lands within ~90s it re-broadcasts
  the _same nonce_ at a higher gas price (+15% per retry, ≥ geth's 10%
  replacement floor), up to `--max-gas-price-gwei`, then keeps trying at the
  ceiling until a 20-minute per-tx deadline.
- **Spent nonce** — if the sender's nonce moves past ours, it keeps asking for
  receipts of every hash it sent at that nonce for ~36s: a load-balanced RPC can
  serve the new nonce before the receipt of our own mined tx. If none of ours
  shows up, the run stops and names those hashes instead of resending, because a
  resend would execute the call twice if one of them did mine. Only a call never
  sent at that nonce (a stale pending nonce) is resent at the next free one.
- **Idempotent** — CREATE2 deploys already on-chain and known already-done
  reverts are skipped, so a re-run after a partial deploy resumes cleanly. A
  `publishEraBytecodes` / `publishEVMBytecodes` batch is skipped only when every
  bytecode in it is published, and an `AddressAlreadySet` only when the address
  already set is the one the call sets. A skipped CREATE2 deploy leaves no
  journal entry (its deployment tx is unknown), so the log names the address: to
  keep the record complete, append its deployment tx hash to `transactions.txt`.

It journals each confirmed receipt immediately: the mined hash is appended to
`transactions.txt` (next to `--out`) and the matching calldata is atomically
recorded in `deploy-executed.json`. Both files are loaded and extended on a
retry, so a later failure cannot erase the record of earlier transactions. The
journal is the operational record of the broadcast; the verifier does not read it.

**Locally** (real signing — needs the deployer key). Sign only from a checkout at the
bundle's `contracts_commit`, built, after holding every deployer call against that checkout
([Deployer signing](upgrade-operations.md#deployer-signing)). `replay-bundle --key` runs the
commit check, the plan check and the broadcast as one command
([below](#deploying--verifying-from-a-deploy-bundle)); the separate steps, Etherscan included, are:

```bash
BUNDLE=<absolute path of the unpacked deploy bundle>
git checkout "$(jq -r .contracts_commit "$BUNDLE/bundle-metadata.json")"
# Recursive, as AllContractsHashes.json was built: nested remappings are in the metadata.
git submodule update --init --recursive
yarn && yarn l1 build:foundry
cd protocol-ops && cargo build --release && cd ..

# Hold every deployer call against this checkout before the key signs anything.
./protocol-ops/target/release/protocol_ops ecosystem check-deployer-plan --bundle "$BUNDLE"

# Broadcast the deployer bundles → writes ./deploy-result/transactions.txt, this
# deployment's journal. Keep it out of the env's output directory: the committed
# transactions.txt there also holds earlier broadcasts.
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
./protocol-ops/target/release/protocol_ops ecosystem upgrade-broadcast \
  --manifest "$BUNDLE/prepare/manifest.json" \
  --l1-rpc-url <l1-rpc> \
  --key "${DEPLOYER_ADDR}=${DEPLOYER_KEY}" \
  --skip-unkeyed \
  --max-gas-price-gwei 500 \
  --out ./deploy-result/deploy-executed.json

# Verify on Etherscan. Step 1 logged `forge verify-contract <address> <Contract>
# [--constructor-args <hex>]` for every contract, from the CREATE2 init code it
# deployed, so nothing is guessed. Each line is parsed and its fields passed to
# forge as arguments, never evaluated; a line of any other shape is not run.
cd l1-contracts
export ETHERSCAN_API_KEY   # forge reads it from the env
verify_line='^forge verify-contract (0x[0-9a-fA-F]{40}) ([A-Za-z_][A-Za-z0-9_]*)( --constructor-args (0x[0-9a-fA-F]*))?$'
grep 'forge verify-contract' "$BUNDLE/extra-verification-logs.txt" |
  sed 's/^.*forge verify-contract/forge verify-contract/' | sort -u |
  while IFS= read -r line; do
    if [[ ! "$line" =~ $verify_line ]]; then
      echo "not run: $line"
      continue
    fi
    args=(verify-contract "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
    if [ -n "${BASH_REMATCH[3]}" ]; then
      args+=(--constructor-args "${BASH_REMATCH[4]}")
    fi
    forge "${args[@]}" --chain mainnet --watch --retries 8 --delay 20 || true
  done
```

**In CI:** run the **`Ecosystem Upgrade: Deploy + Verify`** workflow
(`deploy-ecosystem-upgrade.yaml`) with `generate_run_id` = the step-1 run to pull
the deploy bundle from. It uploads `transactions.txt` as
`ecosystem-upgrade-deploy-result-<env>`. The selected generation run must be a
successful manual run of `generate-ecosystem-upgrade-calldata.yaml`, and its
`verify-bundle-handoff` job must have succeeded. The downloaded bundle's strict
metadata must also identify that exact run, commit, and environment; diagnostic
artifacts from failed generation runs and metadata-free legacy bundles are
rejected before any secret is selected.

Dispatch the workflow on a branch whose head is the bundle's `contracts_commit`:
the provenance step refuses a run that checked out any other commit. Before any
step reads the deployer key, the job builds the contracts from that checkout and
runs `protocol_ops ecosystem check-deployer-plan --bundle` against it
([Deployer signing](upgrade-operations.md#deployer-signing)).

Which L1 it signs against comes from the bundle's `bundle-metadata.json`
(`l1.chain_id`), **not** from the `environment` name: chain ID `1` uses
`L1_RPC_URL_MAINNET` + `DEPLOYER_PRIVATE_KEY_MAINNET`, while `11155111` uses the
`_SEPOLIA` pair. Before exporting either secret to later steps, the job requires
`cast chain-id` against that RPC to equal the bundle's chain ID. It also refuses
to start if the key's address isn't the deployer the bundle was prepared for,
since `--skip-unkeyed` would otherwise drop every bundle and report success
having deployed nothing. `ETHERSCAN_API_KEY` is optional (verify only).

> A single deployer bundle can revert mid-way (e.g. RPC 429). The broadcast is
> idempotent, so retry it with the same journal — already-deployed /
> already-transferred txs are skipped and it resumes. Locally, reuse the same
> `--out` path. In CI, dispatch a new deploy run with `resume_deploy_run_id` set
> to the failed deploy run; the workflow validates and restores that run's
> partial result artifact before broadcasting. Do not use GitHub's plain
> “re-run failed jobs” button, which cannot add the resume input.
>
> With a journal, a resume skips every call the journal proves already mined —
> matched on target, calldata and value, then confirmed by the on-chain
> receipt's sender, target and status — so ownership transfers that already
> moved off the deployer are skipped too, not re-sent into a revert. Without a
> journal only CREATE2 deploys whose address has code and a few revert
> signatures (already-published bytecodes, already-scheduled governance ops)
> are skipped.
>
> The same mechanism completes a **re-cut** deployment: when contracts changed
> after a partial or full broadcast, regenerate the bundle (forking BEFORE the
> earlier broadcast, so the prepare still owns what it deploys) and dispatch
> the deploy with `resume_deploy_run_id` = the earlier deploy run and
> `resume_from_other_bundle` = true. Unchanged contracts and their setup calls
> are byte-identical to the journaled ones and are skipped; only the changed
> contracts, their setup calls and new bytecode publishes go out.

---

## Step 3 — verify the deployment (`verify-bootstrap`)

Run it after step 2 and before governance signs: it is a pre-execution check. It
needs the contracts built from the commit `bundle-metadata.json` names, because it
re-derives every object from the reviewed creation code in `l1-contracts/out` and
holds that build against the commit's `AllContractsHashes.json`:

```bash
yarn && yarn l1 build:foundry
cd protocol-ops && cargo build --release && cd ..
./protocol-ops/target/release/protocol_ops ecosystem replay-bundle \
  --bundle <unpacked-bundle-dir> --rpc <l1-rpc> --verify-only
```

`replay-bundle` runs `ecosystem verify-bootstrap` on the bundle's `ecosystem.toml`
with the reviewer inputs the env config supplies: the reviewed Bridgehub (the permanent values'
`bridgehub_proxy_addr`), the expected governance owner (the upgrade input's `owner_address`) and
the CREATE2 salts (its core and per-CTM salts). A bootstrap package carries the records of the executors it drives; a
recurring upgrade's executors were deployed by `ecosystem init` / `ctm init`, so
pass those runs' outputs with `--executor-record`. `ecosystem verify-bootstrap`
takes the same inputs as flags when run on its own (see `protocol-ops/README.md`).

No receipt journal is involved: the verifier re-derives each CREATE2 address from
the reviewed creation code and salts rather than resolving deployments from
broadcast receipts, so it verifies anyone's broadcast from the bundle alone.

---

## Deploying + verifying from a deploy bundle

A generation run packs `output/<env>/deploy-bundle/` (uploaded by CI as
`ecosystem-upgrade-deploy-inputs-<env>`). It is the unit of handoff between the
machine that compiled the upgrade and whoever deploys or audits it:

| File                          | Why it is in there                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `prepare/manifest.json`       | the bundles, in execution order, each with its signer (`target`)                                                       |
| `prepare/*.safe.json`         | the calls themselves — `to`/`value`/`data`, CREATE2 init code included                                                 |
| `ecosystem.toml`              | the resulting addresses + the governance bundle's calldata                                                             |
| `bundle-metadata.json`        | provenance (commit, hashes digest, fork block, deployer, toolchain) plus the SHA-256 of every other file in the bundle |
| `extra-verification-logs.txt` | `forge verify-contract` commands, constructor args included                                                            |

**The broadcasting EOA must be the bundle's `deployer_address`.** The deployer is
not just the fork-rehearsal signer: it is the `from` of every deployer transaction, and a release
may pass it into init code, which makes those contracts' CREATE2 addresses a function of it.
Broadcasting with a different EOA puts those contracts at different addresses while
`ecosystem.toml` and the governance calldata still name the original ones — a
silently broken upgrade. The bundle records the deployer as `deployer_address` in
`bundle-metadata.json`; `replay-bundle --key` and `deploy-ecosystem-upgrade.yaml` both
refuse a key for any other account. Generate with the EOA that will deploy; never with
a placeholder.

Both the replay command and the deploy workflow verify every file digest in the
metadata, and that every bundle file the manifest names is covered, before sending
any transaction.

**Check out and build the commit `bundle-metadata.json` names.** `verify-bootstrap`
re-derives every object from the local build's creation code, holds that build
against the committed `AllContractsHashes.json` and identifies deployed code
against the same file; from a different commit the deployments are not recognised
and the verdict is meaningless. `replay-bundle` compares the file's hash with the
bundle's and exits on a mismatch.

**Rehearse the deploy and verify it — no regeneration:**

```bash
yarn && yarn l1 build:foundry   # the verifier reads l1-contracts/out
cd protocol-ops && cargo build --release && cd ..
./protocol-ops/target/release/protocol_ops ecosystem replay-bundle \
  --bundle <unpacked-bundle-dir> --fork-url <l1-rpc>
```

That forks L1 at the bundle's recorded height, funds every bundle signer, replays
all the manifest's bundles under impersonation and runs `ecosystem verify-bootstrap`
against the result.

Variants:

```bash
# verify a chain the bundle was already broadcast to (no replay)
./protocol-ops/target/release/protocol_ops ecosystem replay-bundle \
  --bundle <dir> --rpc <l1-rpc> --verify-only

# broadcast the deployer bundles for real, then verify
./protocol-ops/target/release/protocol_ops ecosystem replay-bundle \
  --bundle <dir> --rpc <l1-rpc> --key "$DEPLOYER_KEY"
```

`--key` signs only the deployer's bundles (`--skip-unkeyed`); the governance
ceremony bundles stay for their multisig. Same broadcast path, and same
idempotency, as step 2 above. `replay-bundle` writes its own state (`executed.json`
and the receipts in `transactions.txt`) to
`l1-contracts/upgrade-envs/v0.35.0-upgrade-system/output/<env>/replay/`, never into the
bundle directory.

Both `--rpc` modes first read `eth_chainId` and require it to equal the bundle's
recorded `l1.chain_id`, and refuse to continue otherwise. That check matters most
for `--key`: the deployer address is baked into some init code, so the same key is
valid on every chain, and a wrong `--rpc` would otherwise receive real, correctly
signed transactions.
