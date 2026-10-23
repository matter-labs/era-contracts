# ZKIP accounting experiments

This benchmark compares the original PoC at `cb7382cdb486beb0a6b5ba352cf1a79c2560e497` with proof-carried
IMT insertion checks and compact, single-asset transfers. It measures gates, repeated CPU proving time,
peak process RSS, proof bytes, public-input bytes, and standalone Solidity verification gas.

The implemented PoC change is described in [the accounting design](../../protocol-docs/zkip-accounting-poc.md).
No production protocol contract is changed.

## Variants

| Variant | Transfer format | IMT insertion checks | Commitment trees |
| --- | --- | --- | --- |
| `legacy_keccak` | Existing 1,600-byte bundle | Original L1 checks, outside this circuit | Existing Keccak |
| `proof_keccak` | Existing bundle | Inside the debit circuit | Existing Keccak |
| `compact_keccak` | 320-byte typed transfer | Inside the debit circuit | Keccak |
| `compact_blake2s` | Typed transfer | Inside the debit circuit | BLAKE2s |
| `compact_blake3_source` | Typed transfer | Inside the debit circuit | BLAKE3 source IMT; Keccak batch/chain/shared settlement trees |
| `compact_blake3` | Typed transfer | Inside the debit circuit | BLAKE3 |
| `compact_poseidon2` | Typed transfer | Inside the debit circuit | Poseidon2, Noir-only comparison |

The 320-byte transfer consists of ten words: version, source chain, destination chain, asset ID, amount,
origin chain, origin token, sender, recipient, and a sender-scoped nonce. Origin and token remain to
authenticate the Keccak NTV asset ID: the accounting rule treats origin-chain transfers specially.
Amounts are canonical 128-bit integers; chain IDs are canonical 64-bit integers; addresses are 160-bit.
Changing the nonce changes the transfer commitment. Token metadata and arbitrary execution calls are absent.

All variants retain the original state commitment, balance updates, consumed-leg tree, two-leg flow
preimage, finality checks, deadline checks, and tree-depth bounds. NTV asset IDs remain Keccak in every
variant. The generator copies the original claim circuits and the current debit circuits instead of
maintaining independent implementations of accounting.

## Interpretation boundaries

- These are circuit experiments, not a deployed transfer protocol. Compact execution, asset registration,
  refunds, and migration are not implemented by the benchmark.
- Claim fixtures use synthetic Merkle siblings and locally calculated anchors. A valid circuit proof does
  **not** establish that those anchors were accepted on L1. Production must authenticate the roots and
  settlement timestamps; that trust boundary is retained in the existing PoC registry tests.
- The BLAKE/Poseidon variants change the IMT and settlement commitment hierarchy. They require corresponding
  source-chain and settlement changes. They cannot be submitted against existing Keccak roots.
  `compact_blake3_source` isolates the source-only change while preserving the settlement-side hashes.
- Insertion proofs include the predecessor update, append-slot check, tree-height growth, 256-bit ordering,
  and exact begin/end-root binding. Their proving cost is included in every non-legacy debit measurement.
  Empty slots use the protocol's domain-separated empty-leaf constant, distinct from the zero sentinel leaf.
- Finality still authenticates both legs with depths 16 + 18 + 7. Smaller example trees are not used to
  advertise savings. Unused fixed-size slots still incur proving work.
- Hash support is not an Airbender performance measurement. BLAKE2s/BLAKE3 are candidates for a common hash;
  the Poseidon2 row illustrates Noir costs without claiming Airbender efficiency.
- Gas is for the standalone generated verifier with a cold call, calldata at 4/16 gas per byte and a 21k
  transaction base, under Prague. It excludes registry bookkeeping, settlement, L2 execution, and proof
  aggregation. It is **not** a per-transfer production fee. Proof randomness can slightly change calldata gas.
- Proofs use Barretenberg's zero-knowledge `evm` target throughout. Smaller circuits need not produce
  proportionally smaller proof bytes or lower L1 verification gas.
- Forge uses the original PoC's enlarged code-size limit. Runtime byte counts are reported separately;
  compare them with EIP-170 before treating a verifier as deployable.

## Reproduce

Use `nargo 1.0.0-beta.25`, `bb 5.2.1`, Foundry, Solidity 0.8.28, and Python 3.9 or later. Install the native
nargo/bb release binaries for your platform from their official GitHub releases; no binaries are committed.
Run from the repository root:

```sh
python3 -m venv zkip-poc/work/venv
zkip-poc/work/venv/bin/python -m pip install -r zkip-poc/benchmarks/requirements.txt
export NARGO=/absolute/path/to/nargo
export BB=/absolute/path/to/bb
export BB_CRS="$PWD/zkip-poc/work/crs"

NARGO="$NARGO" zkip-poc/work/venv/bin/python -m unittest discover -s zkip-poc/benchmarks -v
zkip-poc/work/venv/bin/python zkip-poc/benchmarks/benchmark.py --threads 4 --repetitions 3 --evm
```

The first VK generation downloads the required CRS into `BB_CRS`. The default matrix includes `debit_1`,
`debit_4`, `claim_1`, and `claim_2`. `--variants`, `--circuits`, `--gates-only`, and `--prepare-only` select
smaller experiments. `--forge-std /absolute/path/to/forge-std` can reuse an initialized checkout.
`--large-repetitions 1` can reduce the number of samples for `debit_4` and `claim_2`; the selected counts and
every individual sample remain in the JSON report.

Outputs are under ignored `zkip-poc/work/benchmarks/`: generated Noir workspaces, witnesses, real proofs,
generated Solidity verifiers, `verifiers/gas.log`, and `results.json`. Timings include the `bb prove` process
startup, exclude witness execution/VK setup, and verify every sample natively. Use an otherwise idle machine
for comparable timings. On macOS RSS comes from `/usr/bin/time -l`; other platforms report it as null.

The Python/Noir tests cover positive state transitions and rejection of omitted legs, invalid insertion
paths, duplicate commitments, wrong leaf counts, late or non-ZKIP legs, wrong anchors/destinations, double
credits, forged asset origins, and noncanonical amount encodings. The Forge benchmark verifies real proofs
and rejects a changed public input for every measured circuit.
