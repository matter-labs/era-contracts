# ZKIP-lite: proof of concept

An experimental proof of concept for ZKIP, an asset-accounting proof that each chain produces next to its STF proof:

- it tracks the chain's **private interop balance**;
- a batch that sends interop legs can execute only once its debit is proven;
- a chain can count a received leg only once both legs of the flow are final on L1.

Statements reach L1 one by one, or several at once in one aggregated proof.

**Status: research code.**

This branch adds composable multi-chain accounting aggregation and private chain-admission membership, on top of proof-carried IMT checks and compact settlement inputs. See the
[accounting design](../protocol-docs/zkip-accounting-poc.md) and [benchmark instructions](benchmarks/README.md).

- It is not wired into the Executor or the native token vault: `contracts/src/mocks/` stands in for them.
- It is not audited, and it is excluded from the repository's lint.
- Nothing outside `zkip-poc/` depends on it.

## Design

- **Public L1 flows stay under per-chain caps** (the native token vault's per-chain balances).
  - ZKIP does not re-prove deposits or withdrawals.
  - A debit's `lock` and a claim's `unlock` move value between a chain's public cap and its private interop balance.
  - `MockCaps` stands in for the vault.
- **Debits.** A batch that appended legs to the chain's interop commitment tree (the IMT) gets one debit proof, and
  `onExecute` refuses to execute it without one.
  - **L1 checks** the batch root and continuity. The circuit proves every insertion from the batch's IMT begin
    root to its end root; the stored starting leaf count is public, while values and paths are private.
  - **The circuit** opens each value to its 1,600-byte bundle and the flow preimage, decodes the asset-router call, and
    debits the amount.
  - Batches without legs need no proof.
- **Claims.** A claim credits up to two received legs. For each, the circuit proves that both legs of the flow are final
  on L1, against message-root anchors that L1 supplies: the IMT path, the chain batch root, the chain tree and the
  shared tree.
  - The legs must be final before the deadline, and both source chains must be ZKIP chains.
  - A consumed-leg tree prevents double credits.
  - Finality is proved inside the circuit, so L1 never learns which chains interoperate.
- **Private state.** A Poseidon2 root over 8 asset slots and an indexed Merkle tree of consumed legs. Protocol data
  (bundles, flow preimages, the IMT and the message-root trees) is hashed with keccak, exactly as the L1 and L2
  contracts hash it.
- **Proofs.**
  - **Circuits:** Noir 1.0.0-beta.25.
  - **Proof system:** Barretenberg (`bb`) 5.2.1 UltraHonk with zero-knowledge, EVM target, with a universal setup, so
    no per-circuit ceremony.
  - **On L1:** bb's generated, optimized Solidity verifiers (`contracts/src/verifiers/`).
  - **Size classes:** debits of up to 1 or 4 legs (`debit_1`, `debit_4`), claims of up to 1 or 2 credits (`claim_1`,
    `claim_2`).
- **Aggregation.** Chains provide zero-knowledge accounting proofs to an untrusted aggregator.
  - `agg_4` and the fixed `agg_16` experiment support small-window comparisons.
  - The composable path uses `agg_leaf` (up to four accounting proofs), `agg_fold` (up to four recursive
    nodes of different heights), and `agg_finalize` (one EVM wrapper). A node can represent any number
    of enabled chains and accounting statements, within the documented depth/transaction limits.
  - Independently produced per-chain nodes can be combined without the underlying accounting proof files.
    The final proof always has six public fields. L1 authenticates its ordered statement-tree root, then
    applies current statements with approved keys; stale/revoked slots are skipped independently.
  - Claim source membership is private against a depth-32 admitted-chain tree, replacing the four-chain list.
  - **Privacy:** aggregators learn the public accounting statements, not private balances, paths or counterparties.
  - **Fallback:** a chain omitted by an aggregator can still submit directly.
  - [Settlement measurements](benchmarks/SETTLEMENT.md) describe the earlier compact four-slot change;
    [multi-chain measurements](benchmarks/MULTICHAIN.md) cover the larger wrapper and composable tree.

## Layout

| Path              | What                                                                                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `circuits/`       | Noir workspace: the `zkip_lite` library, the `debit_1`, `debit_4`, `claim_1`, `claim_2` circuits (each pair differs only in `N`) and fixed-window/composable aggregation circuits |
| `prover/prove.py` | Prover bridge for the tests (vm.ffi): builds the private witness, runs nargo and bb, writes VKs and verifiers (`setup`), and aggregates fixed windows or recursive nodes      |
| `contracts/src/`  | `ZKIPLiteRegistry` (submissions, execute gate), `ImtInsertion`, errors, mocks, generated verifiers                                                                   |
| `contracts/test/` | End-to-end tests on real proofs                                                                                                                                      |
| `work/`           | Generated VKs, proofs and timings (ignored)                                                                                                                          |

## Running it

You need nargo 1.0.0-beta.25, bb 5.2.1 and a bb CRS with at least 2^22 points. The tools are found on `PATH`, or
through these variables:

| Variable              | Meaning                                                                      |
| --------------------- | ---------------------------------------------------------------------------- |
| `NARGO`, `BB`         | the binaries                                                                 |
| `BB_CRS`              | the CRS directory; default `~/.bb-crs`                                       |
| `ZKIP_PROVER_THREADS` | prover threads; default 14                                                   |
| `ZKIP_CMD_WRAPPER`    | a command every nargo and bb call runs under, e.g. a network-denying sandbox |

```bash
cd zkip-poc && python3 -I prover/prove.py setup
```

```bash
cd zkip-poc/contracts && forge test --threads 1 -vv
```

`setup` compiles the circuits, writes the VKs to `work/vk/`, and regenerates the verifiers, which must come out
identical to the committed ones. The tests prove every statement for real: the 11 direct-path tests take ~2 minutes on
an Apple M4 Max, and the 4 aggregation tests ~5. `foundry.toml` uses Prague gas pricing. Add `--evm-version osaka` for today's mainnet pricing.

## Tests

| Test                                                                     | What it shows                                                                                                                                                                           |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_swapEndToEnd`                                                      | Chain A swaps 60 USDC for B's 25 EURC. Both debits are proven and both claims credited with in-circuit finality, then B withdraws on L1. A second credit of the same leg is unprovable. |
| `test_multiLegBatchAndBatchedClaims`                                     | A 3-leg batch (`debit_4`), then two credits in one claim (`claim_2`) and one in `claim_1`                                                                                               |
| `test_overdraftIsUnprovableAndBlocksExecution`                           | A debit beyond the locked balance has no proof, so its batch never executes                                                                                                             |
| `test_batchWithoutLegsNeedsNoProof`                                      | A batch without legs executes with no ZKIP proof                                                                                                                                        |
| `test_gateGasForBatchWithoutLegs`, `test_gateGasForFurtherBatchInSameTx` | Gas of the execute gate                                                                                                                                                                 |
| `test_imtContinuityIsEnforcedOnL1`                                       | Debit proofs must chain over the leg batches in order                                                                                                                                   |
| `test_proofBoundToPublicInputs`                                          | A valid proof submitted with different public data is rejected                                                                                                                          |
| `test_lateLegCannotBeCredited`                                           | A counter-leg settled after the deadline doesn't make the flow final                                                                                                                    |
| `test_nonZkipLegSourceCannotBeCredited`                                  | A leg from a chain that isn't a ZKIP chain can't be credited                                                                                                                            |
| `test_unknownAnchorRejected`                                             | Anchors must be existing L1 message roots                                                                                                                                               |
| `test_aggSwapEndToEnd`                                                   | The same swap with one aggregated proof per window: both debits in one, both claims in the next. A tampered public input fails verification.                                            |
| `test_aggFourSlotsFromTwoChains`                                         | One proof carries 4 debits from 2 chains, 2 batches each. Slots apply in order, so a chain's second batch builds on its first.                                                          |
| `test_aggDropsInvalidProofAndChecksCircuits`                             | The aggregator drops a corrupted proof and aggregates the rest. A revoked circuit's slot is skipped, and the dropped chain proves directly.                                             |
| `test_aggStaleSlotIsSkipped`                                             | A slot made stale by a direct submission is skipped; the other slot applies, and nothing applies twice                                                                                  |

## Original PoC measurements

The numbers below are the original #2630/#2631 baseline, before proof-carried insertions. They do not measure
this branch's revised debit path. Updated comparisons are recorded under `benchmarks/`.

These are from an Apple M4 Max. L1 gas is per submission: execution plus calldata plus the 21k base, at Osaka
pricing.

| Circuit   | Gates | Rows | Prove, 4 threads | Prove, 14 threads | Peak RAM | Proof   | L1 gas          |
| --------- | ----- | ---- | ---------------- | ----------------- | -------- | ------- | --------------- |
| `debit_1` | 0.33M | 2^19 | 3.7 s            | 2.3 s             | 0.63 GB  | 9.9 KB  | ~1.03M          |
| `debit_4` | 1.31M | 2^21 | 13.0 s           | 8.2 s             | 2.5 GB   | 10.7 KB | ~1.11M (3 legs) |
| `claim_1` | 1.96M | 2^21 | 19.2 s           | 12.1 s            | 3.6 GB   | 10.7 KB | ~1.06–1.10M     |
| `claim_2` | 3.92M | 2^22 | 36.5 s           | 28.1 s            | 7.0 GB   | 11.1 KB | ~1.13M          |

- **Verifier:** ~0.76–0.82M execution plus ~0.16M of calldata per proof. The rest is L1 bookkeeping, the largest part
  being ~19k gas per leg for the IMT insertion checks.
- **Execute gate:** ~16k gas for the first batch of an execute transaction, ~7.7k for each further one.
- **Aggregation** (`agg_4`):
  - 3,015,574 gates (2^22 rows); 20.7 s at 4 threads and 11–13 s at 14 threads, in 5.2 GB. The cost is the same
    however many slots are filled.
  - **L1, one aggregated proof at Prague pricing** (Osaka adds ~8k):
    - ~1.15M with 1 statement;
    - ~1.21–1.23M with 2;
    - ~1.36M with 4, i.e. ~0.34M per statement.

    That's ~1.08M fixed plus ~0.07M per statement. A lone statement is cheaper submitted directly.

- **Where the gates go:**
  - keccak-f1600 costs 17,380 gates and Poseidon2 73.
  - A leg's 1,600-byte bundle hash is ~0.22M gates.
  - Claims are dominated by the finality paths: ~46 keccak-f per leg.

## Limitations

- **Mocks.** The caps, message root and chain contract are mocks. Wiring ZKIP into the Executor, the native token
  vault and the message root is not done.
- **Fixed circuit sizes:**
  - IMT depth 16, chain-tree depth 18, shared-tree depth 7;
  - a consumed-leg tree of depth 24 and 8 asset slots;
  - one bundle layout: ERC20 legs through the asset router.
- **Refunds** of expired flows aren't covered.
- **L1 cost.** A direct proof costs ~1M gas on L1, and a full aggregated window ~0.34M per statement.
- **Practical capacity.** Recursive aggregation has a height limit of 30; admission has depth 32. L1 work and calldata still grow with exposed updates. These are PoC limits, not a production deployment.
