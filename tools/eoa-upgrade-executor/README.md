# EOA upgrade executor

Sends the EOA transactions of a stage or testnet protocol upgrade from GitHub
Actions, so nobody pastes calldata into MetaMask or a key into a terminal.
The workflow is `.github/workflows/execute-eoa-upgrade.yaml`. It runs only in
`matter-labs/era-contracts-private`, whose default branch mirrors `draft-v31`
of this repository; the key lives there as a GitHub environment secret.

Two of the three code owners (`kelemeno`, `StanislavBreadless`, `vladbochok`,
the members of the team `protocol-upgrade-approvers`) are needed for every
broadcast: one starts the run, a different one approves it.

## How a run works

Start **Actions → Execute EOA upgrade transactions → Run workflow** on the
default branch, with:

| input         | meaning                                                                                                                            |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `source_sha`  | commit of this repository that holds the file, full 40-hex SHA. Branch and tag names are rejected.                                 |
| `path`        | repo-relative path of the file at that commit                                                                                      |
| `environment` | `stage` or `testnet`: picks the network (both Sepolia), the GitHub environment with the key, and its approvers                     |
| `tx_range`    | optional `N` or `A-B`, 0-based and inclusive (default: the whole file); for resuming, or for splitting a file with several senders |
| `fork_block`  | optional block for the simulate job (default: latest)                                                                              |
| `dry_run`     | default `true`: every check runs, nothing is signed or sent                                                                        |

The executor code always comes from the ref the workflow runs on (the default
branch); only the transaction file comes from `source_sha`. The source commit
must exist in the private repository, so its branch has to be mirrored there
too.

Two file formats are read:

- `emergency-upgrade-board`: `l1-contracts/upgrade-envs/<upgrade>/output/<env>/emergency-upgrade-board.json`,
  `{ "_comment", "emergency_upgrade_board", "protocol_upgrade_handler", "owner", "transactions": [{ "step", "label", "from", "to", "data" }] }`.
  Value is always 0, the network is the environment's, and steps must be
  1, 2, 3, ... in file order.
- `transaction-simulator`: the array format of `matter-labs/transaction-simulator`
  (`description`, `network`, `from`, `to`, `value` in ETH, `data`, ...).

The jobs:

1. **resolve** checks the inputs, checks out `source_sha` (only that file),
   verifies the commit resolves to itself and the file hashes to its git blob,
   validates every entry, and writes the job summary: source link, git blob,
   sha256, sender, and for each selected transaction its index, description,
   from, to, value, 4-byte selector, calldata length and keccak256 of the
   calldata, plus the transactions left out of the range. It fails on an
   unknown field, a malformed address, calldata or value, a bad EIP-55
   checksum, a network other than the environment's, an RPC with another
   chain id, a nonzero value (`config.json` allows only zero-value
   transactions), a simulation-only field (`testOnly`, `timeIncrease`,
   `emulateAllBatchesExecuted`), or more than one sender in the range. Its
   output `plan.json` has a sha256 that every later job checks.
2. **simulate** forks the network's public RPC with anvil, impersonates the
   sender and sends the transactions in order; every one must succeed.
   Receipts and `callTracer` traces go to the `simulation` artifact.
3. **preflight** fails unless the repository is `matter-labs/era-contracts-private`,
   the run is on the default branch, whoever started it is one of the
   dispatchers in `config.json`, and the GitHub environment is protected as
   described under [Setup](#setup-devops): the team `protocol-upgrade-approvers`
   as its only reviewer, self-review prevented, no admin bypass, and a
   deployment branch policy of "protected branches" (the default branch must
   be one; any other protected branch is reported as a warning) or a custom
   list of exactly the default branch. A job that names a missing
   environment makes GitHub create it without protection, so the broadcast
   job must not start until this passes.
4. **broadcast** runs in the GitHub environment `eoa-upgrade-<environment>`,
   so it waits for a required reviewer, who cannot be the person who started
   the run. The job runs **no action** (no `uses:`), so nothing third-party
   shares the runner with the key: it fetches the executor at the run's commit
   with plain git (and checks its tree against what resolve ran), repeats the
   dispatcher check (a re-run of this job alone does not re-run preflight),
   rebuilds the plan from `source_sha` + `path` and requires it to hash to
   resolve's `plan.json`, replays the whole range on a fresh fork of the
   latest block (approval can come hours after step 2; results in the job
   summary), and only then, in its last step, loads the key:
   - the keystore's address must be the plan's sender;
   - two independent RPCs (`rpcUrl`, `secondaryRpcUrl` in `config.json`) must
     agree on the chain id and on the sender's nonce, with nothing pending;
   - per transaction: `eth_call` must succeed on both RPCs; the gas limit is
     `eth_estimateGas` + 20% (higher of the two answers, at most
     `maxTxGasLimit`); fees are EIP-1559 (max fee = 2 x base fee + priority
     fee, higher of the two answers, clamped to the cap; never `--legacy`,
     which can sit below the base fee forever) and must stay within the
     network's caps (`maxPriorityFeePerGasWei`, `maxFeePerGasWei`, and
     `maxRunFeeWei` for the whole run), checked before signing; then sign,
     log the hash, publish to both RPCs, and wait (up to 15 minutes) until
     both return the receipt with the same block hash and status 1 before the
     next. A disagreement, an RPC that stops answering (after brief retries),
     or a reverted receipt stops the run.

   With `dry_run: true` it checks the keystore (if set) and runs the checks
   for the first transaction, then stops. Without a keystore it stops too:
   cleanly in a dry run, as an error in a live run. Dry runs need the same
   approval.

One run per environment at a time (`concurrency`), because runs share the
sender's nonce.

### Files with several senders, and resuming

One run sends one sender's transactions; a file with two senders is two
runs with `tx_range`, the second once the first is on-chain (its simulation
forks the current chain, so it passes only then). If a run stops partway,
the summary shows which transactions landed; start a new run with `tx_range`
from the first one that did not. A transaction that timed out waiting for
its receipt may still land, so check its hash first.

## Setup (devops)

All of it is in `matter-labs/era-contracts-private`.

1. **From terraform** (`matter-labs/terraform-configurations` #6677, once
   `matter-labs/terraform-modules` #2255 is released):
   - write access only for the team `protocol-upgrade-approvers` (members
     `kelemeno`, `StanislavBreadless`, `vladbochok`; `StanislavBreadfulAI` is
     a different, bot account and must not be added);
   - branch protection on the default branch `draft-v31` (mirrored from this
     repository): pull request required, 1 code-owner approval; together with
     the organization ruleset on `~DEFAULT_BRANCH`, no force pushes and no
     deletion. A mirroring bot that pushes directly must be the only bypass
     actor;
   - environments `eoa-upgrade-stage` and `eoa-upgrade-testnet`, each with
     the team as required reviewer, prevent self-review on, administrators
     cannot bypass, and deployment branches "protected branches".
2. **By hand**, in each environment, the only two secrets:
   - `EXECUTOR_KEYSTORE`: the contents of an encrypted foundry keystore for
     the sending EOA (stage: `0xd669494442609879b209CcA8eba2BdC904D2E69D`).
     Create it on a trusted machine with
     `cast wallet import eoa-upgrade-stage --interactive` (prompts for the key
     and a password, nothing on the command line) and copy
     `~/.foundry/keystores/eoa-upgrade-stage`.
   - `EXECUTOR_KEYSTORE_PASSWORD`: that password.

   Leave them unset until the key should be used; dry runs work without
   them.

3. **Never add a repository-level secret** to `era-contracts-private`. Every
   workflow of the mirrored repository can read repository secrets, from any
   branch, without an approval. `.github/workflows/execute-deployer-safe-bundles.yaml`
   is one: it reads `DEPLOYER_PRIVATE_KEY_*` as repository secrets in a job
   with no environment, puts inputs straight into `run:` and writes the key
   into `$GITHUB_ENV`, so a key stored that way is readable by anyone who can
   push a branch or dispatch a workflow.
4. Before relying on "protected branches", check which branches are
   protected: today `fake_default` and an old mirror branch `main` are, and
   either could then deploy (each run still needs an approval). Preflight
   prints them as a warning. Removing them, or switching to a custom list of
   `draft-v31` once the module supports it, closes that.

Preflight checks the environment settings above, not the secrets and not
the team's membership: `GITHUB_TOKEN` cannot read team membership, so that
rests on terraform. The dispatcher allow-list in `config.json` repeats the
three logins.

A second sender for an environment needs its own GitHub environment, a
`config.json` entry and a workflow `environment` option.

## Threat model

What the design protects: the private key of the sending EOA, and the rule that
nothing is sent without two of the three code owners.

**How the key is handled.** `cast` has no environment variable for a raw
private key (`--private-key` is argv only), so the secret is an encrypted
keystore and its password. Both are environment secrets, mapped into the
`env:` of one step, the last step of the broadcast job. `execute.sh` moves
them into shell variables and unsets them before anything else runs, so no
child process inherits them; writes them with the `printf` builtin into two
0600 files in a private temporary directory; passes only the file paths to
the two `cast` commands that need them (`wallet address` and `mktx`, as
`ETH_KEYSTORE` / `ETH_PASSWORD`); and deletes the files on exit. The raw key
exists only inside `cast`. The tests check that neither secret appears on any
`cast` command line, in any `cast` process environment, or in the output, and
that the files are gone afterwards.

| vector                                                           | mitigation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A modified workflow or script on another branch reads the secret | Environment secrets reach only jobs on protected branches (deployment branch policy), and each such job still needs an approval. Protected branches need a reviewed PR to change; `CODEOWNERS` covers this workflow and directory. The in-workflow default-branch check stops accidental runs from other protected branches, not a modified workflow on one; hence the warning and item 4 of the setup.                                                                                                                                                           |
| Someone without write access starts a run                        | Only the team `protocol-upgrade-approvers` has write access (terraform); `check-run.sh` also rejects any other `actor` / `triggering_actor`, in preflight and again in the broadcast job.                                                                                                                                                                                                                                                                                                                                                                         |
| One person sends alone                                           | The team is the required reviewer and self-review is prevented: the approver is a team member other than the dispatcher.                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Admin bypass, or an unprotected environment                      | Admin bypass off; preflight fails unless the team is the only reviewer, self-review is prevented, admin bypass is off and the branch policy is "protected branches" (with the default branch protected) or exactly the default branch.                                                                                                                                                                                                                                                                                                                            |
| A repository-level secret                                        | None exists and none may be added (setup item 3): unlike environment secrets, any workflow on any branch reads them.                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Another workflow in the repository names the environment         | The environment names are specific to this tool; a workflow that names them must land on `draft-v31` through review and still waits for approval. `pull_request_target` workflows run in the default branch's context, so review any that are added.                                                                                                                                                                                                                                                                                                              |
| The secret printed in logs                                       | GitHub masks secret values; the scripts never echo them, `set +x` is set, nothing dumps the environment, and errors of the two `cast` commands that read the key are discarded. The summary and logs show the transactions and hashes.                                                                                                                                                                                                                                                                                                                            |
| The secret in an artifact or cache                               | The key step is the last step of a job that uploads nothing and uses no cache; the key files are deleted on exit.                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Script injection through inputs                                  | No `${{ }}` in any `run:`: inputs reach scripts through `env:` and are validated (40-hex commit, plain file path, `N`/`A-B`, block number) before use; `environment` is a choice.                                                                                                                                                                                                                                                                                                                                                                                 |
| A compromised third-party action or tool                         | The key job runs no action: executor and source are fetched with plain git at pinned commits (executor tree checked against resolve), the plan is rebuilt and must hash to resolve's, and the re-simulation goes to the job summary. Other jobs use only `actions/checkout`, `actions/upload-artifact` and `actions/download-artifact`, pinned by commit SHA, and never see a secret. Foundry is the release tarball pinned by sha256 in `config.json`. The tests fail if a `uses:` appears in the broadcast job or a secret outside its last step.               |
| Git credentials                                                  | `actions/checkout` runs with `persist-credentials: false`; the broadcast job hands `GITHUB_TOKEN` to git through its environment (never argv, never `.git/config`), and not to the key step. Jobs get `contents: read` (preflight also `actions: read` for the environment API).                                                                                                                                                                                                                                                                                  |
| A tampered plan between jobs                                     | `plan.json`'s sha256 is a job output of resolve; simulate checks the downloaded plan against it, and broadcast rebuilds the plan itself and checks it.                                                                                                                                                                                                                                                                                                                                                                                                            |
| A malicious or wrong transaction file                            | The approver sees the source commit, per-transaction calldata hashes and both simulations before approving, and should match them against the reviewed upgrade PR. Zero-value only, one sender per run, gas limit capped.                                                                                                                                                                                                                                                                                                                                         |
| A lying RPC                                                      | It never sees the key, only calls and signed transactions. To make the executor move on wrongly it would have to fool two independent providers at once: chain id, nonces, pre-send `eth_call` and receipts (block hash, status) must agree on both, or the run stops. Inflated fees are capped per network (priority fee, max fee per gas, fee total per run; gas per tx) before signing; understated fees at worst leave a tx pending. The fork used for simulation comes from one RPC, so a simulation can be fooled; the live checks above do not rely on it. |
| Debug logging (`ACTIONS_STEP_DEBUG`)                             | Secrets stay masked; nothing in the scripts depends on it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| The GitHub runner or GitHub itself                               | Out of scope: a compromised runner sees everything the job sees.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

## Running it on a laptop

Needs upstream foundry `v1.5.1` (`foundryup --install v1.5.1`; other builds
print a warning), `jq` and `git`. From this repository:

```bash
cd tools/eoa-upgrade-executor
sha=8ad567ab6eb1f142338dd0eda2d70d2d394687ef
file=l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/emergency-upgrade-board.json

scripts/fetch.sh "$sha" "$file" ../.. /tmp/plan    # ../.. is this repository's checkout
scripts/resolve.sh --plan-dir /tmp/plan --environment stage
cat /tmp/plan/summary.md
scripts/simulate.sh --plan-dir /tmp/plan           # or --fork-block N
scripts/execute.sh --plan /tmp/plan/plan.json --mode key --dry-run --out /tmp/plan/dry
```

`simulate.sh` starts anvil on the first free port from 8645 and stops only
that process. `resolve.sh --simulation-only` lifts the one-sender rule to
simulate a whole multi-sender file; such a plan is never signed.
`--fork-block` must be recent for the public node, which prunes old state
within days; for older blocks set `FORK_RPC_URL` to an archive node (for
example `https://sepolia.gateway.tenderly.co`). Keep API keys out of it in CI:
it appears in `anvil.log`.

## Tests

```bash
tests/local-anvil.test.sh   # offline: validation, run checks, send loop on a local anvil
tests/fork.test.sh          # Sepolia fork: the v0.33.0 stage file passes, a tampered copy fails
```

Both run on pull requests (`.github/workflows/eoa-upgrade-executor-tests.yaml`,
no secrets). The local test uses throwaway keystores against a plain local
anvil, not a fork of a real network.
