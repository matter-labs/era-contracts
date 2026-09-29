# EOA upgrade executor

Sends the EOA transactions of a stage or testnet protocol upgrade from GitHub
Actions, so nobody pastes calldata into MetaMask or a key into a terminal.
The workflow is `.github/workflows/execute-eoa-upgrade.yaml`. It runs only in
`matter-labs/era-contracts-private`, whose default branch mirrors `draft-v31`
of this repository; the key lives there as a GitHub environment secret.

Two of the three code owners (`kelemeno`, `StanislavBreadless`, `vladbochok`)
are needed for every broadcast: one starts the run, a different one approves
it.

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
   described under [Setup](#setup-devops). A job that names a missing
   environment makes GitHub create it without protection, so the broadcast
   job must not start until this passes.
4. **broadcast** runs in the GitHub environment `eoa-upgrade-<environment>`,
   so it waits for a required reviewer, who cannot be the person who started
   the run. It repeats the dispatcher check (a re-run of this job alone does
   not re-run preflight), replays the whole range on a fresh fork of the
   latest block (approval can come hours after step 2), uploads that replay,
   and only then, in its last step, loads the key:
   - the keystore's address must be the plan's sender, and the sender must
     have nothing pending in the mempool;
   - per transaction: `eth_call` against the live chain (stop on revert),
     `eth_estimateGas` + 20% as gas limit, EIP-1559 fees (max fee = 2 x latest
     base fee + `eth_maxPriorityFeePerGas`; never `--legacy`, which can sit
     below the base fee forever), sign, log the hash, publish, and wait for
     the receipt (up to 15 minutes) before the next. A reverted receipt stops
     the run.

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

Nothing below exists yet. All of it is in `matter-labs/era-contracts-private`.

1. **Repository access**: write access (the right to dispatch workflows) only
   for `kelemeno`, `StanislavBreadless` and `vladbochok`. Note that
   `StanislavBreadfulAI` is a different, bot account.
2. **Default branch** `draft-v31` (mirrored from this repository), with a
   ruleset: pull request required, 1 approving review from a code owner, no
   force pushes, no deletion. The organization ruleset on `~DEFAULT_BRANCH`
   already has these; a mirroring bot that pushes directly needs to be its
   only bypass actor.
3. **Environments** `eoa-upgrade-stage` and `eoa-upgrade-testnet`, each:
   - Required reviewers: exactly `kelemeno`, `StanislavBreadless`,
     `vladbochok` (users, not a team).
   - Prevent self-review: on.
   - Allow administrators to bypass configured protection rules: off.
   - Deployment branches and tags: selected branches, only `draft-v31`.
   - Environment secrets:
     - `EXECUTOR_KEYSTORE`: the contents of an encrypted foundry keystore
       for the sending EOA (stage: `0xd669494442609879b209CcA8eba2BdC904D2E69D`).
       Create it on a trusted machine with
       `cast wallet import eoa-upgrade-stage --interactive` (prompts for the
       key and a password, nothing on the command line) and copy
       `~/.foundry/keystores/eoa-upgrade-stage`.
     - `EXECUTOR_KEYSTORE_PASSWORD`: that password.

   Leave the secrets unset until the key should be used; dry runs work
   without them. The preflight job checks every setting above except the
   secrets and the repository access.

4. No repository-level secret is needed.

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

| vector                                                           | mitigation                                                                                                                                                                                                                                                                                                          |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A modified workflow or script on another branch reads the secret | Environment secrets reach only jobs on `draft-v31` (deployment branch policy), and each such job still needs an approval. Changing `draft-v31` needs a reviewed PR; `CODEOWNERS` covers this workflow and directory.                                                                                                |
| Someone without write access starts a run                        | Only the three code owners have write access; `check-run.sh` also rejects any other `actor` / `triggering_actor`, in preflight and again in the broadcast job.                                                                                                                                                      |
| One person sends alone                                           | Required reviewers with self-review prevented: the approver differs from the dispatcher.                                                                                                                                                                                                                            |
| Admin bypass, or an unprotected environment                      | Admin bypass off; preflight fails unless reviewers are exactly the three, self-review is prevented, admin bypass is off and the branch policy is exactly the default branch.                                                                                                                                        |
| Another workflow in the repository names the environment         | The environment names are specific to this tool; a workflow that names them must land on `draft-v31` through review and still waits for approval. `pull_request_target` workflows run in the default branch's context, so review any that are added.                                                                |
| The secret printed in logs                                       | GitHub masks secret values; the scripts never echo them, `set +x` is set, nothing dumps the environment, and errors of the two `cast` commands that read the key are discarded. The summary and logs show the transactions and hashes.                                                                              |
| The secret in an artifact or cache                               | The key step is the last step: nothing is uploaded after it, the foundry install has no cache, and the key files are deleted on exit.                                                                                                                                                                               |
| Script injection through inputs                                  | No `${{ }}` in any `run:`: inputs reach scripts through `env:` and are validated (40-hex commit, plain file path, `N`/`A-B`, block number) before use; `environment` is a choice.                                                                                                                                   |
| A compromised third-party action or tool                         | Only `actions/checkout`, `actions/upload-artifact` and `actions/download-artifact`, pinned by commit SHA. Foundry is the release tarball pinned by sha256 in `config.json`, not an action. An earlier step in the broadcast job could still tamper with the files the key step runs, which is why there are so few. |
| `checkout` credentials                                           | `persist-credentials: false`; jobs get `contents: read` (preflight also `actions: read` for the environment API).                                                                                                                                                                                                   |
| A tampered plan between jobs                                     | `plan.json`'s sha256 is a job output of resolve, checked by simulate and broadcast.                                                                                                                                                                                                                                 |
| A malicious or wrong transaction file                            | The approver sees the source commit, per-transaction calldata hashes and both simulations before approving, and should match them against the reviewed upgrade PR. Zero-value only, one sender per run, gas limit capped.                                                                                           |
| The RPC (public node, fork source)                               | It only ever sees calls and signed transactions, never the key. A lying RPC can make a check pass or fail, not steal the key; the chain id is checked and the signature is bound to it.                                                                                                                             |
| Debug logging (`ACTIONS_STEP_DEBUG`)                             | Secrets stay masked; nothing in the scripts depends on it.                                                                                                                                                                                                                                                          |
| The GitHub runner or GitHub itself                               | Out of scope: a compromised runner sees everything the job sees.                                                                                                                                                                                                                                                    |

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
