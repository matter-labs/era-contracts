# Multi-chain recursive aggregation

Research code only, stacked on the compact four-slot settlement PoC. No production Executor, vault,
STF verifier or message-root changes are included. Source/finality roots retain protocol Keccak;
BLAKE2s migration remains the separate experiment described in [README.md](README.md).

## Fixed sixteen-statement capacity measurement

Apple M2 Max, 32 GiB, four prover threads, pinned Noir 1.0.0-beta.25 / bb 5.2.1. Sixteen actual one-leg **debit
statements** from four chains, four batches each, use the same inner accounting proofs in both paths.
This is not sixteen completed two-leg swaps, nor does it include claims or STF settlement.

| Path                 | Submission gas | Calldata bytes | Final proof bytes | Public fields |
| -------------------- | -------------: | -------------: | ----------------: | ------------: |
| Four `agg_4` windows |      5,381,067 |         54,672 |      44,288 total |      32 total |
| One `agg_16` wrapper |      1,735,675 |         20,228 |            11,072 |            33 |

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

| Path, same 17 statements     | Submission gas | Calldata bytes | Final proof bytes | Public fields |
| ---------------------------- | -------------: | -------------: | ----------------: | ------------: |
| Five `agg_4` windows         |      6,675,299 |         67,092 |      55,360 total |      40 total |
| One composable final wrapper |      1,751,223 |         19,780 |            10,304 |             6 |

Savings: **73.77% / 3.81× less gas**, about **103,013 gas per outgoing debit statement** in this
warmed harness. Neither claims nor STF settlement are included in this submission comparison.
The complete E2E test passed, including the fifth-chain claim, cap/root effects, batch execution,
revocation, tampering, stale-prefix handling and replay rejection.

The global aggregator took **48.45 s** after the independently produced per-chain nodes were ready:
two fold proof jobs (21.64/20.44 s) and a final EVM proof (5.32 s), plus witness/native verification.
The first chain's five-statement node took 73.54 s; the other chains' three-statement nodes took about
25–26 s each. Jobs ran serially. These are single samples, not medians; they exclude accounting proof
production, whose cost still grows with transfers. The complete test, including inner proofs, both
settlement paths, negative cases and a final claim, took 656.83 s.

Standalone cold verifier gas (including calldata and the 21k base, excluding registry/STF): 1,029,151
for `agg_4`, 1,043,245 for `agg_16`, and **976,507 for `agg_finalize`**. All three deploy within the
default code-size limit, verify their real proofs and reject changed public inputs. The final verifier
is 17,332 runtime bytes; the PoC registry is 18,619 bytes. The small standalone saving comes from a
smaller final circuit/proof; most settlement savings come from sharing that verifier across statements.

The final public-input vector is six fields regardless of count. Calldata, state writes and batch checks
still grow with statement count.
Maximum node height is 30 (at most 4^31 statements); admitted-chain tree capacity is 2^32. Real L1
transaction gas limits are much tighter. Aggregation amortizes the fixed verifier cost, not all costs.

Raw single-sample results and source/log fingerprints:
[`results/m2-max-multichain-2026-10-23.json`](results/m2-max-multichain-2026-10-23.json).
The fixed16 measurement was taken before the admission-tree change; the composable17 comparison uses
the admission-tree implementation on both sides. Registration itself costs roughly 3M gas per chain in
this unoptimized Solidity Poseidon2 implementation; that one-time cost is outside the submission rows.

## Reproduce

Set tool paths and CRS as in [README.md](README.md#reproduce), with `ZKIP_PROVER_THREADS=4`, then:

```sh
cd zkip-poc
python3 -I prover/prove.py setup
cd contracts
forge test --match-test test_agg16FourChainsAgainstFourSeparateWindows --threads 1 -vv
forge test --match-test test_recursiveIndependentFiveChainsSeventeenStatements --threads 1 -vv
```

After both tests pass, collect their logs and independently check the final Solidity verifiers:

```sh
cd ../..
zkip-poc/work/venv/bin/python zkip-poc/benchmarks/multichain.py
```

Pass `--fixed-log` and `--recursive-log` if saving logs outside their default `zkip-poc/work/` paths.
The collector produces no new accounting or aggregation proofs. It reuses the tested proof files.

Prover timings are appended to `work/metrics.jsonl`. Keep other proving jobs stopped when measuring.
To combine independently produced nodes, pass `{"nodes":[{"dir":"..."}, ...]}` to `aggregate-node`
(recursive output) or `aggregate-recursive` (EVM output). For raw accounting proofs, use
`{"slots":[{"circuit":"debit_1","dir":"...","settlement":{...}}, ...]}` instead.
The public settlement attachments are untrusted: L1 reconstructs each current statement and compares
its digest before applying it. Proof-input inclusion does not guarantee that stale attachments settle.
