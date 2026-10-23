# ZKIP compact-transfer measurements

Measured on Apple M2 Max, 4 prover threads, 32 GiB RAM. nargo version = 1.0.0-beta.25; Barretenberg 5.2.1.

Original PoC: `cb7382cdb486beb0a6b5ba352cf1a79c2560e497`. Experiment base: `a896663a9e08bb6bd6025987cae3813570fee2ec`.

Harness edits were present in the working tree; the complete harness is published alongside this report.

[Raw measurements](results/m2-max-2026-10-23.json) include every sample, RSS, compiled artifact hashes, and verifier runtime sizes.

The single-leg circuits have 3 proving samples each; larger circuits use the sample count shown.
Proving time is the median of those samples, excluding witness generation and VK setup.

Gas is a standalone cold Solidity verifier call plus calldata and 21k base at Prague pricing.
It excludes registry/settlement/aggregation. It is not a production per-transfer fee.

## debit_1

| Variant | Gates | Prove (s) | Samples | Peak RSS (MiB) | Proof bytes | Public-input bytes | Verifier tx gas |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `legacy_keccak` | 330,104 | 4.13 | 3 | 651 | 9,920 | 320 | 941,199 |
| `proof_keccak` | 1,504,707 | 17.25 | 3 | 2,851 | 10,688 | 512 | 993,519 |
| `compact_keccak` | 1,342,499 | 16.23 | 3 | 2,612 | 10,688 | 512 | 993,483 |
| `compact_blake2s` | 322,034 | 3.63 | 3 | 648 | 9,920 | 512 | 944,371 |
| `compact_blake3_source` | 250,421 | 2.63 | 3 | 508 | 9,536 | 512 | 919,738 |
| `compact_blake3` | 250,421 | 2.63 | 3 | 510 | 9,536 | 512 | 919,750 |
| `compact_poseidon2` | 83,344 | 1.07 | 3 | 238 | 9,152 | 512 | 895,237 |

## debit_4

| Variant | Gates | Prove (s) | Samples | Peak RSS (MiB) | Proof bytes | Public-input bytes | Verifier tx gas |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `legacy_keccak` | 1,307,895 | 15.04 | 1 | 1,891 | 10,688 | 512 | 994,359 |
| `proof_keccak` | 6,005,134 | 72.83 | 1 | 5,373 | 11,456 | 512 | 1,042,722 |
| `compact_keccak` | 5,355,847 | 64.66 | 1 | 5,815 | 11,456 | 512 | 1,042,902 |
| `compact_blake2s` | 1,272,951 | 12.61 | 1 | 2,007 | 10,688 | 512 | 993,483 |
| `compact_blake3_source` | 986,559 | 9.44 | 1 | 1,660 | 10,304 | 512 | 968,878 |
| `compact_blake3` | 986,559 | 9.15 | 1 | 1,648 | 10,304 | 512 | 968,902 |
| `compact_poseidon2` | 326,420 | 3.75 | 1 | 661 | 9,920 | 512 | 944,395 |

## claim_1

| Variant | Gates | Prove (s) | Samples | Peak RSS (MiB) | Proof bytes | Public-input bytes | Verifier tx gas |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `legacy_keccak` | 1,963,046 | 23.34 | 3 | 2,805 | 10,688 | 512 | 993,495 |
| `proof_keccak` | 1,963,046 | 22.04 | 3 | 3,588 | 10,688 | 512 | 993,591 |
| `compact_keccak` | 1,800,907 | 22.01 | 3 | 2,828 | 10,688 | 512 | 993,579 |
| `compact_blake2s` | 429,820 | 4.32 | 3 | 821 | 9,920 | 512 | 944,395 |
| `compact_blake3_source` | 1,203,671 | 14.44 | 3 | 1,997 | 10,688 | 512 | 993,639 |
| `compact_blake3` | 334,229 | 3.45 | 3 | 648 | 9,920 | 512 | 944,287 |
| `compact_poseidon2` | 112,582 | 1.36 | 3 | 300 | 9,152 | 512 | 895,345 |

## claim_2

| Variant | Gates | Prove (s) | Samples | Peak RSS (MiB) | Proof bytes | Public-input bytes | Verifier tx gas |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `legacy_keccak` | 3,921,838 | 46.80 | 1 | 4,209 | 11,072 | 512 | 1,018,231 |
| `proof_keccak` | 3,921,838 | 47.96 | 1 | 5,317 | 11,072 | 512 | 1,018,111 |
| `compact_keccak` | 3,597,201 | 41.60 | 1 | 4,819 | 11,072 | 512 | 1,018,147 |
| `compact_blake2s` | 854,496 | 8.27 | 1 | 1,328 | 10,304 | 512 | 968,878 |
| `compact_blake3_source` | 2,402,239 | 30.75 | 1 | 3,425 | 11,072 | 512 | 1,018,099 |
| `compact_blake3` | 663,339 | 6.90 | 1 | 1,304 | 10,304 | 512 | 968,926 |
| `compact_poseidon2` | 220,619 | 2.65 | 1 | 533 | 9,536 | 512 | 919,714 |

## Larger source batch

[Raw 16-leg sample](results/m2-max-batch16-2026-10-23.json) uses compact transfers, BLAKE3 source commitments, and Keccak settlement hashes.

| Legs | Gates | Prove (s) | Samples | Proof bytes | Public-input bytes | Verifier gas | Verifier gas per debit |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 | 3,932,878 | 31.18 | 1 | 11,072 | 512 | 1,018,135 | 63,633 |

This is a benchmark-only size class generated from the same debit circuit. The current PoC registry accepts at most four legs.
The per-debit figure assumes a full batch on one source chain and excludes claims, registry work, and STF/settlement costs.
It measures amortization, not the end-to-end price of an interop transfer.

## Interpretation

- `legacy_keccak` leaves insertion checking on L1. Every other debit includes insertion checking inside ZKIP.
- `proof_keccak` isolates the cost of moving checks, without changing the transfer format or hashes.
- `compact_blake3_source` keeps Keccak batch/chain/shared settlement hashes; it requires source protocol changes.
- Full BLAKE/Poseidon finality rows additionally require a settlement redesign. Their synthetic anchors are not L1 settlement evidence.
- Poseidon2 is a Noir comparison; no Airbender performance is claimed for any row.
- Gates and prover time can fall much more than proof bytes or L1 verification gas. See the separate aggregation PoC for amortization.
- Reproduce with `benchmark.py`; see [methodology and trust boundaries](README.md).
