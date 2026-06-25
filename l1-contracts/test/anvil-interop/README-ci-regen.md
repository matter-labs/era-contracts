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
