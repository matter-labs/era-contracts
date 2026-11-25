# Batch mirror: following a ZKsync OS chain from a chain it does not settle on

`ZKsyncOSBatchMirror` keeps a verified copy of one ZKsync OS chain's executed batches on an EVM chain that
the chain does not settle on, so that the messages the chain sends can be proven there with the standard
`MessageRoot.proveL2MessageInclusionShared`. A typical host is an institution's own EVM ledger following the
institution's ZKsync OS chain, which settles on a shared settlement layer: the ledger acts as a _mirror
settlement layer_ of that chain. Nothing changes for the followed chain or its real settlement layer.

The mirror is verify-only. It never sees the followed chain's priority queue, DA or the settlement layer's
`MessageRoot`; it replays the settlement layer's own commit and prove calldata and re-runs every check of
those steps that does not depend on the settlement layer's state. The commitment code it uses is the
`CommitterFacet`'s own (`ZKsyncOSBatchCommitment`), so a mirrored batch's `StoredBatchInfo` and its hash are
byte-identical to the settlement layer's.

## Mirroring a range

A validator of the mirror (its relayer) calls `mirrorBatches` with the calldata of one
`proveBatchesSharedBridge` call of the settlement layer, the calldata of each `commitBatchesSharedBridge`
call that committed the proved batches, and the system upgrade transaction hash each batch was committed
with (the settlement layer reports it in `ReportCommittedBatchProtocolVersion`). The mirror:

1. Requires every non-zero upgrade transaction hash to be the one the owner set with
   `setL2SystemContractsUpgradeTxHash`, and uses it up, as the settlement layer's `CommitterFacet` uses its
   `l2SystemContractsUpgradeTxHash` for one batch.
2. Decodes the proof data with `BatchDecoder` and requires its range to start right after the newest
   mirrored batch and to hold one batch per commit.
3. Requires the proof's previous batch to hash to the newest mirrored batch's stored hash. The first
   range continues from the anchor: the `StoredBatchInfo` the mirror is initialized with, trusted once
   like a genesis.
4. For every commit, decodes it with `BatchDecoder`, requires exactly one batch (as the settlement
   layer's committer does), requires its previous batch to hash to the batch before, and requires its
   `chainId` to be the followed chain, its `slChainId` to be the followed chain's real settlement layer
   (not the mirror's host chain), and its `chainConfigHash` to match the configuration the owner set.
5. Recomputes the batch's `StoredBatchInfo` with `ZKsyncOSBatchCommitment.storedBatchInfo`, as the
   settlement layer's `CommitterFacet` did, and requires the proof's batch to hash to it.
6. Verifies the proof with the configured verifier against the recomputed commitments, exactly the
   public input the settlement layer's `ExecutorFacet` passes. The verifier is called by the mirror, so a
   `MultiProofVerifier` reads the mirror's `disabledProofSystems()`, which the owner keeps equal to the
   followed chain's.
7. Stores each batch's hash and chain batch root, and appends the root to the host chain's `MessageRoot`
   with `addChainBatchRootV32`, as the settlement layer's executor does at execution.

The chain batch root is not a public input of the proof on its own; only the commitment binds it.
Recomputing the commitment from the commit data is what keeps a relayer from pairing a proof with a root
other than the one the proved batch produced.

## What the mirror does not check

A proof says that the batch's state transition was computed correctly from the inputs it was given. It
does not say that those inputs were legitimate. On the settlement layer that is checked when the batch is
committed and executed, against the settlement layer's state, and the mirror skips all of those checks:

- at commit, the DA validator, the DA commitment scheme, the commit timestamp window and priority mode;
- at execution, the priority operations: `ExecutorFacet` recomputes the batch's `priorityOperationsHash`
  from the settlement layer's priority tree and checks `numberOfLayer1Txs` against it;
- at execution, the imported interop roots: `ExecutorFacet` checks every root behind the batch's
  `dependencyRootsRollingHash` against the settlement layer's `MessageRoot.historicalRoot`.

The commit-time checks are about what the settlement layer accepts. The execution-time checks are about
whether the batch is part of the chain's real history. The mirror takes a batch's priority operations and
imported interop roots as the commit data states them, so it accepts a proved batch that the settlement
layer would refuse to execute.

The upgrade transaction is the one input of this kind that the mirror does check: the settlement layer
accepts only the hash governance set, and the mirror only the hash its owner set.

## What the mirror trusts

The mirror trusts its validators, its owner and its proxy admin for soundness, not only for liveness.

**Validators.** A validator that can produce a proof can mirror a batch the settlement layer would never
execute. Proving is open: anyone with the prover and the followed chain's previous state can prove a
batch, and with the testnet verifier no prover is needed at all. Such a batch can contain made-up priority
transactions, which carry no signatures and an arbitrary `from`, or made-up imported interop roots. Through
either it can make any account on the followed chain, system contracts included, send any L2->L1 message.
Those messages land in the host chain's `MessageRoot` and pass `proveL2MessageInclusionShared` like real
ones. So the validators must mirror only batches the settlement layer executed, read at a final block of
the settlement layer. The same rule covers reverts: a second valid batch at the same height exists in
practice when the settlement layer reverts committed but unexecuted batches (`revertBatchesSharedBridge`).
Mirroring is append-only, like execution: a mirrored batch cannot be removed from the mirror or from the
`MessageRoot`.

**Owner.** The owner can replace the verifier, add validators, switch off ZiSK and change the
configuration, the settlement layer and the upgrade transaction the mirror expects, all without a delay.
Any of these makes the mirror accept any batch root. The settlement layer gates the same powers more
tightly: a chain's verifier changes only in a governance upgrade, and while a second proof system is
required, only the Bridgehub owner can switch ZiSK off. The mirror does not copy that ZiSK check, since an
owner that can replace the verifier gains nothing from it.

**Proxy admin.** The proxy admin can replace the mirror's code, and with it everything the mirror checks.

The owner and the proxy admin should therefore be the same governance the host chain's users already rely
on for the host chain's Bridgehub and `MessageRoot`, behind a timelock where the host chain has one. When
the validators, the owner and the proxy admin all belong to the institution that runs the followed chain,
as with an institution's own ledger, that institution relies on nobody but itself.

Narrowing the validators' power without the settlement layer's state is not cheap. Rejecting batches
with priority transactions or imported interop roots would stop the mirror following any chain that
receives deposits or takes part in interop, since those batches carry both in ordinary operation. Closing
the gap needs the settlement layer's state on the host chain, i.e. a light client of the settlement layer:
a storage proof of its `storedBatchHashes(n)` and `totalBatchesExecuted` against a settlement-layer state
root the host chain trusts. Such a proof shows that the settlement layer executed the batch, which covers
both the execution-time checks and reverts. Because the mirror's stored hashes are byte-identical to the
settlement layer's, the check can be added to `mirrorBatches` later without changing what is stored. It is
not cheap on a host chain that has no view of the settlement layer's consensus, so the mirror relies on its
validators for now.

## Registration in the host chain's Bridgehub

The mirror's batch roots reach the host chain's `MessageRoot` through the same path as a settling chain's.
The host chain runs a Bridgehub and a `MessageRoot`, the mirror is deployed behind a proxy, and the
Bridgehub owner registers it as the followed chain's ZK chain with `registerAlreadyDeployedZKChain`. The
mirror implements the getters that registration reads (`getChainId`, `getChainTypeManager`, `getAdmin`,
`getBaseTokenAssetId`, `getBridgehub`, `getTotalBatchesExecuted`), and the `MessageRoot` registers the chain
at the anchor's batch number, so the first mirrored batch is the next consecutive root. From then on the
mirror is the address `addChainBatchRootV32` accepts for the chain, and proofs need no new code: a message
proof that ends at the chain batch root (`zks_getL2ToL1LogProof` for a chain settling on its settlement layer
directly) is checked against `chainBatchRoots`.

A host chain that also runs the interop contracts (`InteropCenter`, `InteropHandler`, the asset router and
the native token vault) runs the L2 flavour of the Bridgehub and the `MessageRoot` at their built-in
addresses, because those contracts read the L2 Bridgehub, for example its `isPeerAllowed`. So
`registerAlreadyDeployedZKChain` lives in `BridgehubBase` and works on both flavours; before the mirror it
existed on `L1Bridgehub` only, and an L2 Bridgehub registered chains only through the chain asset handler
when they migrated. The mirror's tests run against both flavours.

The alternative, a `MessageRoot` extension where an owner names a batch-root source per chain, was rejected.
Both options change a core contract. Registration moves one existing owner-only function from
`L1Bridgehub` to the base contract, with no new storage or role, and keeps a single way for any chain to
reach the `MessageRoot`: the Bridgehub's `getZKChain`. The extension would add storage and an owner to the
`MessageRoot`, which has neither, a second way for roots to enter it, and it would still need the Bridgehub
for `addNewChain`. Registration also gives the host chain the same view of the followed chain that a
settlement layer has, read through the same Bridgehub as everything else on it.

The cost is on every chain that runs the L2 Bridgehub: its owner, the aliased L1 governance on a ZKsync
chain, can now register a chain directly. Governance can already do so on L1, and on an L2 through an
upgrade. Before registering the mirror, the Bridgehub owner must also register a chain type manager and the
followed chain's base token asset ID. The registration is permanent, which is why the mirror sits behind a
proxy.

Messages in the anchor batch cannot be proven, since its root is not appended. The mirror is not a diamond, so the
Bridgehub paths that call into a chain's diamond, such as requesting an L2 transaction on the followed chain from the
host chain, revert for it.

## Keeping up with the followed chain

The mirror's owner follows the followed chain's administrative changes; until it does, `mirrorBatches`
reverts:

- `setZKsyncOSChainConfig` when the chain's runtime configuration changes ([chain config](./chain-config.md)),
  since every batch commits to it;
- `setVerifier` when the chain's verifier changes in a protocol upgrade;
- `setL2SystemContractsUpgradeTxHash` when a protocol upgrade of the chain carries a system upgrade
  transaction, before the batch that runs it is mirrored;
- `setProofSystemStatus` when the chain's ZiSK switch changes
  ([multi-proof verification](./multi-proof-verification.md));
- `setSettlementLayerChainId` when the chain migrates to another settlement layer, after the last batch
  committed on the old one is mirrored;
- a proxy upgrade when a protocol upgrade changes the commit or prove encoding or the commitment.
