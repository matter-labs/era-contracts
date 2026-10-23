"""Render benchmark JSON as a reviewable Markdown report."""

import argparse
import json
from pathlib import Path


def render(data, raw_name, batch16=None, batch_raw_name=None):
    lines = ["# ZKIP compact-transfer measurements", "",
             f"Measured on {data.get('cpu', data['machine'])}, {data['threads']} prover threads, "
             f"{data.get('ram_bytes', 0) / 2**30:.0f} GiB RAM. {data['nargo'].splitlines()[0]}; Barretenberg {data['bb']}.", "",
             f"Original PoC: `{data['baseline_commit']}`. Experiment base: `{data['experiment_commit']}`.", "",
             "Harness edits were present in the working tree; the complete harness is published alongside this report." if data.get("working_tree_changes") else "The experiment working tree was clean.", "",
             f"[Raw measurements]({raw_name}) include every sample, RSS, compiled artifact hashes, and verifier runtime sizes.", "",
             f"The single-leg circuits have {data['repetitions']} proving samples each; larger circuits use the sample count shown.",
             "Proving time is the median of those samples, excluding witness generation and VK setup.", "",
             "Gas is a standalone cold Solidity verifier call plus calldata and 21k base at Prague pricing.",
             "It excludes registry/settlement/aggregation. It is not a production per-transfer fee.", ""]
    for circuit in ("debit_1", "debit_4", "claim_1", "claim_2"):
        lines += ["## " + circuit, "",
                  "| Variant | Gates | Prove (s) | Samples | Peak RSS (MiB) | Proof bytes | Public-input bytes | Verifier tx gas |",
                  "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for row in data["measurements"]:
            if row["circuit"] != circuit:
                continue
            gates = row["gates"]["functions"][0]["circuit_size"]
            rss_values = [sample["peak_rss_bytes"] for sample in row["samples"] if sample["peak_rss_bytes"] is not None]
            rss = f"{max(rss_values) / 2**20:,.0f}" if rss_values else "n/a"
            lines.append(f"| `{row['variant']}` | {gates:,} | {row['median_prove_s']:.2f} | {len(row['samples'])} | "
                         f"{rss} | {row['proof_bytes']:,} | {row['public_input_bytes']:,} | {row['transaction_gas']:,} |")
        lines.append("")
    if batch16 is not None:
        row = batch16["measurements"][0]
        if row["circuit"] != "debit_16":
            raise ValueError("Expected the debit_16 capacity experiment")
        lines += ["## Larger source batch", "",
                  f"[Raw 16-leg sample]({batch_raw_name}) uses compact transfers, BLAKE3 source commitments, and Keccak settlement hashes.", "",
                  "| Legs | Gates | Prove (s) | Samples | Proof bytes | Public-input bytes | Verifier gas | Verifier gas per debit |",
                  "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                  f"| 16 | {row['gates']['functions'][0]['circuit_size']:,} | {row['median_prove_s']:.2f} | {len(row['samples'])} | "
                  f"{row['proof_bytes']:,} | {row['public_input_bytes']:,} | {row['transaction_gas']:,} | {row['transaction_gas'] / 16:,.0f} |", "",
                  "This is a benchmark-only size class generated from the same debit circuit. The current PoC registry accepts at most four legs.",
                  "The per-debit figure assumes a full batch on one source chain and excludes claims, registry work, and STF/settlement costs.",
                  "It measures amortization, not the end-to-end price of an interop transfer.", ""]
    lines += ["## Interpretation", "",
              "- `legacy_keccak` leaves insertion checking on L1. Every other debit includes insertion checking inside ZKIP.",
              "- `proof_keccak` isolates the cost of moving checks, without changing the transfer format or hashes.",
              "- `compact_blake3_source` keeps Keccak batch/chain/shared settlement hashes; it requires source protocol changes.",
              "- Full BLAKE/Poseidon finality rows additionally require a settlement redesign. Their synthetic anchors are not L1 settlement evidence.",
              "- Poseidon2 is a Noir comparison; no Airbender performance is claimed for any row.",
              "- Gates and prover time can fall much more than proof bytes or L1 verification gas. See the separate aggregation PoC for amortization.",
              "- Reproduce with `benchmark.py`; see [methodology and trust boundaries](README.md).", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--raw-name", default="results/m2-max-2026-10-23.json")
    parser.add_argument("--batch16", type=Path)
    parser.add_argument("--batch16-raw-name", default="results/m2-max-batch16-2026-10-23.json")
    args = parser.parse_args()
    batch = json.loads(args.batch16.read_text()) if args.batch16 else None
    args.output.write_text(render(json.loads(args.input.read_text()), args.raw_name, batch, args.batch16_raw_name))


if __name__ == "__main__":
    main()
