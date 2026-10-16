# Per-chain v0.33.0 → v0.33.2 calldata (testnet)

The emergency proposal in `../emergency-upgrade-board.json` registers the cut on the ZKsync OS CTM. It does
not move any chain. Each chain then takes the cut itself, through its own ChainAdmin.

Each `<id>/` holds two bundles, **in execution order**, and the `EXECUTE.md` runbook for them:

1. `01_chain.set-upgrade-timestamp`: `ServerNotifier.setUpgradeTimestamp(chainId, 1)`
2. `02_chain.upgrade`: `upgradeChainFromVersion(chain, 0x2100000000, cut)`

Both are `ChainAdmin.multicall` (`0x69340beb`), signed by that ChainAdmin's owner. Every cut bundle is
byte-identical to `[chain_upgrades.<id>].chain_admin_calldata` in `../ecosystem.toml`;
`generate-chain-upgrades.sh testnet` and `rehearse.sh testnet` both check it.

| chain   | ChainAdmin (the `to`)                        | signer (ChainAdmin owner)                    | DA today (unchanged by the upgrade) |
| ------- | -------------------------------------------- | -------------------------------------------- | ----------------------------------- |
| 1913    | `0xa7f9a1a7b6b68fbf68adc938104a096006794ad7` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium, blobs, logs-only pubdata  |
| 4221    | `0x82b6590f23591a6be0f0434e681a038467f21900` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | rollup, blobs, full pubdata         |
| 42111   | `0x4e48a5152f8d705073b5accccaf234571b2a0621` | `0x397aa1340b514cb3ef8f474db72b7e62c9159c63` | rollup, blobs, full pubdata         |
| 88288   | `0xf3b67c6e88bb7ab3721d0cfa47c024f08f0f2476` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium, blobs, logs-only pubdata  |
| 579029  | `0x0c39098d6a7e7287db4a2ae5bad67c9ef76eb265` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | rollup, blobs, full pubdata         |
| 8022833 | `0x3b7a24e583867ab85694cf55941734653bdfab9c` | `0xd64e136566a9e04eb05b30184ff577f52682d182` | rollup, blobs, full pubdata         |
| 8022834 | `0xf87e2fb52ab4769bf60b04d4c7ad311048858230` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium, blobs, logs-only pubdata  |

### The order is load-bearing

`setUpgradeTimestamp` keys the timestamp on the chain's protocol version **at the time of that call**. Run
the cut first and the timestamp lands under v0.33.2, so the server never sees one for the upgrade the chain
just took. As for the v33 testnet bundles, the timestamp is `1`: "no waiting", since 0 is the unset sentinel
and is rejected.

### Precondition: no batches in flight

`DefaultUpgradeZKsyncOS.upgrade` reverts with `NotAllBatchesExecuted()` unless
`totalBatchesCommitted == totalBatchesExecuted`: the new verifier would otherwise be asked to verify batches
proven for the old VK. Time each chain's cut for a moment when its executor has caught up. At the
rehearsal's fork block only 1913 was idle.

To get past this check, the generator advances the generation fork's batch counters for chains with batches
in flight, as the v33 testnet README describes. That fork is never a real network, and the emitted calldata
does not depend on it.

### DA: left alone

The cut sets no DA. protocol-ops reports `pair unchanged, pubdata content unchanged` for all seven chains.
The three validium chains already commit the log region and deliver it through blobs, the recommended setup,
so none needs `--acknowledge-unrecommended-noda`.

## Regenerating

```bash
L1_FORK_URL=<sepolia rpc> ../../../generate-chain-upgrades.sh testnet 2026-10-16
```

It forks Sepolia, applies the ecosystem upgrade (`apply-ecosystem-upgrade-to-fork.sh testnet`, the 13
emergency transactions), then runs `protocol_ops chain set-upgrade-timestamp --upgrade-timestamp 1` and
`protocol_ops chain upgrade` per chain, and emits `../simulator/<date>-v0.33.2-verifier-testnet-2-chain-<id>.json`
with `protocol_ops ecosystem manifest-to-simulator --emulate-all-batches-executed-for <chain diamond>`. It needs
upstream forge >= 1.8.3 (Glamsterdam, see `../../../README.md`).

## Executing, and rehearsing first

Follow `<id>/EXECUTE.md` from the ChainAdmin owner in MetaMask, or load the Safe Transaction Builder files.
Run `01_` before `02_`.

The simulator walks scenario files alphabetically on one shared fork, so the `-1-ecosystem` file runs before
the `-2-chain-<id>` files: setting the timestamp needs the cut registered by stage 1.
`emulateAllBatchesExecutedFor` names the chain's diamond, because the `to` is the ChainAdmin.
