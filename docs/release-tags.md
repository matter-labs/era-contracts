# Release tags

A release tag marks the exact commit whose contracts a CTM runs. The
[Check release tags](../.github/workflows/check-release-tags.yaml) workflow checks every day that the protocol version
of each live CTM has one. When a version has none, it posts to Slack.

## Tag names

| Tag            | Marks                                                           | Example       |
| -------------- | --------------------------------------------------------------- | ------------- |
| `v<x.y.z>`     | a ZKsync OS CTM release at protocol version `x.y.z`             | `v0.33.2`     |
| `era-v<x.y.z>` | an Era CTM release at protocol version `x.y.z`                  | `era-v0.33.0` |
| `zip-<n>`      | the commit that produced governance proposal ZIP-`n`'s calldata | `zip-18`      |

The `v` prefix meant Era up to v0.29, and ZKsync OS used `zkos-v`. Those tags, `v0.33.0` and `v31-mainnet` predate this
policy. The check still accepts a `zkos-v<x.y.z>` tag for a ZKsync OS CTM.

## When to tag

Upgrades go to stage, then testnet, then mainnet. Push a version tag once the upgrade to that version has executed on
stage, or on its first environment if it skips stage, on the commit that produced the executed calldata. Do not tag when
the code is merged: an upgrade can stall before it executes. Later environments then run the tagged commit; a change
after that needs a new version.

The generated runbook (`EXECUTE.md`) of an upgrade that sets a new CTM version ends with this step: the tag name, and the
commands that tag the commit that last changed the runbook's transaction list. Run them on the first environment; on a
later one, `git tag` stops because the tag exists.

Push the `zip-<n>` tag when governance proposal ZIP-`n` is submitted, on the commit that produced its calldata. Every tag
is pushed by hand, after the go-ahead from the release owner.

A pushed tag is never moved. If a proposal is resubmitted with new calldata, tag the new proposal's number.

## What the check enforces

The check covers the stage, testnet, testnet3, mainnet and ADI environments, each described by
[`l1-contracts/upgrade-envs/permanent-values/<env>.toml`](../l1-contracts/upgrade-envs/permanent-values). For each
environment it reads the CTMs of the chains registered in the Bridgehub, and for each CTM:

- the CTM is listed in the environment's file. Its flavour comes from the file's `is_zk_sync_os`, or else from the CTM's
  `isZKsyncOS()`;
- its `getSemverProtocolVersion()` has a tag: `era-v<x.y.z>` for Era, `v<x.y.z>` or `zkos-v<x.y.z>` for ZKsync OS.

Every failure, and every failed RPC call, fails the run and posts to Slack.

Run the check locally with the command below. It reads the local tags, so fetch them first.

```bash
cd l1-contracts
git fetch origin --tags --prune
L1_RPC_URL_MAINNET=<rpc> L1_RPC_URL_SEPOLIA=<rpc> yarn check-release-tags --require-onchain
```
