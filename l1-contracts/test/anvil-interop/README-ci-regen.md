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

**Push-artifacts option** (`push_artifacts` input, default off): on a PUVT-green
run it commits the regenerated `ecosystem.toml` + `sim-inputs/` and **pushes them
to the branch this run was dispatched on** (refreshing that branch's open PR), so
the transaction-simulator-compatible `sim-inputs/` are reviewable in the diff. It
stages `output/<env>/` without `-f`, so `.gitignore` keeps `anvil.log` (which can
echo the RPC) and the ephemeral `prepare/` + `fork-rehearsal/` dirs out. Following
`update-generated-artifacts.yaml`, the workflow's `GITHUB_TOKEN` stays **read-only**
and the push is authenticated with the scoped **`RELEASE_TOKEN`** secret — no
`contents: write` / `pull-requests: write` needed.

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

## 2. Actual deployment (the `deploy` checkbox)

The real-network "Mode 2" deployment is folded into the same workflow as an
opt-in `deploy` checkbox (default off). On a run with `deploy` checked, after
regen+PUVT the job broadcasts **only the deployer-EOA bundle** to the real L1
via idempotent `dev execute-safe` (already-deployed CREATE2 addresses are
skipped). Governance / multisig bundles (PUH, security council) are **never**
broadcast here — those go through the governance process.

It is intentionally **ungated** — just the checkbox. It runs even if PUVT
reported errors (`!cancelled()`), since prepare's bundles already exist, and it
reuses the `DEPLOYER_PRIVATE_KEY_<net>` + real RPC already loaded into
`$GITHUB_ENV`. The `use_new_salt` checkbox rotates the deployment salts first so
the run lands at fresh CREATE2 addresses.

> Note: this does **not** merge the new real-network deploy hashes into the
> committed `transactions.txt`, so a `push_artifacts` run still pushes the
> calldata as "not-yet-deployed".
