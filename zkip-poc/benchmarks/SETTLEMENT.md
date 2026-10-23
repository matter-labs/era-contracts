# Compact ZKIP settlement

The aggregate now exposes four statement digests as eight 128-bit public fields, instead of 64 inner
inputs and four VK commitments. L1 receives the four VK commitments separately and reconstructs each
statement from its authenticated state and the debit/claim submission. The [accounting design](../../protocol-docs/zkip-accounting-poc.md#compact-aggregated-settlement)
specifies the encoding and approval checks.

This removes 1,792 bytes from an otherwise identical aggregated submission. It preserves independent
stale-slot skipping, sequential updates within a window, approved-circuit checks and direct fallback.
The outer circuit performs extra Keccak work; this trades prover work for lower L1 calldata and public-input
processing. Keccak at this boundary is independent of the selected BLAKE2s source/finality hash.

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

## Remaining costs

The fixed outer verifier, proof calldata, per-chain state writes, batch authentication and cap updates
remain. More statements per outer proof and more legs per inner statement amortize them. This change
does not implement a larger aggregate, integrate the benchmark-only 16-leg size class, or move the
production settlement trees behind a proof. Full BLAKE2s finality still requires that separate settlement
change; the 4.32s claim result is a circuit benchmark with synthetic anchors.
