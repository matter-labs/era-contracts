# Compact ZKIP settlement

The aggregate now exposes four statement digests as eight 128-bit public fields, instead of 64 inner
inputs and four VK commitments. L1 receives the four VK commitments separately and reconstructs each
statement from its authenticated state and the debit/claim submission. The [accounting design](../../protocol-docs/zkip-accounting-poc.md#compact-aggregated-settlement)
specifies the encoding and approval checks.

This removes 1,792 bytes from an otherwise identical aggregated submission. It preserves independent
stale-slot skipping, sequential updates within a window, approved-circuit checks and direct fallback.
The outer circuit performs extra Keccak work; this trades prover work for lower L1 calldata and public-input
processing. Keccak at this boundary is independent of the selected BLAKE2s source/finality hash.

## Results

Apple M2 Max, 32 GiB, four prover threads, Noir 1.0.0-beta.25 / bb 5.2.1. The same real four-statement
witness was used for both versions, with three sequential proof samples each. [Raw results](results/m2-max-settlement-2026-10-23.json)
include individual timings, artifact hashes, verifier runtime sizes and the registry comparisons.

| Aggregate                           |  Original |   Compact |
| ----------------------------------- | --------: | --------: |
| Gates                               | 3,015,574 | 3,402,153 |
| Median proving time                 |   21.68 s |   24.72 s |
| Proof bytes                         |    11,072 |    11,072 |
| Public-input bytes                  |     2,176 |       256 |
| Standalone verifier transaction gas | 1,061,143 | 1,029,055 |
| Verifier runtime bytes              |    17,752 |    18,073 |

Proving time increases **14%** and gates increase **12.8%**. Standalone verifier gas falls **3.0%**.
Both verifiers deploy under the default contract-size limit; every native sample verified, and both
final proofs verified in Solidity and rejected a changed public input.

The registry cases below add calldata and a 21k base to the measured E2E call gas. Their storage/account
warmth comes from the test harness, so these are comparisons rather than isolated transaction quotes.

| Window      | Original gas | Compact gas |         Saved |
| ----------- | -----------: | ----------: | ------------: |
| One debit   |    1,128,799 |   1,097,898 | 30,901 / 2.7% |
| Two debits  |    1,191,206 |   1,159,154 | 32,052 / 2.7% |
| Four debits |    1,303,442 |   1,264,926 | 38,516 / 3.0% |
| Two claims  |    1,218,478 |   1,178,089 | 40,389 / 3.3% |

Every comparable window removes exactly 1,792 calldata bytes. The full PoC suite passes **20 tests**
with real-proof flows covering changed digests, VK substitution, changed settlement data, malformed counts, stale
slots, mixed size classes, caps, execution gating and direct fallback. The existing **18 Python/Noir
accounting tests** also pass.

## BLAKE2s source-only capacity

A separate [single-sample capacity run](results/m2-max-blake2s-selected-2026-10-23.json) keeps the batch,
chain and shared settlement hashes as Keccak while using BLAKE2s for source commitments and compact
transfers. It verifies both proofs natively and in Solidity, including changed-public-input rejection.

| Circuit    |     Gates |   Prove | Proof bytes | Standalone verifier gas |
| ---------- | --------: | ------: | ----------: | ----------------------: |
| `debit_16` | 5,078,422 | 37.79 s |      11,456 |               1,042,735 |
| `claim_1`  | 1,246,628 | 11.21 s |      10,688 |                 993,375 |

The 16-leg outgoing batch amortizes to **65,171 verifier gas per debit** when full. The registry still
accepts at most four legs, so this is a capacity experiment, not an integrated size class. Claims,
registry work, STF settlement and aggregation are excluded. Source changes are still required; claim
anchors are synthetic. These single timing samples should not be used to rank hash algorithms across
separate runs. The earlier **4.32s** full BLAKE2s claim result additionally changes settlement hashes.

## Measurement scope

`settlement.py` builds the old aggregate from pinned commit
`4773253f074a69e9d091bfff116d62c49e1892fc` and the current aggregate in separate ignored workspaces.
It uses the same real recursive-proof witness for both, proves each repeatedly, verifies every sample
natively, and verifies the final samples in Solidity. The Solidity test also rejects a modified public input
and enforces the default contract-size limit.

Standalone verifier gas includes a cold verifier call, calldata at 4/16 gas per byte and the 21k transaction
base under Prague. It excludes the registry and production settlement. Registry comparisons, when logs
are supplied, use the existing Forge E2E call harness, including its warmed test state; adding calldata
and a transaction base does not turn that into an isolated cold transaction measurement.

## Reproduce

Set `NARGO`, `BB`, `BB_CRS` and `ZKIP_PROVER_THREADS=4` as described in [the benchmark instructions](README.md#reproduce).
Generate real recursive proofs and the aggregate witness:

```sh
cd zkip-poc/contracts
forge test --match-contract ZKIPAggE2ETest --threads 1 -vv > ../work/settlement-candidate.log
cd ../..
zkip-poc/work/venv/bin/python zkip-poc/benchmarks/settlement.py --threads 4 --repetitions 3
```

Run without other proving jobs when comparing time. Generated circuits, witnesses, native proofs,
Solidity verifiers and logs live under `zkip-poc/work/settlement-benchmarks/`.

For registry comparisons, run the same E2E cases at the pinned baseline in a separate checkout. Pass its
log and the current log with `--registry-baseline` and `--registry-candidate`. The baseline cases are
`test_aggDropsInvalidProofAndChecksCircuits`, `test_aggFourSlotsFromTwoChains`, and `test_aggSwapEndToEnd`.
The report retains each case's execution gas, calldata gas and byte count.

The source-only capacity sample is reproduced with:

```sh
zkip-poc/work/venv/bin/python zkip-poc/benchmarks/benchmark.py \
  --variants compact_blake2s_source --circuits debit_16 claim_1 --threads 4 --repetitions 1 --evm \
  --output zkip-poc/work/benchmarks/blake2s-selected-results.json
```

## Remaining costs

The fixed outer verifier, proof calldata, per-chain state writes, batch authentication and cap updates
remain. More statements per outer proof and more legs per inner statement amortize them. This change
does not implement a larger aggregate, integrate the benchmark-only 16-leg size class, or move the
production settlement trees behind a proof. Full BLAKE2s finality still requires that separate settlement
change; the 4.32s claim result is a circuit benchmark with synthetic anchors.
