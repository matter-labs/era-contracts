# EOA upgrade executor

Sends the EOA transactions of a stage or testnet protocol upgrade from GitHub
Actions, so nobody pastes calldata into MetaMask or a key into a terminal.

- `.github/workflows/execute-eoa-upgrade.yaml` here is a **reusable workflow**
  (`on: workflow_call`). This repository never runs it.
- `matter-labs/era-contracts-private` holds only a thin caller on its default
  branch `executor` (an orphan branch: the caller workflow, `CODEOWNERS`, a
  README) and the key, as a GitHub environment secret. It mirrors nothing, so
  it cannot go out of sync.
- The executor code (this directory) and the transaction files both come from
  this public repository, at commits pinned by the caller and the dispatcher.

Two of the three code owners (`kelemeno`, `StanislavBreadless`, `vladbochok`,
the members of the team `protocol-upgrade-approvers`) are needed for every
broadcast: one starts the run, a different one approves it.

## How a run works

In `era-contracts-private`, start **Actions → Execute EOA upgrade
transactions → Run workflow** on `executor`, with:

| input           | meaning                                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `source_sha`    | commit of `matter-labs/era-contracts` that holds the file, full 40-hex SHA                                                         |
| `source_branch` | branch of `matter-labs/era-contracts` that contains `source_sha`                                                                   |
| `path`          | repo-relative path of the file at that commit                                                                                      |
| `environment`   | `stage` or `testnet`: picks the network (both Sepolia), the GitHub environment with the key, and its approvers                     |
| `tx_range`      | optional `N` or `A-B`, 0-based and inclusive (default: the whole file); for resuming, or for splitting a file with several senders |
| `fork_block`    | optional block for the simulate job (default: latest)                                                                              |
| `dry_run`       | default `true`: every check runs, nothing is signed or sent                                                                        |

The caller passes two more inputs of its own: `executor_sha`, the commit of
this repository it pins the reusable workflow to, and `executor_branch`, a
branch of this repository that contains it (see [Pinning](#pinning-the-executor)).

Two file formats are read:

- `emergency-upgrade-board`: `l1-contracts/upgrade-envs/<upgrade>/output/<env>/emergency-upgrade-board.json`,
  `{ "_comment", "emergency_upgrade_board", "protocol_upgrade_handler", "owner", "transactions": [{ "step", "label", "from", "to", "data" }] }`.
  Value is always 0, the network is the environment's, and steps must be
  1, 2, 3, ... in file order.
- `transaction-simulator`: the array format of `matter-labs/transaction-simulator`
  (`description`, `network`, `from`, `to`, `value` in ETH, `data`, ...).

Every job starts the same way, without any action: it checks that
`executor_sha` is on `executor_branch` of `matter-labs/era-contracts`,
fetches the executor there anonymously with plain git, and checks its git
tree against the one resolve ran. resolve also reads the caller's run to
check that this workflow file runs at `executor_sha`, so the workflow and
the scripts come from one commit. The transaction file is fetched the same
way, after the same branch check for `source_sha` on `source_branch`. In a
called workflow the `github` context (repository, ref, actor, token) and the
environment are the caller's, so every repository, branch and actor check
below is about `era-contracts-private`.

The jobs:

1. **resolve** runs **no action**, because it renders the table the approver
   reads. It checks the inputs, verifies the commit resolves to itself and the
   file hashes to its git blob, validates every entry, and writes the job
   summary: source link, git blob, sha256, sender, and for each selected
   transaction its index, description, from, to, value, 4-byte selector,
   calldata length and keccak256 of the calldata, plus the transactions left
   out of the range and the executor commit. It fails on an unknown field, a
   malformed address, calldata or value, a bad EIP-55 checksum, a network other
   than the environment's, an RPC with another chain id, a nonzero value
   (`config.json` allows only zero-value transactions), a simulation-only
   field (`testOnly`, `timeIncrease`, `emulateAllBatchesExecuted`), or more
   than one sender in the range. It outputs the sha256 of `plan.json` and the
   executor's git tree; the other jobs rebuild the plan and must match both.
2. **simulate** is **advisory**. It rebuilds the plan the same way and must
   match resolve's hash, forks the network's public RPC with anvil,
   impersonates the sender and sends the transactions in order; every one must
   succeed. Its only action uploads the receipts and `callTracer` traces
   (`actions/upload-artifact`, pinned by SHA) after the results are in the
   summary. Nothing it produces is the approval table or is trusted by
   broadcast, which repeats the simulation itself before signing.
3. **preflight** runs no action, because broadcast depends on it. It fails
   unless the caller is `matter-labs/era-contracts-private`, the run is on its
   default branch, whoever started it is one of the dispatchers in
   `config.json`, and the GitHub environment is protected as described under
   [Setup](#setup-devops): the team `protocol-upgrade-approvers` as its only
   reviewer, self-review prevented, no admin bypass, and a deployment branch
   policy of "protected branches" (the default branch must be one; any other
   protected branch is reported as a warning) or a custom list of exactly the
   default branch. A job that names a missing environment makes GitHub create
   it without protection, so the broadcast job must not start until this
   passes.
4. **broadcast** runs in the caller's GitHub environment
   `eoa-upgrade-<environment>`, so it waits for a required reviewer, who
   cannot be the person who started the run. It runs **no action**: after the
   common start it repeats the dispatcher check (a re-run of this job alone
   does not re-run preflight), rebuilds the plan and requires resolve's hash,
   replays the whole range on a fresh fork of the latest block (approval can
   come hours after step 2; results in the job summary), and only then, in
   its last step, loads the key:
   - the keystore's address must be the plan's sender;
   - two independent RPCs (`rpcUrl`, `secondaryRpcUrl` in `config.json`) must
     agree on the chain id and on the sender's nonce, with nothing pending;
   - per transaction: `eth_call` must succeed on both RPCs; the gas limit is
     `eth_estimateGas` + 20% (higher of the two answers, at most
     `maxTxGasLimit`); fees are EIP-1559 (max fee = 2 x base fee + priority
     fee, higher of the two answers, clamped to the cap; never `--legacy`,
     which can sit below the base fee forever) and must stay within the
     network's caps (`maxPriorityFeePerGasWei`, `maxFeePerGasWei`, and
     `maxRunFeeWei` for the whole run, which reserves each transaction's
     worst case, gas limit x max fee, and never credits anything back from a
     receipt), checked before signing; then sign, log the hash, publish to
     both RPCs, and wait (up to 15 minutes) until both return the receipt with
     the same block hash and status 1 before the next. A disagreement, an RPC
     that stops answering (after brief retries), or a reverted receipt stops
     the run.

   With `dry_run: true` it checks the keystore (if set) and runs the checks
   for the first transaction, then stops. Without a keystore it stops too:
   cleanly in a dry run, as an error in a live run. Dry runs need the same
   approval. One broadcast per environment runs at a time (`concurrency`),
   because runs share the sender's nonce.

### Files with several senders, and resuming

One run sends one sender's transactions; a file with two senders is two
runs with `tx_range`, the second once the first is on-chain (its simulation
forks the current chain, so it passes only then). If a run stops partway,
the summary shows which transactions landed; start a new run with `tx_range`
from the first one that did not. A transaction that timed out waiting for
its receipt may still land, so check its hash first.

## Pinning the executor

The caller in `era-contracts-private` names the reusable workflow by commit,
once:

```yaml
jobs:
  pin: # checks the commit in `uses:` below is on EXECUTOR_BRANCH upstream
    env:
      EXECUTOR_BRANCH: draft-v31
  execute:
    needs: pin
    uses: matter-labs/era-contracts/.github/workflows/execute-eoa-upgrade.yaml@<sha>
    with:
      executor_sha: ${{ needs.pin.outputs.executor_sha }}
      executor_branch: ${{ needs.pin.outputs.executor_branch }}
```

**Why the branch check.** GitHub serves every commit of a fork network
through the parent repository: `git fetch https://github.com/matter-labs/era-contracts <sha>`
and `uses: matter-labs/era-contracts/...@<sha>` both accept a SHA that exists
only in someone's fork ("impostor commits"). A pin alone therefore does not
prove the code was reviewed here. The public compare API does:
`compare/<branch>...<sha>` is `behind` or `identical` only when the commit is
on that branch.

**Who checks what.** A workflow file cannot vouch for itself: code at an
impostor commit would simply skip its own checks. So the caller's `pin` job,
code reviewed in `era-contracts-private` that runs before anything from this
repository, reads which commit its run references for this workflow (the
run's `referenced_workflows`), checks that commit is on `EXECUTOR_BRANCH`,
and passes it on as `executor_sha`. This workflow then checks, for any
caller, that `executor_sha` is on `executor_branch` and is the commit it runs
at, and applies the same branch rule to `source_sha` on `source_branch`.

**Bumping the pin.** Land the executor change on its branch here (normally
`draft-v31`, through a reviewed PR), then open a PR in `era-contracts-private`
that changes the SHA in `uses:` (and `EXECUTOR_BRANCH` if needed). Its
`CODEOWNERS` require a code-owner approval.

## Setup (devops)

All of it is in `matter-labs/era-contracts-private`.

1. **From terraform** (`matter-labs/terraform-configurations` #6677, once
   `matter-labs/terraform-modules` #2255 is released):
   - write access only for the team `protocol-upgrade-approvers` (members
     `kelemeno`, `StanislavBreadless`, `vladbochok`; `StanislavBreadfulAI` is
     a different, bot account and must not be added);
   - default branch `executor`, protected: pull request required, 1
     code-owner approval; together with the organization ruleset on
     `~DEFAULT_BRANCH`, no force pushes and no deletion;
   - environments `eoa-upgrade-stage` and `eoa-upgrade-testnet`, each with
     the team as required reviewer, prevent self-review on, administrators
     cannot bypass, and deployment branches "protected branches";
   - Actions allowed to use reusable workflows from `matter-labs/era-contracts`.
2. **By hand**, in each environment, the only two secrets:
   - `EXECUTOR_KEYSTORE`: the contents of an encrypted foundry keystore for
     the sending EOA (stage: `0xd669494442609879b209CcA8eba2BdC904D2E69D`).
     Create it on a trusted machine with
     `cast wallet import eoa-upgrade-stage --interactive` (prompts for the key
     and a password, nothing on the command line) and copy
     `~/.foundry/keystores/eoa-upgrade-stage`.
   - `EXECUTOR_KEYSTORE_PASSWORD`: that password.

   Leave them unset until the key should be used; dry runs work without
   them. The caller passes no secrets (no `secrets: inherit`): a job with
   `environment:` in a reusable workflow reads that environment's secrets in
   the caller's repository directly.

3. **Never add a repository-level secret** to `era-contracts-private`. Any
   workflow on any branch reads repository secrets without an approval, and
   workflows written for this repository's CI do not guard them:
   `.github/workflows/execute-deployer-safe-bundles.yaml`, for one, reads
   `DEPLOYER_PRIVATE_KEY_*` as repository secrets in a job with no
   environment, puts inputs straight into `run:` and writes the key into
   `$GITHUB_ENV`.
4. Before relying on "protected branches", check which branches are
   protected: besides `executor`, today `fake_default` and an old mirror
   branch `main` are, and either could then deploy (each run still needs an
   approval). Preflight prints them as a warning. Removing their protection,
   or switching to a custom list of `executor` once the module supports it,
   closes that.

Preflight checks the environment settings above, not the secrets and not
the team's membership: `GITHUB_TOKEN` cannot read team membership, so that
rests on terraform. The dispatcher allow-list in `config.json` repeats the
three logins.

A second sender for an environment needs its own GitHub environment, a
`config.json` entry and an `environment` option in the caller.

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

| vector                                                                                          | mitigation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unreviewed executor or transaction code (an impostor commit from a fork, or an unmerged commit) | The caller's `pin` job checks that the commit its `uses:` references is on the upstream branch before this workflow runs; this workflow checks that `executor_sha` is that commit and on its branch, and that `source_sha` is on `source_branch` (public compare API). The pin changes only through a reviewed PR in `era-contracts-private`.                                                                                                                                                                                                                                                                                                                                                                                          |
| A modified caller or workflow on another branch of `era-contracts-private` reads the secret     | Environment secrets reach only jobs on protected branches (deployment branch policy), and each such job still needs an approval. Protected branches need a reviewed PR to change; `CODEOWNERS` covers everything. The in-workflow default-branch check stops accidental runs from other protected branches, not a modified caller on one; hence the warning and setup item 4.                                                                                                                                                                                                                                                                                                                                                          |
| Someone without write access starts a run                                                       | Only the team `protocol-upgrade-approvers` has write access (terraform); `check-run.sh` also rejects any other `actor` / `triggering_actor`, in preflight and again in the broadcast job.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| One person sends alone                                                                          | The team is the required reviewer and self-review is prevented: the approver is a team member other than the dispatcher.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Admin bypass, or an unprotected environment                                                     | Admin bypass off; preflight fails unless the team is the only reviewer, self-review is prevented, admin bypass is off and the branch policy is "protected branches" (with the default branch protected) or exactly the default branch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| A repository-level secret                                                                       | None exists and none may be added (setup item 3): unlike environment secrets, any workflow on any branch reads them.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Another workflow names the environment                                                          | The environment names are specific to this tool, and `era-contracts-private` has no other workflow on `executor`; one would have to land there through review and would still wait for approval.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| The secret printed in logs                                                                      | GitHub masks secret values; the scripts never echo them, `set +x` is set, nothing dumps the environment, and errors of the two `cast` commands that read the key are discarded. The summary and logs show the transactions and hashes.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| The secret in an artifact or cache                                                              | The key step is the last step of a job that uploads nothing and uses no cache; the key files are deleted on exit.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Script injection through inputs                                                                 | No `${{ }}` in any `run:`: inputs reach scripts through `env:` and are validated (40-hex commits, plain branch names and file path, `N`/`A-B`, block number) before use; `environment` is a choice in the caller and checked against `config.json`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| A compromised third-party action or tool                                                        | resolve (the approval table and the plan hash), preflight (the gate) and broadcast (the key) run no action. The only action in the workflow is the pinned `actions/upload-artifact` at the end of the advisory simulate job, which never sees a secret and produces nothing that is displayed as the approval table or trusted by broadcast. Foundry is the release tarball pinned by sha256 in `config.json`. The tests fail if a `uses:` appears in resolve, preflight or broadcast, if any other action appears, or if a secret is read outside broadcast's last step.                                                                                                                                                              |
| Git credentials                                                                                 | None are used: the executor and the transaction files are fetched anonymously from the public repository, and the caller's `GITHUB_TOKEN` is only given to preflight's environment check (`actions: read`). Jobs get `contents: read`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| A tampered plan or a forged approval table                                                      | No plan is passed between jobs: resolve renders the table and outputs the plan hash from verified code, simulate and broadcast rebuild the plan from `source_sha` + `path` and must match that hash.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| A malicious or wrong transaction file                                                           | The approver sees the source commit, per-transaction calldata hashes and both simulations before approving, and should match them against the reviewed upgrade PR. Zero-value only, one sender per run, gas limit capped.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| A lying RPC                                                                                     | It never sees the key, only calls and signed transactions. To make the executor move on wrongly it would have to fool two independent providers at once: chain id, nonces, pre-send `eth_call` and receipts (block hash, status) must agree on both, or the run stops. Inflated fees are capped per network (priority fee, max fee per gas, gas per tx) before signing, and the run's fee total reserves each transaction's worst case (gas limit x max fee, the values being signed) and never credits a receipt, so fake receipt fees cannot free the budget; understated fees at worst leave a tx pending. The fork used for simulation comes from one RPC, so a simulation can be fooled; the live checks above do not rely on it. |
| Debug logging (`ACTIONS_STEP_DEBUG`)                                                            | Secrets stay masked; nothing in the scripts depends on it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| The GitHub runner or GitHub itself                                                              | Out of scope: a compromised runner sees everything the job sees.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

## Running it on a laptop

Needs upstream foundry `v1.5.1` (`foundryup --install v1.5.1`; other builds
print a warning), `jq`, `curl` and `git`. From this repository:

```bash
cd tools/eoa-upgrade-executor
sha=a92ad0057f77adfe6a6bdb46d8b2fb60b2ef804c
branch=kl/v33-stage-compiler-upgrade-draft-v31
file=l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/emergency-upgrade-board.json

scripts/git-fetch.sh matter-labs/era-contracts "$branch" "$sha" "$file" /tmp/src
scripts/fetch.sh "$sha" "$file" /tmp/src /tmp/plan
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
tests/fork.test.sh          # Sepolia fork + GitHub API: the v0.33.0 stage file passes, a tampered copy fails
```

Both run on pull requests (`.github/workflows/eoa-upgrade-executor-tests.yaml`,
no secrets). The local test uses throwaway keystores against a plain local
anvil, not a fork of a real network.
