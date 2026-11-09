# Release tags

A release tag marks the exact commit whose contracts a CTM runs. The
[Check release tags](../.github/workflows/check-release-tags.yaml) workflow checks every day that the protocol version
of each live CTM has one. When a mainnet CTM's version has none, it posts to Slack.

## Tag names

| Tag            | Marks                                                           | Example       |
| -------------- | --------------------------------------------------------------- | ------------- |
| `v<x.y.z>`     | a ZKsync OS CTM release at protocol version `x.y.z`             | `v0.33.2`     |
| `era-v<x.y.z>` | an Era CTM release at protocol version `x.y.z`                  | `era-v0.33.0` |
| `zip-<n>`      | the commit that produced governance proposal ZIP-`n`'s calldata | `zip-18`      |

The `v` prefix meant Era up to v0.29, and ZKsync OS used `zkos-v`. Those tags, `v0.33.0` and `v31-mainnet` predate this
policy. The check still accepts a `zkos-v<x.y.z>` tag for a ZKsync OS CTM.

## When to tag

Push a version tag once the upgrade to that version has executed on its first environment, testnet or mainnet, on the
commit that produced the executed calldata. Do not tag when the code is merged: an upgrade can stall before it executes.

Push the `zip-<n>` tag when governance proposal ZIP-`n` is submitted, on the commit that produced its calldata. Every tag
is pushed by hand, after the go-ahead from the release owner.

A pushed tag is never moved. If a proposal is resubmitted with new calldata, tag the new proposal's number.

The tagged commit must be one of the release branch's own commits, not one it shares with `main`. That branch keeps
the deployed bytecode: contract fixes go to the next release, not to the tagged branch.

Keep the release branch: the daily check reports a tag whose branch is gone. GitHub deletes a PR's head branch when the
PR merges, so never open a PR from a `release/*` branch itself. To bring its changes into `main`, open the PR from a copy
(`git push origin release/<name>:refs/heads/merge/<name>`). If a release branch is deleted anyway, restore it ("Restore
branch" on its merged PR). A branch already merged into `main` with a merge commit, like `release/v0.33.0-atomic-interop`
in #2667, is still found through that merge.

## What the check enforces

The check covers the mainnet, ADI, testnet and testnet3 environments, each described by
[`l1-contracts/upgrade-envs/permanent-values/<env>.toml`](../l1-contracts/upgrade-envs/permanent-values). Stage runs
release candidates and is not checked. For each environment it reads the CTMs of the chains registered in the Bridgehub,
and for each CTM:

- the CTM is listed in the environment's file. Its flavour comes from the file's `is_zk_sync_os`, or else from the CTM's
  `isZKsyncOS()`;
- its `getSemverProtocolVersion()` has a tag: `era-v<x.y.z>` for Era, `v<x.y.z>` or `zkos-v<x.y.z>` for ZKsync OS;
- the tag's commit is on an `origin/release/*` branch and not on `main`, or was on a release branch merged into `main`
  with a merge commit and not on `main` before that merge.

On mainnet a failure is an error: it fails the run and posts to Slack. On Sepolia it is a warning in the run summary:
some testnet versions released before this policy have no tag. A failed RPC call is an error everywhere.

Run the check locally with the command below. It reads the local tags and the `origin/release/*` and `origin/main`
branches, so fetch them first.

```bash
cd l1-contracts
git fetch origin --tags --prune
L1_RPC_URL_MAINNET=<rpc> L1_RPC_URL_SEPOLIA=<rpc> yarn check-release-tags --require-onchain
```
