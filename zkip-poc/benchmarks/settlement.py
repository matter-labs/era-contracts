"""Compare the original and compact outer proofs on the same real inner-proof witness.

Generate the witness with the PoC Forge tests first. See SETTLEMENT.md for scope and reproduction.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
from pathlib import Path

import benchmark

POC = Path(__file__).resolve().parent.parent
BASELINE_COMMIT = "4773253f074a69e9d091bfff116d62c49e1892fc"
WORK = POC / "work/settlement-benchmarks"
BASE_GAS = 21_000


def registry_measurements(log):
    pattern = r"^\s+([^\n]+): submitAggregated\n\s+execution gas / calldata gas / calldata bytes (\d+) (\d+) (\d+)"
    rows = []
    for label, execution, calldata, size in re.findall(pattern, log, re.MULTILINE):
        execution, calldata = int(execution), int(calldata)
        rows.append({"label": label.strip(), "execution_gas": execution, "calldata_gas": calldata,
                     "calldata_bytes": int(size), "call_plus_calldata_and_base_gas": execution + calldata + BASE_GAS})
    return rows


def prepare(variant, witness):
    root = WORK / variant
    files = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", BASELINE_COMMIT, "zkip-poc/circuits"], cwd=POC.parent,
        text=True).splitlines()
    files = [p for p in files if p.endswith((".nr", "Nargo.toml"))]
    if variant == "settlement_compact":
        files += [str(p.relative_to(POC.parent)) for p in (POC / "circuits").glob("*/src/*.nr")]
    for relative in sorted(set(files)):
        dest = root / Path(relative).relative_to("zkip-poc/circuits")
        dest.parent.mkdir(parents=True, exist_ok=True)
        if variant == "settlement_baseline":
            dest.write_bytes(subprocess.check_output(["git", "show", f"{BASELINE_COMMIT}:{relative}"], cwd=POC))
        else:
            shutil.copyfile(POC.parent / relative, dest)
    shutil.copyfile(witness, root / "agg_4/Prover.toml")
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--witness", type=Path, default=POC / "circuits/agg_4/Prover_agg_four.toml")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--registry-baseline", type=Path)
    parser.add_argument("--registry-candidate", type=Path)
    parser.add_argument("--output", type=Path, default=WORK / "results.json")
    args = parser.parse_args()
    if args.repetitions < 1 or args.threads < 1:
        parser.error("threads and repetitions must be positive")
    if not args.witness.is_file():
        parser.error("generate the witness with test_aggFourSlotsFromTwoChains first")
    if bool(args.registry_baseline) != bool(args.registry_candidate):
        parser.error("pass both registry logs, or neither")
    benchmark.WORK = WORK
    nargo, bb = os.environ.get("NARGO", "nargo"), os.environ.get("BB", "bb")
    crs = os.environ.get("BB_CRS", str(POC / "work/crs"))
    env = dict(os.environ, HARDWARE_CONCURRENCY=str(args.threads))
    results = {"baseline_commit": BASELINE_COMMIT, "machine": platform.platform(), "threads": args.threads,
               "repetitions": args.repetitions, "witness_sha256": hashlib.sha256(args.witness.read_bytes()).hexdigest(),
               "measurements": [], "gas_scope": "standalone cold verifier + calldata at 4/16 + 21k base, Prague"}
    results["experiment_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=POC, text=True).strip()
    results["working_tree_changes"] = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=POC))
    for tool, path in (("nargo", nargo), ("bb", bb)):
        results[tool] = benchmark.command([path, "--version"], POC, env)[0].strip()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for variant in ("settlement_baseline", "settlement_compact"):
        root = prepare(variant, args.witness.resolve())
        print("Measuring", variant, flush=True)
        command = lambda cmd: benchmark.command(cmd, root, env)
        command([nargo, "compile", "--package", "agg_4"])
        command([nargo, "execute", "--package", "agg_4", "agg_4"])
        bytecode = root / "target/agg_4.json"
        gates = json.loads(command([bb, "gates", "-b", bytecode, "-t", "evm"])[0])
        out = root / "proofs/agg_4"
        out.mkdir(parents=True, exist_ok=True)
        command([bb, "write_vk", "-b", bytecode, "-o", out, "-t", "evm", "-c", crs])
        samples = []
        for _ in range(args.repetitions):
            _, seconds, rss = command([bb, "prove", "-b", bytecode, "-w", root / "target/agg_4.gz",
                                       "-k", out / "vk", "-o", out, "-t", "evm", "-c", crs])
            command([bb, "verify", "-k", out / "vk", "-p", out / "proof", "-i", out / "public_inputs",
                     "-t", "evm", "-c", crs])
            samples.append({"prove_s": seconds, "peak_rss_bytes": rss})
        row = {"variant": variant, "circuit": "agg_4", "gates": gates, "samples": samples,
               "median_prove_s": statistics.median(s["prove_s"] for s in samples),
               "proof_bytes": (out / "proof").stat().st_size,
               "public_input_bytes": (out / "public_inputs").stat().st_size,
               "bytecode_sha256": hashlib.sha256(bytecode.read_bytes()).hexdigest()}
        results["measurements"].append(row)
        args.output.write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(row), flush=True)
    root = benchmark.prepare_verifier_bench(results["measurements"], bb, crs, env, POC.parent / "lib/forge-std")
    output = benchmark.command(["forge", "test", "--threads", "1", "-vv"], root, env)[0]
    (root / "gas.log").write_text(output)
    current = None
    by_name = {r["variant"] + "_agg_4": r for r in results["measurements"]}
    for line in output.splitlines():
        match = re.search(r"BENCH (\w+)", line)
        if match:
            current = by_name[match[1]]
        match = re.search(r"(execution_gas|calldata_gas|transaction_gas|verifier_runtime_bytes)\s+(\d+)", line)
        if match and current is not None:
            current[match[1]] = int(match[2])
    assert all("transaction_gas" in row for row in results["measurements"]), "missing verifier gas measurements"
    if args.registry_baseline:
        results["registry_scope"] = "existing Forge E2E call harness, warmed test state; not an isolated cold transaction"
        results["registry_baseline"] = registry_measurements(args.registry_baseline.read_text())
        candidate = {r["label"]: r for r in registry_measurements(args.registry_candidate.read_text())}
        results["registry_compact"] = [candidate[r["label"]] for r in results["registry_baseline"]]
        assert results["registry_baseline"], "no registry measurements found"
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(args.output, flush=True)


if __name__ == "__main__":
    main()
