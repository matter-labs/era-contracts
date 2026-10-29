# fed-l1: local anvil L1 with two ZKsync OS chains (301, 302) for a custom-STF host

`deploy.sh` starts anvil and deploys the era-contracts L1 ecosystem from this worktree
(`kelemeno/l1-deposits-via-interop` = draft v0.35.0 + `L1AssetRouter.depositViaInterop` /
`L1MessageRoot.commitL1Leg`) with the repo's own forge scripts. It then registers chains **301** and **302**,
which settle on L1, are ETH-based, use the mock-proof testnet verifier and the no-DA Validium pair, are
interop-enabled with their balances in the interop pool, and are each other's interop peers. It also deploys
USDC and DAI test tokens. A host then drives the chains through the `ValidatorTimelock`
(commit / prove / execute) with batches it computes itself. No server or L2 node is involved.

All paths below are relative to the repo root (`era-contracts-l1-interop/`). Line numbers are for commit `1b5047d63`.

## Running it

```bash
cd fed-l1
./deploy.sh                       # fresh anvil on :8545 (chain id 31337) + full deployment, ~20 s with a warm forge cache
FED_GENESIS_BATCH_HASH=0x<32 bytes> ./deploy.sh   # batch 0 stores YOUR genesis state commitment
./start.sh                        # restart anvil from out/state.json (post-deploy snapshot), no redeploy
kill $(cat out/anvil.pid)         # stop anvil
```

Prerequisites: `forge`/`anvil`/`cast` on PATH, `jq`, `python3` (3.9 is enough), `node` with `blakejs` in
`l1-contracts/node_modules` (the CTM script's blake2s FFI). The first run compiles the deploy scripts. After
that, forge's cache makes the whole run take about 20 s.

| env | default | meaning |
|---|---|---|
| `FED_L1_PORT` | `8545` | anvil port |
| `FED_L1_CHAIN_ID` | `31337` | anvil chain id. Must not be 1: the testnet verifiers assert `chainid != 1` |
| `FED_GENESIS_BATCH_HASH` | ZKsync OS `genesis_root` from `configs/genesis/zksync-os/latest.json` | batch 0 `StoredBatchInfo.batchHash` |
| `FED_GENESIS_ROLLUP_LEAF_INDEX` | `0` | batch 0 `indexRepeatedStorageChanges` |
| `FED_GENESIS_BATCH_COMMITMENT` | `1` | accepted only if 1, because the contracts hard-code it (see [Genesis values](#genesis-values)) |
| `FED_DUMMY_MESSAGE_ROOT=1` | off | deploy `DummyL1MessageRoot`, which skips L2->L1 Merkle-proof checks, instead of the real `L1MessageRoot` |
| `FED_SKIP_SMOKE=1` | off | skip the smoke tests |
| `FED_KEEP_ANVIL=0` | keep | stop anvil at the end |

anvil runs with automine (no block time), a 100M block gas limit, a zero base fee and `--auto-impersonate`
(the same settings as `l1-contracts/test/anvil-interop/src/daemons/anvil-manager.ts:105-125`). Its clock is
wall time. That matters because `commitBatches` computes `block.timestamp - 30 days` with checked arithmetic
(`l1-contracts/contracts/state-transition/chain-deps/facets/Committer.sol:218`), so don't start anvil with
`--timestamp 1`.

### What deploy.sh does

| Step | What runs |
|---|---|
| 1. Core | `DeployL1CoreContracts.runForAnvil()` deploys the core contracts: Bridgehub, real `L1MessageRoot`, L1AssetRouter, L1Nullifier, L1NativeTokenVault, L1InteropHandler, ChainRegistrationSender, ChainAssetHandler, CTMDeploymentTracker, Governance and the upgrade executor. The Bridgehub admin, a `ChainAdminOwnable`, is then accepted through impersonation. |
| 2. CTM | `script/FedDeployCTM.s.sol`, a 25-line subclass of `DeployCTMScript`, runs `runForAnvilTest(bridgehub)`. Its only change is to override `getChainCreationParamsConfig` with the `FED_GENESIS_*` values. The CTM is the multi-proof testnet configuration, as in the anvil-interop harness: `testnet_verifier = true` and `multi_proof_verifier = true`. That gives `MultiProofTestnetVerifier`, which wraps `MultiProofVerifier`, with an `EmptyContract` stand-in at `zisk_plonk_verifier_addr`. `RegisterCTM.runForTest` then registers it. This CTM hosts only 301 and 302. |
| 3. Tokens | USDC and DAI are `TestnetERC20Token`s with 18 decimals that anyone can mint. They are registered with `L1NativeTokenVault.registerToken`. Alice (#1) gets 1000 USDC and Bob (#2) gets 1000 DAI; both keep anvil's 10000 ETH. |
| 4. Chains | For each chain, `RegisterZKChain.runForTest(ctm, id)` registers it with base token ETH. That runs `Bridgehub.createNewChain`, the genesis upgrade, `MessageRoot.addNewChain` and `seedGenesisRoot`. The validator roles go to that chain's operator. The script then runs, per chain: `unpauseDeposits()` (new chains start paused, `l1-contracts/contracts/state-transition/ChainTypeManager.sol:707-710`), `setDAValidatorPair(ValidiumL1DAValidator, EMPTY_NO_DA)`, `L1MessageRoot.enableInterop(id, false)`, and `L1NativeTokenVault.moveChainBalanceToInteropPool(id, asset)` for ETH, USDC and DAI. |
| 5. Peers | `ChainRegistrationSender.allowInteropPeer(301, 302)` and `(302, 301)`. Each call enqueues one L2 service transaction (a priority op) on the chain it is called for. |
| 6. Output | Writes `out/addresses.json` and dumps the state to `out/state.json` with `anvil_dumpState`. |
| 7. Smoke tests | Run inside `evm_snapshot` and then `evm_revert`, so the chains stay at batch 0. `scripts/settle_empty_batch.py` commits, proves and executes batches 1 and 2 on both chains. It computes the commitment locally and checks it against `BlockCommit`; batch 2 consumes the queued priority op. Alice and Bob each `depositViaInterop` 100 USDC to 301 and 100 DAI to 302. |
| 8. Verification | Prints `Bridgehub.getZKChain` / `chainTypeManager`, `getTotalBatchesCommitted` (0) and `isInteropEnabled` for both chains, plus the genesis `StoredBatchInfo`. |

Forge only lets scripts write under `l1-contracts/script-out/` (`l1-contracts/foundry.toml` `fs_permissions`).
So the generated configs and outputs, and a copy of `FedDeployCTM.s.sol`, go to the gitignored
`l1-contracts/script-out/fed-l1/`, and then get copied to `fed-l1/out/`. Nothing under `l1-contracts/` that git
tracks is modified.

### Accounts (anvil default mnemonic)

| who | index | address | role |
|---|---|---|---|
| deployer | #0 | `0xf39F…2266` | Owner of Bridgehub, NTV, AssetRouter, MessageRoot and ChainRegistrationSender: their `transferOwnership` to Governance is a pending Ownable2Step transfer that is never accepted, as in the harness. Also admin of both diamonds (pending admin: `ChainAdminOwnable`, never accepted). |
| alice | #1 | `0x7099…79C8` | holds 1000 USDC and 10000 ETH |
| bob | #2 | `0x3C44…93BC` | holds 1000 DAI and 10000 ETH |
| operator 301 | #4 | `0x15d3…6A65` | committer, prover, executor, reverter and upgrader on the ValidatorTimelock for 301 |
| operator 302 | #5 | `0x9965…A4dc` | the same roles for 302 |

Private keys are in `addresses.json`.

### addresses.json

- **Top level:**
  - `contracts`: bridgehub, message_root (`L1MessageRoot`), l1_asset_router, l1_native_token_vault, l1_nullifier, l1_interop_handler, chain_registration_sender, chain_asset_handler, governance, bridgehub_admin, chain_type_manager, ctm_release, validator_timelock, validium_l1_da_validator.
  - `tokens`: eth / usdc / dai, each with its address and NTV asset id.
  - `accounts`: the accounts above, with keys and balances.
  - `ctm_genesis`.
- **`chains.<id>`, all read back from chain:**
  - Addresses and roles: `diamond_proxy`, `chain_admin`, `operator`, `operator_private_key`, `validator_timelock`.
  - Chain configuration: `base_token_asset_id`, `protocol_version`, `verifier`, `proof_mode`, `da_validator_pair`, `zksync_os_chain_config_hash`.
  - Genesis: `genesis_stored_batch_info` (all nine fields, checked against `storedBatchHash(0)`), `genesis_chain_batch_root`, `l2_system_contracts_upgrade_tx_hash` and `genesis_upgrade_event` (the raw `GenesisUpgrade` log).
  - Queues and interop state: `priority_queue.pending` (`NewPriorityRequest` log data with id and canonical hash), `message_root`, `interop_pool`, `interop_peers_allowed`.

## Calling the chain

The diamond's validator is the `ValidatorTimelock` (a `MultisigCommitter` proxy, with execution delay 0 and
signing threshold 0). The operator EOA calls these functions on it, and the timelock forwards them to the diamond:

```solidity
// l1-contracts/contracts/state-transition/validators/ValidatorTimelock.sol:279, :315, :325
function commitBatchesSharedBridge (address chain, uint256 from, uint256 to, bytes data); // also MultisigCommitter.sol:75, threshold must be 0
function proveBatchesSharedBridge  (address chain, uint256 from, uint256 to, bytes data);
function executeBatchesSharedBridge(address chain, uint256 from, uint256 to, bytes data);
```

`chain` is `chains.<id>.diamond_proxy`. `scripts/settle_empty_batch.py` is a working, cast-only reference
for all three encodings below.

### Structs

```solidity
// l1-contracts/contracts/state-transition/chain-interfaces/IExecutor.sol:29-39
struct StoredBatchInfo {
    uint64  batchNumber;
    bytes32 batchHash;                  // ZKsync OS: full state commitment (newStateCommitment)
    uint64  indexRepeatedStorageChanges;// 0 (genesis: release value)
    uint256 numberOfLayer1Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;             // the CHAIN BATCH ROOT, see below
    uint256 timestamp;                  // always 0
    bytes32 commitment;                 // full (unshifted) public-input hash
}
// l1-contracts/contracts/state-transition/chain-interfaces/ICommitter.sol:30-49
struct CommitBatchInfoZKsyncOS {
    uint64  batchNumber;
    bytes32 newStateCommitment;
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;
    L2DACommitmentScheme daCommitmentScheme; // uint8 in the ABI; EMPTY_NO_DA = 1
    bytes32 daCommitment;
    uint64  firstBlockTimestamp;
    uint64  firstBlockNumber;
    uint64  lastBlockTimestamp;
    uint64  lastBlockNumber;
    uint256 chainId;
    bytes   operatorDAInput;
    uint256 slChainId;
    bytes32 chainConfigHash;
    uint256 interopFeeUnits;
}
// l1-contracts/contracts/state-transition/libraries/PriorityTree.sol:16-20
struct PriorityOpsBatchInfo { bytes32[] leftPath; bytes32[] rightPath; bytes32[] itemHashes; }
// l1-contracts/contracts/common/Messaging.sol:147-154
struct InteropRoot { uint256 chainId; uint256 blockOrBatchNumber; uint256 timestamp; bytes32[] sides; }
// enum L2DACommitmentScheme { NONE, EMPTY_NO_DA, PUBDATA_KECCAK256, BLOBS_AND_PUBDATA_KECCAK256, BLOBS_ZKSYNC_OS }
// l1-contracts/contracts/common/Config.sol:49-55
```

### Wire encodings (`l1-contracts/contracts/state-transition/libraries/BatchDecoder.sol`)

Each payload is one version byte followed by standard ABI encoding:

| call | data | cite |
|---|---|---|
| commit | `0x06 ‖ abi.encode(StoredBatchInfo lastCommitted, CommitBatchInfoZKsyncOS[] newBatches)` | `:32`, `:50-58`. Exactly one batch per commit (`Committer.sol:99-101`). Version 5 (without `interopFeeUnits`) is retired. |
| prove | `0x01 ‖ abi.encode(StoredBatchInfo prev, StoredBatchInfo[] batches, uint256[] proof)` | `:26`, `:112-120` |
| execute | `0x02 ‖ abi.encode(DecodedExecuteData)`, where `DecodedExecuteData = (StoredBatchInfo[] batchesData, PriorityOpsBatchInfo[] priorityOpsData, InteropRoot[][] dependencyRoots)` | `:29`, `:168-187` |

Execute is the encoding of **one tuple argument**, so it starts with a `0x20` head offset. In cast that is
`cast abi-encode "f(((..)[],(..)[],(..)[][]))" "(...)"`. `from`/`to` must equal the first and last
`batchNumber` in the array (`IncorrectBatchBounds`).

### Commit: what is checked (`Committer.sol`)

- The chain's protocol version is active on the CTM (`:85-87`).
- `lastCommitted` hashes to `storedBatchHashes[totalBatchesCommitted]`, where the hash is `keccak256(abi.encode(StoredBatchInfo))` (`:103`, `l1-contracts/contracts/state-transition/chain-deps/facets/ZKChainBase.sol:238-255`, `l1-contracts/contracts/state-transition/chain-deps/StoredBatchHashing.sol:9-11`).
- `batchNumber == prev + 1` (`:165-167`).
- `chainConfigHash == getZKsyncOSChainConfigHash()` (`:169-172`). The value is `keccak256(abi.encodePacked(chainId, 0, uint256(maxTxGasLimit = 2^24), uint256(pubdataContent = 0), uint256(l1TxFiltering), uint256(largeContracts)))` (`ZKChainBase.sol:205-217`). Read it from the getter; it is stored as `zksync_os_chain_config_hash`.
- **DA** (`:179-210`). `ValidiumL1DAValidator.checkDA` requires `operatorDAInput.length == 32` and ignores the content (`l1-contracts/contracts/state-transition/data-availability/ValidiumL1DAValidator.sol:9-27`). Use `operatorDAInput = abi.encode(bytes32(0))`, `daCommitmentScheme = 1` (it must equal the stored scheme, `:230-232`) and `daCommitment = 0`. `daCommitment` is not checked, but it enters the output hash. This pair needs no blobs and no calldata, which makes it the cheapest valid option. `setDAValidatorPair` only checks `RollupDAManager` for permanent rollups (`l1-contracts/contracts/state-transition/chain-deps/facets/Admin.sol:387-401`), and these chains are not permanent rollups.
- Timestamps: `firstBlockTimestamp >= block.timestamp - 30 days`, `lastBlockTimestamp <= block.timestamp + 1 h`, and `first <= last` (`:218-226`; `l1-contracts/contracts/common/Config.sol:95-99`). There is no check against the previous batch.
- `chainId == s.chainId` and `slChainId == block.chainid` (31337) (`:227-235`). `firstBlockNumber <= lastBlockNumber` is checked too, but not trusted (`:272-274`).
- Nothing about priority ops or dependency roots is checked at commit. They are only stored, and checked at execute.

**Stored result** (`:244-259`):

```
StoredBatchInfo{batchNumber, batchHash: newStateCommitment, 0, numberOfLayer1Txs, priorityOperationsHash,
                dependencyRootsRollingHash, l2LogsTreeRoot, timestamp: 0, commitment}
```

`storedBatchHashes[n] = keccak256(abi.encode(that))` (`:136`) and `interopFeeUnits[n]` are written, and
`BlockCommit(n, batchHash, commitment)` is emitted. In the event, all three are indexed, so the commitment is
`topics[3]`.

### Batch hash and public input

Both are computed by L1, in `Committer.sol:291-328`:

```
batchOutputHash = keccak256(abi.encodePacked(
    uint64  firstBlockTimestamp,   // 8 bytes
    uint64  lastBlockTimestamp,    // 8 bytes
    uint256 daCommitmentScheme,
    bytes32 daCommitment,
    uint256 numberOfLayer1Txs,
    uint256 numberOfLayer2Txs,
    bytes32 priorityOperationsHash,
    bytes32 l2LogsTreeRoot,
    bytes32 upgradeTxHash,         // s.l2SystemContractsUpgradeTxHash for the first batch after genesis/upgrade, else 0
    bytes32 dependencyRootsRollingHash,
    uint256 slChainId,
    uint256 interopFeeUnits))

commitment = keccak256(abi.encodePacked(prevBatch.batchHash, newStateCommitment, chainConfigHash, batchOutputHash))
```

`upgradeTxHash` is non-zero for exactly one batch: the first one committed while
`l2SystemContractsUpgradeTxHash != 0` and `l2SystemContractsUpgradeBatchNumber == 0`. For these chains that is
batch 1 (`:105-129`). The hash is cleared once that batch is executed (`Executor.sol:207-211`).

**Prove** (`l1-contracts/contracts/state-transition/chain-deps/facets/Executor.sol:215-251`) checks that `prev`
hashes to `storedBatchHashes[totalBatchesVerified]` and that each batch hashes to its stored hash. It then sets
the public inputs to `uint256(commitment_i)` and calls `verifier.verify(publicInputs, proof)`.

### Mock proof

The chains' verifier is `MultiProofTestnetVerifier`
(`l1-contracts/contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol`). It accepts two kinds of
fake proof:

- **Empty proof.** `proof = []` is accepted unconditionally (`:33-35`).
- **Type-3 mock proof** (`:38-40`, `:76-98`): `proof = [3, 0, 13, fold >> 32]`.
  - `fold = commitment_0` for a single batch, or `uint256(keccak256(abi.encodePacked(commitment_0..n)))` for several.
  - `PUBLIC_INPUT_SHIFT = 32` (`l1-contracts/contracts/common/Config.sol:102`).
  - Word 1 (the "carried hash") must be 0 (`NonZeroCarriedHash`).

Anything else is passed to the real `MultiProofVerifier` (proof types 2 and 5), which fails on these chains.
`getProofMode()` reports 5 (multi-proof). The second proof system is **not** required, because interop was
enabled with `requireSecondProofSystem = false`.

### Execute: what is checked (`Executor.sol`)

For each batch:

1. `addChainBatchRootV32(chainId, n, l2LogsTreeRoot)` on the MessageRoot (`:163-166`, `:192-194`), which runs before anything else.
2. `itemHashes.length == numberOfLayer1Txs` (`:92-94`).
3. The rolling hash of `itemHashes` equals the stored `priorityOperationsHash` (`:95`, `:48-55`, `:70-72`).
4. The dependency roots' rolling hash equals the stored one (`:96`, `:73-78`, `:117-158`).
5. The batch is the next one to execute, and its hash matches (`:65-69`).
6. `priorityTree.processBatch` (`l1-contracts/contracts/state-transition/libraries/PriorityTree.sol:83-96`).
7. `l2LogsRootHashes[n] = l2LogsTreeRoot` (`:103`).
8. The interop fee is charged if `interopFeeUnits != 0` (`:105-113`). Use 0: the fee manager is a no-op at fee 0, and the units are only bound by a real proof.
9. Finally, `totalBatchesExecuted <= totalBatchesVerified` (`:203-205`).

**Priority ops**

- Each queued op's hash is `keccak256(abi.encode(L2CanonicalTransaction))` (`l1-contracts/contracts/state-transition/chain-deps/facets/Mailbox.sol:305-344`). It is emitted in `NewPriorityRequest(txId, txHash, 0, tx, factoryDeps)` from the diamond (`Mailbox.sol:369`) and pushed into the priority tree (`:373-378`). `addresses.json` → `priority_queue.pending` lists the queued ops.
- `priorityOperationsHash` starts at `keccak256("")`, and each op folds in as `h = keccak256(abi.encode(h, opHash))` (`Executor.sol:48-55`). For no ops it is `0xc5d2…a470`.
- `PriorityOpsBatchInfo` must prove `itemHashes` at `[unprocessedIndex, unprocessedIndex + len)` against **some historical root** of the priority tree (`PriorityTree.sol:83-96`).
  - **Tree shape.** The tree is a `DynamicIncrementalMerkle`: keccak pairs, `zero[0] = keccak256("")`, `zero[i+1] = keccak(zero[i] ‖ zero[i])` (`PriorityTree.sol:22`, `:58-63`). After `k` pushes its height is `ceil(log2 k)`, and 0 when k = 1 (`l1-contracts/contracts/common/libraries/DynamicIncrementalMerkle.sol:92-135`). The root after every push is historical (`PriorityTree.sol:52-56`).
  - **The paths.** `leftPath` and `rightPath` must both have length equal to the height of the tree size you prove against. `leftPath[l]` is the left sibling of the range start at level `l`, used when the start index is odd at that level. `rightPath[l]` is the right sibling of the range end, used when the end is unpaired, with zero-padding past `k` (`l1-contracts/contracts/common/libraries/Merkle.sol:79-122`).
  - **Single op.** Empty paths are allowed only for start 0 with exactly 1 item, which is the current state of both chains (`Merkle.sol:94`).
- **The queue never blocks commits.** Batches with `numberOfLayer1Txs = 0` commit and execute while ops are queued: nothing at commit or execute requires the queue to drain, and the smoke test does exactly this. The only lever a queued op has is Priority Mode. Activating it requires `canBeActivated` and a permanent rollup (`Admin.sol:524-530`), and neither holds for these Validium chains.
- The genesis upgrade tx is **not** a priority op. It is only bound through `upgradeTxHash` in batch 1's output hash.

**Dependency roots** (`Executor.sol:117-158`)

- **Nothing imported.** Commit `dependencyRootsRollingHash = 0` and execute with `dependencyRoots[i] = []`.
- **L1 roots imported.** Each entry must be `InteropRoot{chainId: 31337 (L1 = block.chainid), blockOrBatchNumber: L1 block number, timestamp, sides: [root]}`. `root` and `timestamp` must equal `L1MessageRoot.historicalRoot(blockNumber)` (`l1-contracts/contracts/core/message-root/MessageRootBase.sol:223-230`). Any other `chainId` reverts with `CommitBasedInteropNotSupported`.
- **Rolling hash.** It starts at `bytes32(0)`, **not** `keccak("")`: `h = keccak256(abi.encodePacked(h, chainId, blockOrBatchNumber, timestamp, sides))`, where `sides` is packed as its 32-byte words.
- **Which block.** `historicalRoots[block.number]` is rewritten on every shared-tree update: chain creation, each executed batch, and each `commitL1Leg`. Read the final root of a block after it is mined (`protocol-docs/message-root.md:34-38`).

### Chain batch root and L2->L1 logs tree

`l2LogsTreeRoot` in both structs is the **chain batch root**, not the raw logs root
(`protocol-docs/message-root.md:77-91`; `l1-contracts/contracts/common/libraries/ChainBatchRootTree.sol`).

- **Formula.** It is a fixed height-3 tree: `root = keccak(keccak(keccak(L0‖L1) ‖ keccak(L2‖L3)) ‖ RESERVED_SUBTREE_NODE)` (`:49-62`).
  - The leaves are L0 = logs root, L1 = the chain's multichain root (0 for these chains), L2 = interop commitment tree root at batch begin, L3 = the same root at batch end (`:13-25`).
  - `RESERVED_SUBTREE_NODE = 0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30` (`:29`).
- **Genesis value.** `genesisChainBatchRoot() = compute(0, 0, EMPTY_IMT_ROOT, EMPTY_IMT_ROOT)` with `EMPTY_IMT_ROOT = keccak256(96 zero bytes) = 0x46700b4d…8c21` (`:35-42`). It equals `0x1d57c24629c4445766683a9843cae545c6fe1f8f35159aca41f2a38b7b227885`, stored as `genesis_chain_batch_root`.
- **What MessageRoot checks** (`MessageRootBase.sol:183-197`): the root is non-zero, it was not recorded before, and the batch number is exactly `currentChainBatchNumber + 1`. There is no interop gating here, and no check of the root's structure: any non-zero value settles. The smoke test reuses the genesis root for its empty batches.
- **Logs tree.** Leaves are `keccak256(abi.encodePacked(uint8 shardId, bool isService, uint16 txNumberInBatch, address sender, bytes32 key, bytes32 value))`, 88 bytes (`l1-contracts/contracts/common/libraries/MessageHashing.sol:64-66`; `l1-contracts/contracts/common/Config.sol:24`). The empty leaf is `keccak256(88 zero bytes) = 0x72ab…43ba` (`Config.sol:27`).
  - ZKsync OS uses a **fixed depth of 14** (16384 leaves), padding with empty-subtree hashes, so an empty batch's logs root is `emptySubtree[14]`, not 0. That constant lives in the zksync-os sources (`zk_ee` `logs_storage.rs`), not in this repo.
  - L1 hard-codes no depth: the proof metadata carries the leaf path length (`MessageHashing.sol:101-142`). Use the depth your STF uses, consistently.
  - The default leaf is rejected as a proven leaf (`MessageHashing.sol:165`).
- **Proofs against executed batches.** Withdrawal and message proofs check against `chainBatchRoots[chain][n]`, which is written at execute.

### Genesis values

| batch 0 field | value | source |
|---|---|---|
| `batchHash` | `FED_GENESIS_BATCH_HASH`, else `genesis_root` of `configs/genesis/zksync-os/latest.json` | Read by `l1-contracts/deploy-scripts/ctm/ChainCreationParamsLib.sol:23`, overridden in `fed-l1/script/FedDeployCTM.s.sol`, stored in the CTMRelease manifest (`l1-contracts/deploy-scripts/ctm/DeployCTMUtils.s.sol:226-227`). `ChainTypeManager.storedBatchZero` reads it back (`l1-contracts/contracts/state-transition/ChainTypeManager.sol:329-347`). |
| `indexRepeatedStorageChanges` | `FED_GENESIS_ROLLUP_LEAF_INDEX` (default 0) | Same manifest field (`DeployCTMUtils.s.sol:227`). The stock scripts never set it, so it is 0 upstream. |
| `numberOfLayer1Txs` / `timestamp` / `dependencyRootsRollingHash` | 0 | `ChainTypeManager.sol:334-344` |
| `priorityOperationsHash` | `keccak256("")` | `ChainTypeManager.sol:338` |
| `l2LogsTreeRoot` | **0** (`DEFAULT_L2_LOGS_TREE_ROOT_HASH`) | `ChainTypeManager.sol:339`; `Config.sol:18` |
| `commitment` | **1**, not configurable | `GENESIS_BATCH_COMMITMENT`: `ChainTypeManager.sol:344`; `Config.sol:21`. The deploy-script value (`ChainCreationParamsLib.sol:24`) is not used by the contract. |

The stored struct is `s.storedBatchHashes[0] = ctm.storedBatchZero()` (`l1-contracts/contracts/state-transition/chain-deps/DiamondInit.sol:122-126`).

Two values are separate from the stored `l2LogsTreeRoot = 0`, and both stay at the standard ZKsync OS
`genesisChainBatchRoot()`:

- The chain's `l2LogsRootHash(0)`, the genesis **chain batch root**, is set in `DiamondInit.sol:138`.
- `seedGenesisRoot` copies it into `MessageRoot.chainBatchRoots[id][0]` and the chain tree (`MessageRootBase.sol:296-314`, called from `l1-contracts/contracts/core/bridgehub/L1Bridgehub.sol:135`).

So: commit batch 1 with `lastCommitted = genesis_stored_batch_info` exactly. `commitment(1)` then uses
`prev.batchHash = your genesis root`.

**Genesis upgrade tx hash (`l2_system_contracts_upgrade_tx_hash`)**

| chain | hash |
|---|---|
| 301 | `0x3c97a91bbbbd4a25a2ad92394239583b592247d79bbc6e86ebf1b7593d38c455` |
| 302 | `0xf8a633e15d7cfdd06ece771ec0a7f55df0eaa84605a903c10a28fe75867125dd` |

- **Where it comes from.** `createNewChain` runs `Admin.genesisUpgrade` (`Admin.sol:599-609`), which delegatecalls `L1GenesisUpgrade`. That builds a type-126 L2 upgrade tx and emits `GenesisUpgrade(diamond, tx, protocolVersion, [])` (`l1-contracts/contracts/upgrades/L1GenesisUpgrade.sol:35-51`). It stores `keccak256(abi.encode(tx))` (`l1-contracts/contracts/upgrades/BaseZkSyncUpgrade.sol:162-201`).
- **Can it be zero?** No, not without contract changes. A hash is zero only when `txType == 0` (`:168-170`), and `L1GenesisUpgrade` always builds a real tx.
- **What it means for the host.** Batch 1's output hash must use this value as `upgradeTxHash`. With mock proofs, that only matters if you compute the commitment yourself. You can also read it from `BlockCommit`. With real proofs, your STF must commit to it.
- **Stability.** The value is deterministic per (chain id, CTM deployment).

## Interop and deposits

- **Gating** (`protocol-docs/interop-gating.md#order-per-chain`):
  - Steps 1-3 do not apply: chains created on this release are never backfill-pending (`chainBalanceBackfillPending = false`).
  - Step 4 (second proof system) is waived: `enableInterop(id, false)` (`l1-contracts/contracts/core/message-root/L1MessageRoot.sol:83-100`).
  - Step 6 ran for ETH, USDC and DAI. Because the chains are enabled, every flow, including withdrawals of tokens received over interop, counts against the shared interop pool (`INTEROP_POOL_CHAIN_ID`), not a per-chain cap.
  - Step 7 ran both ways. `allowInteropPeer` needs both chains enabled and the peer to have a leaf in its chain tree; `seedGenesisRoot` already provides that (`l1-contracts/contracts/core/chain-registration/ChainRegistrationSender.sol:77-93`, `:164`).
- **The two queued ops.** Each chain has one queued priority op, `L2Bridgehub.allowInteropPeer(peer, ETH asset id)`, from `SERVICE_TRANSACTION_SENDER`. As shown above, it does not block anything. A custom STF may process it, or skip it with `numberOfLayer1Txs = 0` indefinitely.
- **`depositViaInterop(chainId, assetId, transferData, lowNullifierIndex)`** (`l1-contracts/contracts/bridge/asset-router/L1AssetRouter.sol:260-309`):
  - **Arguments.** `transferData = abi.encode(uint256 amount, address l2Receiver, address l1Token)`, which must be exactly 96 bytes (`l1-contracts/contracts/common/libraries/DataEncoding.sol:51-60`). The depositor first approves the **NTV** for the amount.
  - **Requirements.** The destination must settle on L1 and the asset must not be its base token, so ETH is excluded on these ETH-based chains (`AssetIdNotSupported`). USDC and DAI are NTV assets, so the handler restriction passes (`:382-394`). Deposits being paused does not matter: this path does not use the Mailbox.
  - **What it does.** It calls `L1MessageRoot.commitL1Leg(commitValue, lowNullifierIndex)` (`L1MessageRoot.sol:108-131`). That inserts into L1's indexed commitment tree and settles an L1 "batch" whose chain batch root is `compute(0, 0, imtBegin, imtEnd)`, with chain id 31337 at shared-tree index 0.
  - **`lowNullifierIndex`.** This is the index of the predecessor leaf (the largest existing value below the new commit value) in that sorted IMT. Index 0 is the sentinel. Both smoke deposits used 0, which only works while it is the predecessor. A host should look it up with `l1CommitmentTreeLeafCount` / `l1CommitmentTreeLeafAt` (`protocol-docs/message-root.md:60-75`).
  - **Consuming it on the L2.** The destination batch must import an L1 interop root from a block at or after the commit (dependency root as above, chain id 31337). Then `executeAtomicBundle` on L2 proves L1's end IMT root (`protocol-docs/interop.md:264-293`). L1 legs pass every receive filter, so no peer entry is needed for L1.
  - `InteropDepositCommitted(chainId, bundleHash, l1BatchNumber, flowPreimage, bundle)` carries what the L2 executor needs.

## Not done / caveats

- **Genesis tx is not replayed.** No L2 exists, so nothing replays the genesis upgrade tx or the priority ops. They are only on L1, in `addresses.json` (raw logs).
- **Ownership is left with the deployer.** Pending ownership and admin transfers (to Governance and `ChainAdminOwnable`) are left unaccepted, as in the repo's anvil harness. The deployer EOA is the effective owner and chain admin. `RegisterCTM.runForTest` is the test path: the deployer calls the Bridgehub directly, not through Governance.
- **A multi-proof verifier stands in for the single ZKsync OS testnet verifier.** The CTM uses the multi-proof testnet verifier because that is the harness configuration. Mock and empty proofs work either way; type-2/5 real proofs would fail against the ZiSK stand-in.
- **Addresses are deterministic for a given build and genesis hash.** Changing `FED_GENESIS_BATCH_HASH` changes the CTMRelease, and therefore some CTM-side addresses. Always read `addresses.json`.
