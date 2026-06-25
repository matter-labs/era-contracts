# CI: Regen & Verify Upgrade Calldata (PUVT)

The GitHub Action [`.github/workflows/regen-and-verify-calldata.yaml`](../../../.github/workflows/regen-and-verify-calldata.yaml)
automates what the team does by hand to validate the v31 ecosystem upgrade
calldata: it **redeploys** the upgrade against a fresh anvil fork of the target
L1 and **double-checks** it with PUVT (`protocol_ops ecosystem verify-upgrade`).

It is a thin CI wrapper around the canonical local driver
[`regen-and-verify.sh`](./regen-and-verify.sh) — same script, same gates.

## What it does

1. Builds the contracts (`da` + `l1` with the metadata-free `anvil-interop`
   profile for reproducible EVM addresses, `sc` for the Era-CTM `zkout`) and
   `protocol_ops` **from the checked-out branch** (not a Docker snapshot).
2. Clones `zk-governance` at the pinned commit into the sibling path
   `protocol_ops` expects (`contracts_root/../../zk-governance`) so
   `DeployPUHAndGuardians.s.sol` runs during prepare.
3. Runs `regen-and-verify.sh <env>`: `upgrade-prepare-all` → fund + fork-replay
   the prepare bundles → `verify-upgrade` (PUVT).
4. Emits the git-portable `sim-inputs/` set.
5. Uploads `ecosystem.toml` + `sim-inputs/` + `extra-verification-logs.txt`
   (deliberately **not** `anvil.log`, which can echo the RPC URL) and prints a
   drift diff vs the committed `ecosystem.toml` to the job summary.

The job is **green iff PUVT passes**. A PUVT failure makes the script exit
non-zero → the job is red. That is the automated double-check.

On success, if `open_pr` is set (default), the job commits the regenerated
`ecosystem.toml` + `sim-inputs/` to a new branch and **opens a PR** against the
branch it ran on (override with `pr_base`). The `sim-inputs/` are the
transaction-simulator-compatible bundles, so reviewers see the exact calls in
the PR diff before they go to the simulator. Needs `contents: write` +
`pull-requests: write` (already set on the workflow).

## Running it

Actions tab → "Regen & Verify Upgrade Calldata (PUVT)" → *Run workflow*. Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `environment` | `testnet` | `testnet` / `stage` (both Sepolia) / `mainnet`. |
| `deployer_address` | canonical deployer EOA | Impersonated on the fork (`--unlocked`); **no private key needed**. |
| `zk_governance_commit` | `3e516c5` | Commit whose PUH/Guardians bytecode PUVT verifies. |
| `l1_rpc_url` | *(blank)* | Optional masked RPC override; otherwise the `L1_RPC_URL_*` secret is used. |

## Required repo secrets

| Secret | Used for |
| --- | --- |
| `L1_RPC_URL_SEPOLIA` | testnet + stage forks |
| `L1_RPC_URL_MAINNET` | mainnet fork |

The RPC is `::add-mask::`'d and passed only via `$GITHUB_ENV`. No deployer key
secret is required for the fork rehearsal.

## Dispatchability gate

`workflow_dispatch` workflows can only be triggered once the file lives on the
repo's **default branch**. Until this is merged to `main`, the workflow will not
appear in the Actions dropdown on feature branches.

## Companion: actual deployment

[`.github/workflows/deploy-upgrade-contracts.yaml`](../../../.github/workflows/deploy-upgrade-contracts.yaml)
is the **"Mode 2" real-network deployment** — the one job that uses the deployer
private key to push the new-contract CREATE2 deploys on-chain.

It is deliberately conservative:

1. `workflow_dispatch` only, gated behind a protected `sepolia-deploy`
   GitHub Environment (configure required reviewers in repo Settings → a human
   must approve each run).
2. **Deploy-only-what's-verified:** it first runs the same fork regen + PUVT as
   above; if PUVT is not green it never reaches the broadcast. The bytecode it
   deploys is exactly what was just verified.
3. **Dry run by default** (`dry_run=true`): prints the deployer bundle(s) that
   *would* be sent and stops. To actually deploy, set `dry_run=false` **and**
   type the confirm phrase `DEPLOY-<environment>`.
4. Broadcasts **only the deployer-EOA bundle(s)** (`dev execute-safe`), never the
   governance / multisig bundles (PUH, security council) — those go through the
   governance process. The broadcast is idempotent (already-deployed CREATE2
   addresses are skipped), so a re-run after a partial broadcast is safe.
5. **Pre-flight mempool check:** before broadcasting it asserts the deployer's
   `pending` nonce equals its `latest` nonce — i.e. no in-flight tx. A stuck tx
   at a lower nonce would strand everything sent behind it, so the job fails
   fast with guidance (cancel/replace that nonce, then re-run) instead of
   queueing into a gap.
6. **Gas bid is tunable** via the `gas_price_multiplier` input (default `1.5` =
   150% of the live `eth_gasPrice`); higher lands faster on a busy chain, lower
   risks hanging in the mempool. Threaded into `dev execute-safe
   --gas-price-multiplier`.

Extra secrets it needs: `DEPLOYER_PRIVATE_KEY_SEPOLIA` /
`DEPLOYER_PRIVATE_KEY_MAINNET` (must control the `deployer_address` input).
