# CI: Regen / Verify / Deploy v31 upgrade calldata

Two on-demand workflows cover the v31 ecosystem-upgrade calldata lifecycle.

## 1. Regenerate + verify (+ optional PR)

[`.github/workflows/generate-ecosystem-upgrade-calldata.yaml`](../../../.github/workflows/generate-ecosystem-upgrade-calldata.yaml)
**redeploys** the upgrade against a fresh anvil fork of the target L1 and
**double-checks** it with PUVT (`protocol_ops ecosystem verify-upgrade`). It
builds the contracts + `protocol_ops` from the checked-out branch (default
profile — the same toolchain that produced the committed `AllContractsHashes.json`)
and runs the canonical [`regen-and-verify.sh`](./regen-and-verify.sh): `upgrade-prepare-all`
→ fund + fork-replay → PUVT → emit `sim-inputs/`. Green iff PUVT passes.

**Open-PR option** (`open_pr` input, default off): on a PUVT-green run it commits
the regenerated `ecosystem.toml` + `sim-inputs/` to a `ci/regen-<env>-<run_id>`
branch and opens a PR against the branch it ran on (override with `pr_base`). The
`sim-inputs/` are the transaction-simulator-compatible bundles, so reviewers see
the exact calls in the PR diff before they go to the simulator. The PR step
stages `output/<env>/` without `-f`, so `.gitignore` keeps `anvil.log` (which can
echo the RPC) and the ephemeral `prepare/` + `fork-rehearsal/` dirs out.

Required secrets: `L1_RPC_URL_SEPOLIA` / `L1_RPC_URL_MAINNET` (RPC, masked) and
`DEPLOYER_PRIVATE_KEY_SEPOLIA` / `DEPLOYER_PRIVATE_KEY_MAINNET` (deployer key,
secret-only; the fork replay impersonates, but the script derives the deployer
address from it).

> The `regen-and-verify.sh` `DEPLOYER_ADDR` override (added here) lets the same
> script run keyless for a local fork rehearsal (impersonation, no key) — handy
> when reproducing the artifact without the deployer key. CI uses `DEPLOYER_PK`
> from the secret.

## Dispatchability gate

`workflow_dispatch` workflows only register from the repo's **default branch**.
Until merged to `main`, these won't appear in the Actions dropdown.

## 2. Actual deployment

[`.github/workflows/deploy-upgrade-contracts.yaml`](../../../.github/workflows/deploy-upgrade-contracts.yaml)
is the **"Mode 2" real-network deployment** — the one job that uses the deployer
private key to push the new-contract CREATE2 deploys on-chain.

This is an operator-run helper, **not** the forced/authoritative production
deployment gate. It is deliberately conservative:

1. `workflow_dispatch` only — never on push. (No GitHub Environment gate; the
   dry-run default + confirm phrase below are the guards.)
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
