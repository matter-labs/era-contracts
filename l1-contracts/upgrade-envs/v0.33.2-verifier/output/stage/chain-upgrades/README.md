# Per-chain v0.33.0 → v0.33.2 calldata (stage)

The ecosystem ceremony in `../ecosystem.toml` registers the cut on the ZKsync OS CTM. It does not move
any chain. Each chain then takes the cut itself, through its own ChainAdmin.

This directory holds two bundles per chain, **in execution order**:

1. `01_chain.set-upgrade-timestamp`: `ServerNotifier.setUpgradeTimestamp(chainId, 1)`
2. `02_chain.upgrade`: `upgradeChainFromVersion(chain, 0x2100000000, cut)`

Both are `ChainAdmin.multicall` (`0x69340beb`), signed by that ChainAdmin's owner. Every cut bundle is
byte-identical to `[chain_upgrades.<id>].chain_admin_calldata` in `../ecosystem.toml`;
`generate-chain-upgrades-stage.sh` and `rehearse-stage.sh` both check it.

| chain | ChainAdmin (the `to`)                        | signer (ChainAdmin owner)                    | DA today (unchanged by the upgrade) |
| ----- | -------------------------------------------- | -------------------------------------------- | ----------------------------------- |
| 2727  | `0x77ec7b16e9063b5eee0d26a69bfd7047e398b65f` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | rollup, blobs, full pubdata         |
| 2728  | `0x81cd6071ea6da05de4b8b1d3d745b84e106b86d5` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | rollup, blobs, full pubdata         |
| 2729  | `0x2b32b8172593ae425723d6fed51e41e4428594cd` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | validium, EmptyNoDA, full pubdata ⚠ |
| 27271 | `0x36e6ebc9f445fe19b1aba6dfc384dafb9d7ae7e8` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | rollup, blobs, full pubdata         |
| 27272 | `0x79be7e3240bfe25aaa7c7eb743cecc1d8ceac64e` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | validium, EmptyNoDA, full pubdata ⚠ |
| 27273 | `0xe088729c25bc626381eeae9853112774a76f11a6` | `0xd2d5391421f98a0086f4143d2ea0337a31ca89e5` | validium, blobs, logs-only pubdata  |

### The order is load-bearing

`setUpgradeTimestamp` keys the timestamp on the chain's protocol version **at the time of that call**.
Run the cut first and the timestamp lands under v0.33.2, so the server never sees one for the upgrade
the chain just took. Like the v33 testnet bundles, the timestamp is `1`: "no waiting", since 0 is the
unset sentinel and is rejected.

### Precondition: no batches in flight

`DefaultUpgradeZKsyncOS.upgrade` reverts with `NotAllBatchesExecuted()` unless
`totalBatchesCommitted == totalBatchesExecuted`. The new verifier would otherwise be asked to verify
batches proven for the old VK. Time each chain's cut for a moment when its executor has caught up. At
the rehearsal's fork block only 2727 and 2728 were idle.

To get past this check, the generator advances the generation fork's batch counters for chains with
batches in flight, the same way the v33 testnet README describes. That fork is never a real network,
and the emitted calldata does not depend on it.

### DA: left alone

The cut sets no DA. Every chain keeps its validator pair and pubdata content, and protocol-ops reports
`pair unchanged, pubdata content unchanged` for all six.

2729 and 27272 (⚠) are validium-priced and commit full pubdata with the `EmptyNoDA` scheme, which
protocol-ops flags as not the recommended state. That state predates this upgrade, and the upgrade
keeps it. Their bundles are generated with `--acknowledge-unrecommended-noda`. stage.toml lists them
in `keep_unrecommended_da_chain_ids`.

## Regenerating

```bash
L1_FORK_URL=<sepolia rpc> ../../../generate-chain-upgrades-stage.sh 2026-10-05
```

It forks Sepolia, applies the ecosystem upgrade (`apply-ecosystem-upgrade-to-fork.sh`), then runs
`protocol_ops chain set-upgrade-timestamp --upgrade-timestamp 1` and `protocol_ops chain upgrade` per
chain. It then emits `../simulator/<date>-v0.33.2-verifier-stage-2-chain-<id>.json` with
`protocol_ops ecosystem manifest-to-simulator --emulate-all-batches-executed-for <chain diamond>`.

## Executing, and rehearsing first

Each bundle is a Safe Transaction Builder file. Execute it with `protocol_ops dev execute-safe`, or
send its single transaction from the ChainAdmin owner. Run `01_` before `02_`.

The simulator walks scenario files alphabetically on one shared fork. The `-1-ecosystem` file must
therefore run before the `-2-chain-<id>` files: setting the timestamp needs the cut registered by
stage 1. `emulateAllBatchesExecutedFor` names the chain's diamond, because the `to` is the ChainAdmin.
That field, and the ecosystem file's `ack_test_upgrade_chain_zkos` marker, are supported by the
transaction-simulator branch `sb/v33-atomic-interop-testnet`, the same one the v33 testnet scenarios
need.
