# Per-chain v31 → v33 upgrade calldata (testnet)

The ecosystem ceremony in `../ecosystem.toml` registers the diamond cut on the ZKsync OS CTM.
It does not move any chain. Each chain then takes the cut itself, through its own ChainAdmin.

This directory holds one bundle per chain that can take it today.

| chain   | ChainAdmin (the `to`)                        | signer (ChainAdmin owner)                    |
| ------- | -------------------------------------------- | -------------------------------------------- |
| 4221    | `0x82b6590f23591a6be0f0434e681a038467f21900` | `0x5555555590930f501c88B73Ea43B3EEb5A71643c` |
| 42111   | `0x4e48a5152f8d705073b5accccaf234571b2a0621` | `0x397aA1340b514cB3Ef8f474dB72b7E62c9159c63` |
| 579029  | `0x0c39098d6a7e7287db4a2ae5bad67c9ef76eb265` | `0x5555555590930f501c88B73Ea43B3EEb5A71643c` |
| 8022833 | `0x3b7a24e583867ab85694cf55941734653bdfab9c` | `0xd64e136566a9E04eb05B30184FF577F52682D182` |

Each is a single `ChainAdmin.multicall` (`0x69340beb`) wrapping
`upgradeChainFromVersion(0x1f00000001, cut)`.

**The upgrade timestamp is deliberately not here.** `ServerNotifier.setUpgradeTimestamp` announces
when a chain may take the cut, and the value is a rollout-time decision, so a committed bundle
would carry a stale one. Generate it when you roll out:

```bash
protocol_ops chain set-upgrade-timestamp --env testnet --chain-id <id> \
  --upgrade-timestamp <unix-seconds> --l1-rpc-url <l1-rpc> --out <dir>
```

It must run **before** the cut — `setUpgradeTimestamp` requires `ctm.upgradeCutHash(oldVersion)`
to exist, which stage 1 of the ecosystem ceremony puts there.

## The four preconditions

`V32UpgradeZKsyncOS` and its `DefaultUpgradeZKsyncOS` base check all of these, in this order:

1. `baseTokenHasTotalSupply` — the v31 base-token backfill was _requested_.
2. `PriorityOpLowerBound.recorded(chain)` — a priority-op count was pinned while that flag was set.
3. `getFirstUnprocessedPriorityTx() >= lowerBound(chain)` — proving the backfill _executed_, since
   v33 removes its L2 entry point.
4. `totalBatchesCommitted == totalBatchesExecuted` — the release installs a new verifier, so
   batches still awaiting proof under the old one would stop being provable.

Separately, the cut is registered against **exactly** `oldProtocolVersion = 0x1f00000001` (v0.31.1)
with no deadline, so a chain on any other version cannot consume it.

## Status of every chain on the ZKsync OS CTM

**Ready — bundle in this directory (4):** 4221, 42111, 579029, 8022833.

**Eligible, bundle needs one decision first (4):** 1401, 1913, 88288, 8022834. All four are
validium-priced with an `EmptyNoDA` scheme, and the generator refuses to guess:

> this upgrade would take chain N to v33 committing FullPubdata while its DA scheme is EmptyNoDA —
> batches in that state do not prove.

See "Validium chains" below.

**Eligible but blocked (1):** 278701 is on **v0.31.0**, and the cut is keyed to v0.31.1. Its bound
is recorded and its queue and batches are clean; it needs the v0.31.0 → v0.31.1 patch first, or a
cut registered for its version.

**Cannot be initialised at all (16):** 1326, 1327, 2905, 7186, 17218, 17219, 17986, 29538, 36900,
272363, 579028, 788621, 7187817, 7567979, 8022832, 531050204. All are pre-v31 (v0.29.x / v0.30.x)
and do not have `baseTokenSupportsTotalSupply()` — the diamond reverts with `F`, so
`lowerBoundPriorityOp` cannot even reach its eligibility check. They must reach v31 first. Chain
301 is on the EraVM CTM, which this release does not touch at all.

Precondition 2 needs no action anywhere: every eligible chain is **already recorded** in
`PriorityOpLowerBound` (`0xba83ba8d227550d446D4013428a9a6B2a898C018`). Calling it again reverts
`LowerBoundAlreadyRecorded()` (`0xe4623697`).

## Generating a bundle for another chain

The generator replays the cut against a fork, so the fork must already have the ecosystem upgrade
applied — a plain Sepolia fork does not, because the ceremony has not executed on chain yet.

```bash
# 1. Fork with impersonation.
anvil --port 29761 --fork-url "$SEPOLIA_RPC" --auto-impersonate --silent &

# 2. Apply the governance ceremony, so ctm.upgradeCutHash(0x1f00000001) exists.
#    `ecosystem upgrade-governance` cannot do this: it runs all three stages with no wall time
#    between them and always dies on stage 1's checkDeadline(). This drives the calls directly
#    and advances the fork clock in between.
RPC=http://127.0.0.1:29761 \
ECOSYSTEM_TOML=<abs path>/output/testnet/ecosystem.toml \
GOVERNANCE=0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D \
  bash apply-ecosystem-upgrade-to-fork.sh

# 3. Generate. Omit every DA flag to leave the chain's DA setup untouched.
protocol_ops chain upgrade --env testnet --chain-id <id> \
  --l1-rpc-url http://127.0.0.1:29761 --out <dir>
```

A run that leaves DA alone prints `DA after the upgrade: pair unchanged, pubdata content
unchanged`. Anything else means the command changed the chain's DA posture — check that you meant
it.

### If it fails with `NotAllBatchesExecuted()`

Precondition 4 is a point-in-time property, and a live chain sits with a few committed-but-unexecuted
batches most of the time — the counters here moved between two reads minutes apart. It is not a
permanent blocker: the executor catches up continuously.

For **generation** you can advance the fork to the state a drained executor produces. This changes
nothing in the emitted calldata — the bundle is `upgradeChainFromVersion(oldVersion, cut)` either
way — it only lets the generator's replay get past the check:

```bash
D=$(cast call <bridgehub> "getZKChain(uint256)(address)" <id> --rpc-url $RPC)
CM=$(cast storage $D 13 --rpc-url $RPC)      # 13 = totalBatchesCommitted
cast rpc anvil_setStorageAt $D 0xb $CM --rpc-url $RPC   # 11 = totalBatchesExecuted
cast rpc anvil_setStorageAt $D 0xc $CM --rpc-url $RPC   # 12 = totalBatchesVerified
cast rpc evm_mine --rpc-url $RPC                        # the inner fork must see it
```

**On the real chain this precondition is not negotiable** — execution reverts unless it genuinely
holds. Time the rollout for a moment when it does, or let the executor drain first.

### Validium chains (1401, 1913, 88288, 8022834)

These publish no pubdata today (`EmptyNoDA`). v33 would have them commit `FullPubdata`, which does
not prove, so the generator requires an explicit choice. Both of these were verified to produce a
bundle; which one is right is the chain owner's call, not the tool's.

**Recommended — deliver the log region through blobs:**

```bash
protocol_ops chain upgrade --env testnet --chain-id <id> --l1-rpc-url $RPC --out <dir> \
  --da-mode logs-only-validium --l1-da-validator 0x5DF2dB3EAf761f2FB5C1ba045222310b9CD1457F
# -> pair validator 0x5df2db3e… + scheme BlobsZKSyncOS, pubdata content LogsOnly
```

This starts posting blobs, so it costs more than today.

**Preserve today's posture — still publish nothing:**

```bash
protocol_ops chain upgrade --env testnet --chain-id <id> --l1-rpc-url $RPC --out <dir> \
  --da-mode logs-only-validium --l1-da-validator 0x5DF2dB3EAf761f2FB5C1ba045222310b9CD1457F \
  --l2-da-commitment-scheme discouraged-empty-no-da --acknowledge-unrecommended-noda
# -> pair validator 0x5df2db3e… + scheme EmptyNoDA, pubdata content LogsOnly
```

The flag name is the warning: no data is delivered, so nobody can reconstruct state from L1.

`0x5DF2dB3EAf761f2FB5C1ba045222310b9CD1457F` is the L1 DA validator these four already run — v33
deploys no new DA validators (`DefaultCTMUpgrade.prepareDAValidatorCall` is empty), so there is no
newer one to move to.

## Executing, and rehearsing first

Each bundle is a Safe Transaction Builder file signed by the ChainAdmin owner in the table above.
Execute with `protocol_ops dev execute-safe`, or import it into the Safe UI.

To rehearse against a fork first, convert to a transaction-simulator scenario:

```bash
protocol_ops ecosystem manifest-to-simulator --manifest <dir>/manifest.json \
  --tag chain_upgrade_<id> --emulate-all-batches-executed-for <chain diamond> --out <scenario>.json
```

The simulator shares one fork across scenario files and walks them in alphabetical order, so a
chain scenario must sort **after** the ecosystem one — otherwise the cut it consumes has not been
registered yet. That is what the `-1-` / `-2-` prefixes on the committed scenarios are for.
