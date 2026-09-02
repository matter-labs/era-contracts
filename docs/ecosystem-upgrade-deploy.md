# v31 ecosystem upgrade: generate → deploy

The v31 ecosystem upgrade is produced and shipped in **two steps**, each runnable
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

Then `ecosystem verify-upgrade` (PUVT) consumes `ecosystem.toml` +
`transactions.txt` to check the on-chain result.

---

## Step 1 — generate the calldata

**What it does.** Forks L1, runs `upgrade-prepare-all` (deploys every new
ecosystem contract _on the fork_ to compute deterministic CREATE2 addresses),
replays the prepare bundles, runs PUVT, and emits the git-portable calldata set.
Nothing touches real L1 — the deployer is impersonated.

**Outputs** (under `l1-contracts/upgrade-envs/v0.31.0-interopB/output/<env>/`):

| Artifact                                        | Purpose                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| `ecosystem.toml`                                | merged addresses + governance stage 0/1/2 calls (PUVT input)       |
| `sim-inputs/`                                   | Camp-B manifest + bundles for the transaction simulator            |
| `transaction-simulator.json`                    | ready-to-paste simulator input (Camp-B + PUH stages + smoke tests) |
| `prepare/manifest.json` + `prepare/*.safe.json` | **the bundles step 2 broadcasts**                                  |
| `extra-verification-logs.txt`                   | `forge verify-contract` commands for step 2                        |
| `deploy-bundle/`                                | the above, packed with provenance for handoff (see below)          |

**Locally:**

```bash
# 1a) fork + prepare + PUVT (writes ecosystem.toml + prepare/ + extra-verification-logs.txt)
export PATH="$PWD/foundry-zksync:$PATH"          # foundry-zksync v0.1.5
DEPLOYER_ADDR=<deployer-eoa> \
L1_FORK_URL=<l1-rpc> GW_RPC_URL=<l1-rpc> \
ZK_GOVERNANCE_COMMIT=9b06a16 \
  ./l1-contracts/test/anvil-interop/regen-and-verify.sh mainnet

# 1b) emit the sim-inputs + transaction-simulator.json
OUT=l1-contracts/upgrade-envs/v0.31.0-interopB/output/mainnet
./protocol-ops/target/release/protocol_ops ecosystem governance-toml-to-simulator \
  --env mainnet --include-manifest "$OUT/prepare/manifest.json" \
  --camp-a-signers <deployer-eoa> --emit-sim-inputs "$OUT/sim-inputs"
./protocol-ops/target/release/protocol_ops ecosystem governance-toml-to-simulator \
  --env mainnet --out "$OUT/transaction-simulator.json"
```

**In CI:** run the **`Ecosystem Upgrade Calldata: Regenerate + Verify (v31)`**
workflow (`generate-ecosystem-upgrade-calldata.yaml`). It does 1a + 1b and
uploads two artifacts: `ecosystem-upgrade-calldata-<env>` (the review set) and
`ecosystem-upgrade-deploy-inputs-<env>` (the deploy bundle for step 2 / for a
local deploy + PUVT). Its second job, `verify-bundle-handoff`, then re-deploys
and re-verifies that bundle from scratch **with no contract build**, which is the
standing proof that the artifact is self-sufficient.

### Which ecosystems this runs for

`environment` is just the basename of a config pair — `permanent-values/<env>.toml`
plus `v0.31.0-interopB/<env>.toml` — and the L1 to fork is read from that env's
`l1_chain_id` (`1` → mainnet, `11155111` → Sepolia). Adding an ecosystem therefore
needs no workflow edit: commit the config pair, add its anvil port to
`env_anvil_port` in `upgrade-bundle-lib.sh` if it needs its own fork, and (if PUVT
should accept it) a variant in `VerifyUpgradeEnv`. Committed today: `stage`,
`testnet`, `mainnet`. PUVT must pass for both the generate job and the independent
bundle-handoff verification job.

> **Already-deployed ecosystems.** Re-running the prepare against the chain tip
> of an ecosystem whose v31 upgrade is already live reverts (the deployer no
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
- **Nonce takeover** — if the sender's on-chain nonce advances past ours without
  our tx landing (some other tx grabbed the nonce), it re-fetches the next free
  nonce and resubmits our calldata there.
- **Idempotent** — CREATE2 deploys already on-chain and known already-done
  reverts are skipped, so a re-run after a partial deploy resumes cleanly.

It appends each mined hash to `transactions.txt` (next to `--out`), which is what
PUVT reads.

**Locally** (real signing — needs the deployer key):

```bash
OUT=l1-contracts/upgrade-envs/v0.31.0-interopB/output/mainnet
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")

# Broadcast the deployer bundles → writes $OUT/transactions.txt
./protocol-ops/target/release/protocol_ops ecosystem upgrade-broadcast \
  --manifest "$OUT/prepare/manifest.json" \
  --l1-rpc-url <l1-rpc> \
  --key "${DEPLOYER_ADDR}=${DEPLOYER_KEY}" \
  --skip-unkeyed \
  --max-gas-price-gwei 500 \
  --out "$OUT/deploy-executed.json"

# Verify on Etherscan — replay the logged forge verify-contract commands VERBATIM.
# Step 1 already wrote the exact `--constructor-args <hex>` for every contract
# (from the CREATE2 init code it deployed), so nothing is guessed.
cd l1-contracts
export ETHERSCAN_API_KEY   # forge reads it from the env
grep 'forge verify-contract' \
    "upgrade-envs/v0.31.0-interopB/output/mainnet/extra-verification-logs.txt" | sort -u |
  while IFS= read -r cmd; do
    cmd="forge verify-contract${cmd#*forge verify-contract}"
    eval "$cmd --chain mainnet --watch --retries 8 --delay 20" || true
  done
```

**In CI:** run the **`Ecosystem Upgrade: Deploy + Verify (v31)`** workflow
(`deploy-ecosystem-upgrade.yaml`) with `generate_run_id` = the step-1 run to pull
the deploy bundle from. It uploads `transactions.txt` as
`ecosystem-upgrade-deploy-result-<env>`.

Which L1 it signs against comes from the bundle's `bundle-metadata.json`
(`l1.chain_id`), **not** from the `environment` name: chain ID `1` uses
`L1_RPC_URL_MAINNET` + `DEPLOYER_PRIVATE_KEY_MAINNET`, while `11155111` uses the
`_SEPOLIA` pair. The job also refuses to start if the key's address isn't the
deployer the bundle was prepared for, since `--skip-unkeyed` would otherwise drop
every bundle and report success having deployed nothing. `ETHERSCAN_API_KEY` is
optional (verify only).

> A single deployer bundle can revert mid-way (e.g. RPC 429). The broadcast is
> idempotent, so just re-run it — already-deployed / already-transferred txs are
> skipped and it resumes. Ownership-transfer txs are **not** idempotent-skipped,
> so if a bundle was interrupted after some ownership moved off the deployer, see
> the notes in `execute_safe.rs` for building a resume bundle.

---

## Step 3 — verify the deployment (PUVT)

```bash
OUT=l1-contracts/upgrade-envs/v0.31.0-interopB/output/mainnet
./protocol-ops/target/release/protocol_ops ecosystem verify-upgrade \
  --env mainnet \
  --ecosystem-toml "$OUT/ecosystem.toml" \
  --transactions-log "$OUT/transactions.txt" \
  --l1-rpc-url <l1-rpc> --gw-rpc-url <l1-rpc> \
  --zk-governance-commit 9b06a16
```

Pre-governance (contracts deployed, governance not yet executed) this reports the
allowed exemptions for contracts still owned by the legacy Governor pending their
ceremony; everything else must be clean.

---

## Deploying + verifying from a deploy bundle

A generation run packs `output/<env>/deploy-bundle/` (uploaded by CI as
`ecosystem-upgrade-deploy-inputs-<env>`). It is the unit of handoff between the
machine that compiled the upgrade and whoever deploys or audits it:

| File                          | Why it is in there                                                     |
| ----------------------------- | ---------------------------------------------------------------------- |
| `prepare/manifest.json`       | the bundles, in execution order, each with its signer (`target`)       |
| `prepare/*.safe.json`         | the calls themselves — `to`/`value`/`data`, CREATE2 init code included |
| `ecosystem.toml`              | the resulting addresses + governance stage 0/1/2 calldata              |
| `bundle-metadata.json`        | provenance plus SHA-256 for every executable/supporting bundle file    |
| `extra-verification-logs.txt` | `forge verify-contract` commands, constructor args included            |
| `README.md`                   | the two commands below, pre-filled for that bundle                     |

**The broadcasting EOA must be the bundle's `deployer_address`.** The deployer is
not just the fork-rehearsal signer: the prepare passes it as the initial owner of
two proxies (`initialize(deployer)`) and to `ZKsyncOSDualVerifier`'s constructor, so
it sits in their init code and their CREATE2 addresses are a function of it.
Broadcasting with a different EOA puts those contracts at different addresses while
`ecosystem.toml` and the governance calldata still name the original ones — a
silently broken upgrade. The bundle lists them under
`deployer_dependent_deployments`, its README repeats the required signer, and
`deploy-ecosystem-upgrade.yaml` refuses to start on a mismatch. Generate with the
EOA that will deploy; never with a placeholder.

Both the replay script and deploy workflow verify the metadata's file digests and
require its bundle list to exactly match `prepare/manifest.json` before sending any
transaction.

**Check out the commit `bundle-metadata.json` names.** PUVT identifies deployed
contracts by matching their code against the committed `AllContractsHashes.json`;
from a different commit the deployments are not recognised and the verdict is
meaningless. `replay-bundle-and-verify.sh` compares the hash and exits on a mismatch.

**Rehearse the deploy and run PUVT — no compiler, no regeneration:**

```bash
cd protocol-ops && cargo build --release && cd ..     # the only build needed
./l1-contracts/test/anvil-interop/replay-bundle-and-verify.sh \
  --bundle <unpacked-bundle-dir> --fork-url <l1-rpc>
```

That forks L1 at the bundle's recorded height, funds every bundle signer, replays
all bundles under impersonation (including the governance ceremony, so PUVT sees
the post-upgrade state) and runs `ecosystem verify-upgrade`.

Variants:

```bash
# verify a chain the bundle was already broadcast to (no replay)
./…/replay-bundle-and-verify.sh --bundle <dir> --rpc <l1-rpc> --verify-only

# broadcast the deployer bundles for real, then verify
./…/replay-bundle-and-verify.sh --bundle <dir> --rpc <l1-rpc> --key "$DEPLOYER_KEY"
```

`--key` signs only the deployer's bundles (`--skip-unkeyed`); the governance
ceremony bundles stay for their multisig. Same broadcast path, and same
idempotency, as step 2 above.

**Pack a bundle by hand** (e.g. from an older generation output):

```bash
DEPLOYER_ADDR=<deployer> FORKED_AT_BLOCK=<block> \
  ./l1-contracts/test/anvil-interop/pack-deploy-bundle.sh <env>
```
