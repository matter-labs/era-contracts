# Release tags

A release tag marks the exact commit whose contracts are deployed. [`release-tags.json`](../release-tags.json) records
every release tag and every live deployment, and the
[Check release tags and deployments](../.github/workflows/check-release-tags.yaml) workflow checks it against git and
the chains every day. When the check fails, it posts to Slack.

## Tag names

| Tag            | Marks                                                          | Example       |
| -------------- | -------------------------------------------------------------- | ------------- |
| `v<x.y.z>`     | a ZKsync OS CTM release at protocol version `x.y.z`            | `v0.33.2`     |
| `era-v<x.y.z>` | an Era CTM release at protocol version `x.y.z`                 | `era-v0.33.0` |
| `zip-<n>`      | the commit whose calldata governance proposal ZIP-`n` executed | `zip-18`      |

The `v` prefix meant Era up to v0.29 and ZKsync OS used `zkos-v`. Those tags, `v0.33.0` and `v31-mainnet` predate this
policy. They are listed under `legacyTags` and are not checked.

## When to tag

Tag after the upgrade executes on mainnet. A release that never goes to mainnet is tagged after its last environment.
Do not tag when the code is merged. Push the tag on the commit
that produced the executed calldata. For a governance proposal, push both the `zip-<n>` tag and the version tags of the
CTMs it upgraded. Every tag is pushed by hand, after the go-ahead from the release owner.

The tagged commit must be on a `release/*` branch. That branch keeps the deployed bytecode: contract fixes go to the next
release, not to the tagged branch.

## What the check enforces

For each tag in `tags`:

- the tag exists and points at the recorded `commit`;
- the commit is on the recorded `release/*` branch;
- `configs/genesis/{era,zksync-os}/latest.json` at the commit declare the recorded `genesis` versions;
- the version in a `v` / `era-v` tag name equals that flavour's genesis version.

Every tag that looks like a release tag (`v*`, `era-v*`, `zkos-*`, `zip-*`) must be in `tags` or `legacyTags`.

For each deployment in `deployments`:

- the CTM's `getSemverProtocolVersion()` equals `protocolVersion`;
- each listed chain is registered under that CTM and its diamond is at `protocolVersion`;
- if `tag` is set, the tag's genesis for the deployment's flavour equals `protocolVersion`. A deployment without a tag
  is reported as a warning.

## After an upgrade executes

The daily check fails once a CTM moves to a new version. To fix it:

1. Push the release tag (and the `zip-<n>` tag) on the commit that produced the executed calldata.
2. In `release-tags.json`, add the tag under `tags`. Set the deployment's `protocolVersion` and `tag`.
3. Open a PR. The workflow runs on it, and the on-chain part runs too when the PR is not from a fork.

Run the check locally with:

```bash
cd l1-contracts
L1_RPC_URL_MAINNET=<rpc> L1_RPC_URL_SEPOLIA=<rpc> yarn check-release-tags --require-onchain
```
