"""Collect real E2E windows and measure their final verifiers without producing new proofs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

import benchmark

POC = Path(__file__).resolve().parent.parent
WORK = POC / "work/multichain-benchmarks"
BASE_GAS = 21_000


def registry_rows(path):
    pattern = r"^\s+([^\n]+)\n\s+execution gas / calldata gas / calldata bytes (\d+) (\d+) (\d+)"
    rows = []
    for label, execution, calldata, size in re.findall(pattern, path.read_text(), re.MULTILINE):
        execution, calldata = int(execution), int(calldata)
        rows.append({"label": label.strip(), "execution_gas": execution, "calldata_gas": calldata,
                     "calldata_bytes": int(size), "call_plus_calldata_and_base_gas": execution + calldata + BASE_GAS})
    return rows


def machine_characteristics():
    if sys.platform == "darwin":
        return {"chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))}
    return {"chip": platform.processor() or platform.machine(),
            "memory_bytes": os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixed-log", type=Path, default=POC / "work/multichain-full-window.log")
    parser.add_argument("--recursive-log", type=Path, default=POC / "work/recursive-full-window.log")
    parser.add_argument("--output", type=Path, default=WORK / "results.json")
    args = parser.parse_args()
    logs = [args.fixed_log, args.recursive_log]
    if any("Suite result: ok" not in path.read_text() for path in logs):
        parser.error("both full E2E tests must pass before collecting results")
    rows = []
    for name, directory in [("agg_4", "recursive_baseline_0"), ("agg_16", "large_full_16"),
                            ("agg_finalize", "recursive_global")]:
        destination = WORK / "multichain/proofs" / name
        destination.mkdir(parents=True, exist_ok=True)
        for filename in ("proof", "public_inputs"):
            shutil.copyfile(POC / "work/e2e" / directory / filename, destination / filename)
        shutil.copyfile(POC / "work/vk" / name / "vk", destination / "vk")
        rows.append({"variant": "multichain", "circuit": name,
                     "proof_bytes": (destination / "proof").stat().st_size,
                     "public_input_bytes": (destination / "public_inputs").stat().st_size,
                     "proof_sha256": hashlib.sha256((destination / "proof").read_bytes()).hexdigest()})
    benchmark.WORK = WORK
    bb = os.environ.get("BB", "bb")
    crs = os.environ.get("BB_CRS", str(POC / "work/crs"))
    root = benchmark.prepare_verifier_bench(rows, bb, crs, os.environ, POC.parent / "lib/forge-std")
    gas = benchmark.command(["forge", "test", "--threads", "1", "-vv"], root, os.environ)[0]
    (root / "gas.log").write_text(gas)
    current = None
    by_name = {"multichain_" + row["circuit"]: row for row in rows}
    for line in gas.splitlines():
        match = re.search(r"BENCH (\w+)", line)
        if match: current = by_name[match[1]]
        match = re.search(r"(execution_gas|calldata_gas|transaction_gas|verifier_runtime_bytes)\s+(\d+)", line)
        if match and current is not None: current[match[1]] = int(match[2])
    assert all("transaction_gas" in row for row in rows)
    sources = [p for p in (POC / "circuits").glob("*/src/*.nr")] + list((POC / "contracts/src").glob("*.sol"))
    sources += list((POC / "prover").glob("*.py")) + list((POC / "contracts/test").glob("**/*.sol"))
    sources += [Path(__file__).resolve(), POC / "contracts/foundry.toml",
                POC / "benchmarks/VerifierBench.t.sol", POC / "benchmarks/BenchmarkGasConfig.sol"]
    circuits = {}
    for name, target in [("agg_4", "evm"), ("agg_16", "evm"), ("agg_leaf", "noir-recursive"),
                         ("agg_fold", "noir-recursive"), ("agg_finalize", "evm")]:
        circuits[name] = json.loads(benchmark.command([bb, "gates", "-b", POC / "circuits/target" / (name + ".json"),
                                                      "-t", target], POC, os.environ)[0])
    metrics = [json.loads(line) for line in (POC / "work/metrics.jsonl").read_text().splitlines()]
    selected = [row for row in metrics if row.get("tag", "").startswith(("recursive_", "large_full_16"))]
    result = {"machine": platform.platform(), **machine_characteristics(),
              "experiment_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=POC, text=True).strip(),
              "working_tree_changes": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=POC)),
              "registry_scope": "warmed Forge E2E calls + calldata 4/16 +21k per submission; not isolated cold transactions",
              "fixed16_source_scope": "earlier fixed16 prototype before chain-admission/general-tree changes; current fingerprints cover composable17",
              "fixed16_registry": registry_rows(args.fixed_log), "recursive17_registry": registry_rows(args.recursive_log),
              "standalone_scope": "cold final verifier + calldata 4/16 +21k base, Prague; no registry/STF",
              "standalone_verifiers": rows, "circuit_gates": circuits, "aggregation_metrics_single_samples": selected,
              "source_sha256": {str(p.relative_to(POC)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)},
              "log_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in logs}}
    assert result["fixed16_registry"] and result["recursive17_registry"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__": main()
