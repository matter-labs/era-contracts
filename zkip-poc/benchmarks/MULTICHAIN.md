# Multi-chain recursive aggregation

Research code only, stacked on the compact four-slot settlement PoC. No production Executor, vault,
STF verifier or message-root changes are included. Source/finality roots retain protocol Keccak;
BLAKE2s migration remains the separate experiment described in [README.md](README.md).

## Fixed sixteen-statement capacity measurement

Apple M2 Max, 32 GiB, four prover threads, pinned Noir 1.0.0-beta.25 / bb 5.2.1. Sixteen actual one-leg **debit
statements** from four chains, four batches each, use the same inner accounting proofs in both paths.
This is not sixteen completed two-leg swaps, nor does it include claims or STF settlement.

| Path | Submission gas | Calldata bytes | Final proof bytes | Public fields |
| --- | ---: | ---: | ---: | ---: |
| Four `agg_4` windows | 5,381,067 | 54,672 | 44,288 total | 32 total |
| One `agg_16` wrapper | 1,735,675 | 20,228 | 11,072 | 33 |

Savings: 67.75% gas; roughly 3.10× less. Each total includes measured registry call gas, calldata at
4/16 gas per byte, and 21,000 base gas per submission. The existing Forge call harness warms storage
and verifiers; these are **not isolated cold transaction costs or production fees**. The same circuit
and application states are used for both paths through real contract calls and snapshot/revert.

The serial aggregation stage took 131.05 seconds, excluding accounting proof production; its final
EVM proving step took 22.56 seconds. Each recursive four-proof job produces a 14,656-byte intermediate
proof. Parallel child production is possible but was not timed here. These are single samples.

## Composable tree

`agg_leaf` / `agg_fold` share six public fields and the final `agg_finalize` EVM proof verifies a single
root node. A node represents ordered statements across any enabled chains. Different-height per-chain
nodes can be folded together; every proving job has at most four children. Root/shape authentication
keeps L1 updates tied to the proven statements and preserves independent stale-slot handling.

The end-to-end test uses **17 outgoing debit statements from five chains**, with five batches on one
chain and three on each other chain. Each chain first produces a recursive node. The global aggregator
reads only these node proofs and public attachments; the attachments omit accounting proof paths.
It compares one final wrapper with five `agg_4` windows over exactly the same accounting proofs.
After execution it completes a real incoming claim whose source is the fifth registered chain.

Composable test measurements: pending the current real-proof run. The final public-input vector is six
fields regardless of count. Calldata, state writes and batch checks still grow with statement count.
Maximum node height is 30 (at most 4^31 statements); admitted-chain tree capacity is 2^32. Real L1
transaction gas limits are much tighter. Aggregation amortizes the fixed verifier cost, not all costs.

## Reproduce

Set tool paths and CRS as in [README.md](README.md#reproduce), with `ZKIP_PROVER_THREADS=4`, then:

```sh
cd zkip-poc
python3 -I prover/prove.py setup
cd contracts
forge test --match-test test_agg16FourChainsAgainstFourSeparateWindows --threads 1 -vv
forge test --match-test test_recursiveIndependentFiveChainsSeventeenStatements --threads 1 -vv
```

Prover timings are appended to `work/metrics.jsonl`. Keep other proving jobs stopped when measuring.
To combine independently produced nodes, pass `{"nodes":[{"dir":"..."}, ...]}` to `aggregate-node`
(recursive output) or `aggregate-recursive` (EVM output). For raw accounting proofs, use
`{"slots":[{"circuit":"debit_1","dir":"...","settlement":{...}}, ...]}` instead.
The public settlement attachments are untrusted: L1 reconstructs each current statement and compares
its digest before applying it. Proof-input inclusion does not guarantee that stale attachments settle.
