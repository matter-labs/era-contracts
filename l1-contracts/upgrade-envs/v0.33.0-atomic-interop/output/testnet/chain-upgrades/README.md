# Per-chain v31 → v33 upgrade calldata (testnet)

The ecosystem ceremony in `../ecosystem.toml` registers the diamond cut on the ZKsync OS CTM.
It does not move any chain. Each chain then takes the cut itself, through its own ChainAdmin.

This directory holds two bundles per chain, **in execution order**:

1. `01_chain.set-upgrade-timestamp` — `ServerNotifier.setUpgradeTimestamp(chainId, 1)`
2. `02_chain.upgrade` — `upgradeChainFromVersion(0x1f00000001, cut)`

Both are `ChainAdmin.multicall` (`0x69340beb`), signed by that ChainAdmin's owner.

| chain   | ChainAdmin (the `to`)                        | signer (ChainAdmin owner)                    | DA after the upgrade          |
| ------- | -------------------------------------------- | -------------------------------------------- | ----------------------------- |
| 1401    | `0x18ce0cfa990c024262257e6e4d1d3b5c9c49bfa9` | `0xd41efa366a514c91fcf8dee3cb2b302953078343` | validium → LogsOnly via blobs |
| 1913    | `0xa7f9a1a7b6b68fbf68adc938104a096006794ad7` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium → LogsOnly via blobs |
| 4221    | `0x82b6590f23591a6be0f0434e681a038467f21900` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | rollup → unchanged            |
| 42111   | `0x4e48a5152f8d705073b5accccaf234571b2a0621` | `0x397aa1340b514cb3ef8f474db72b7e62c9159c63` | rollup → unchanged            |
| 88288   | `0xf3b67c6e88bb7ab3721d0cfa47c024f08f0f2476` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium → LogsOnly via blobs |
| 579029  | `0x0c39098d6a7e7287db4a2ae5bad67c9ef76eb265` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | rollup → unchanged            |
| 8022833 | `0x3b7a24e583867ab85694cf55941734653bdfab9c` | `0xd64e136566a9e04eb05b30184ff577f52682d182` | rollup → unchanged            |
| 8022834 | `0xf87e2fb52ab4769bf60b04d4c7ad311048858230` | `0x5555555590930f501c88b73ea43b3eeb5a71643c` | validium → LogsOnly via blobs |

### The order is load-bearing

`setUpgradeTimestamp` keys the timestamp on `chainTypeManager.getProtocolVersion(chainId)` — the
chain's version **at the time of that call**. Run the cut first and the chain is already on v33, so
the timestamp lands under the wrong version and the server never sees one for the upgrade it just
took.

### Why the timestamp is 1, not 0

The intent is "no waiting", but `setUpgradeTimestamp` rejects 0 outright with
`ZeroUpgradeTimestamp()`: `protocolVersionToUpgradeTimestamp` defaults to 0, so storing 0 would be
indistinguishable from never having set it. `1` is the nearest value carrying the intended meaning
— a Unix timestamp in 1970, unconditionally in the past, so no chain waits.

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

**Bundles here (8):** 1401, 1913, 4221, 42111, 88288, 579029, 8022833, 8022834.

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

## DA: what the upgrade does to pubdata

The five rollup-priced chains keep what they have — `pair unchanged, pubdata content unchanged`.

The four validium-priced chains publish nothing today (`EmptyNoDA`), and v33 would have them commit
`FullPubdata`, which does not prove. So they name a DA mode, and the bundles here take the
recommended posture: **pubdata content `LogsOnly`, delivered through blobs**.

That combination is the **default derived from the mode** — you do not pass a scheme:

- `PubdataContent::from_da_and_vm_types(LogsOnlyValidium, ZKSyncOsVM)` → `LogsOnly`
- `L2DACommitmentScheme::from_da_and_vm_types(LogsOnlyValidium, ZKSyncOsVM)` → `BlobsZKSyncOS`

as the comment on the second one puts it: _"a logs-only validium delivers less pubdata, not none:
the log region — with the interop commitment tree leaves in it — reaches L1 through the same blobs
a rollup uses, unless the caller names another scheme."_

Two caveats on "default", both checked here:

- **`--da-mode` itself has no default.** Omit it on a validium chain and the generator refuses
  rather than guessing: _"this upgrade would take chain N to v33 committing FullPubdata while its
  DA scheme is EmptyNoDA — batches in that state do not prove."_ The mode must be named; the scheme
  and content then follow from it.
- **It only holds for an L1-settling chain.** `L2DACommitmentScheme::for_gateway_settling` maps
  `LogsOnlyValidium` to `EmptyNoDA` instead. All eight chains here report
  `settlementLayer == 11155111` (L1), so `BlobsZKSyncOS` is what they get.

`0x5DF2dB3EAf761f2FB5C1ba045222310b9CD1457F` is the L1 DA validator these four already run — v33
deploys no new DA validators (`DefaultCTMUpgrade.prepareDAValidatorCall` is empty), so there is no
newer one to move to.

**This starts posting blobs on chains that post nothing today, so it costs more than today.** To
keep the current no-DA posture instead, add
`--l2-da-commitment-scheme discouraged-empty-no-da --acknowledge-unrecommended-noda`; the flag name
is the warning, since nobody can then reconstruct state from L1.

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

# 3. Timestamp first, then the cut.
protocol_ops chain set-upgrade-timestamp --env testnet --chain-id <id> \
  --upgrade-timestamp 1 --l1-rpc-url http://127.0.0.1:29761 --out <dir>

protocol_ops chain upgrade --env testnet --chain-id <id> \
  --l1-rpc-url http://127.0.0.1:29761 --out <dir> \
  # validium-priced chains only:
  --da-mode logs-only-validium --l1-da-validator 0x5DF2dB3EAf761f2FB5C1ba045222310b9CD1457F
```

Check the `DA after the upgrade:` line the second command prints. `pair unchanged, pubdata content
unchanged` means it left the chain's DA alone; anything else means it changed the posture, so make
sure you meant it.

### If it fails with `NotAllBatchesExecuted()`

Precondition 4 is a point-in-time property, and a live chain sits with a few
committed-but-unexecuted batches most of the time — the counters here moved between two reads
minutes apart. It is not a permanent blocker: the executor catches up continuously.

For **generation** you can advance the fork to the state a drained executor produces. This changes
nothing in the emitted calldata — the bundle is `upgradeChainFromVersion(oldVersion, cut)` either
way — it only lets the generator's replay get past the check:

```bash
D=$(cast call <bridgehub> "getZKChain(uint256)(address)" <id> --rpc-url $RPC)
CM=$(cast storage $D 13 --rpc-url $RPC)                 # 13 = totalBatchesCommitted
cast rpc anvil_setStorageAt $D 0xb $CM --rpc-url $RPC   # 11 = totalBatchesExecuted
cast rpc anvil_setStorageAt $D 0xc $CM --rpc-url $RPC   # 12 = totalBatchesVerified
cast rpc evm_mine --rpc-url $RPC                        # the inner fork must see it
```

**On the real chain this precondition is not negotiable** — execution reverts unless it genuinely
holds. Time the rollout for a moment when it does, or let the executor drain first.

## Executing, and rehearsing first

Each bundle is a Safe Transaction Builder file signed by the ChainAdmin owner in the table above.
Execute with `protocol_ops dev execute-safe`, or import it into the Safe UI. Run `01_` before `02_`.

Every chain here already has a committed transaction-simulator scenario, one file per chain, in
`../simulator/2026-09-04-v33-atomic-interop-testnet-2-chain-<id>.json`. They are regenerated with:

```bash
protocol_ops ecosystem manifest-to-simulator --manifest <dir>/manifest.json \
  --network sepolia --tag chain_upgrade_<id> \
  --descriptions ../../sim-descriptions.toml \
  --emulate-all-batches-executed-for <chain diamond> --out <scenario>.json
```

Three things about those files:

- **Order.** The simulator shares one fork across scenario files and walks them in alphabetical
  order, so a chain scenario must sort **after** the ecosystem one — otherwise the cut it consumes
  has not been registered yet. That is what the `-1-` / `-2-` prefixes are for. The chains are
  independent of each other, so their relative order does not matter.
- **`emulateAllBatchesExecutedFor`.** Set to the chain's own DiamondProxy, not the `to` of the
  transaction: the `to` is the ChainAdmin, and the batch counters that precondition 4 reads live on
  the diamond.
- **Descriptions.** `sim-descriptions.toml` carries a label per ChainAdmin plus two entries per
  chain, told apart by the inner selector — `0xe2a9d554` for the timestamp and `0x3b6d7534` for the
  cut, since both arrive as `ChainAdmin.multicall`. Without them every line reads `[unlabelled]`,
  which is what a reviewer would have to decode by hand.
