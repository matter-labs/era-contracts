/**
 * Main coverage collection pipeline.
 *
 * Orchestrates: trace collection -> artifact resolution -> source mapping -> LCOV generation.
 *
 * This is designed to run AFTER the Anvil interop tests have completed,
 * while the Anvil chains are still running (--keep-chains or coverage mode).
 */

import * as fs from "fs";
import * as path from "path";
import type { providers } from "ethers";
import { assertTracesUsable, collectChainTraces, mergeTraces } from "./trace-collector";
import { resolveContracts, resolveByBytecode } from "./artifact-resolver";
import {
  allSourcePaths,
  loadBuildInfos,
  selectBuildInfo,
  loadSourceContents,
  resolveSourceLocations,
  getExecutableLines,
  extractFunctions,
  resolveFunctionHits,
} from "./source-map-decoder";
import type { ContractSourceMap, SourceIdMap } from "./source-map-decoder";
import { generateLcov, writeLcov, generateSummary, filterCoverageFiles } from "./lcov-generator";
import type { FileCoverage } from "./lcov-generator";
import { createProvider } from "../core/utils";

export interface CoverageOptions {
  /** Path to the l1-contracts directory */
  projectRoot: string;
  /** Path to Forge output directory */
  outDir: string;
  /** Path to the deployment state file (chains.json) */
  statePath: string;
  /** Output directory for coverage artifacts */
  coverageDir: string;
  /** Generate HTML report using genhtml (requires lcov to be installed) */
  html?: boolean;
  /** Only collect traces from L1 chain (skip L2 chains) */
  l1Only?: boolean;
}

/**
 * Runs the full coverage collection pipeline.
 */
export async function collectCoverage(options: CoverageOptions): Promise<{
  lcovPath: string;
  summaryPath: string;
  summary: string;
}> {
  const { projectRoot, outDir, statePath, coverageDir } = options;

  console.log("\n📊 Anvil Interop Coverage Collection");
  console.log("=".repeat(50));

  // 1. Load deployment state
  console.log("\n🔍 Step 1: Loading deployment state...");
  if (!fs.existsSync(statePath)) {
    throw new Error(`Deployment state not found: ${statePath}. Run interop tests first.`);
  }
  const state = JSON.parse(fs.readFileSync(statePath, "utf-8"));

  // 2. Load source maps and build info
  console.log("\n🔍 Step 2: Loading compilation artifacts...");
  // One map per compilation, and artifacts are matched to their own — see selectBuildInfo. A single
  // global map silently misattributes whenever more than one compilation contributed artifacts.
  const buildInfos = loadBuildInfos(outDir);
  const knownSourcePaths = allSourcePaths(buildInfos);
  const sourceContents = loadSourceContents(
    Object.fromEntries([...knownSourcePaths].map((p, i) => [String(i), p])),
    projectRoot
  );
  console.log(
    `  Loaded ${buildInfos.length} build-info file(s), ${knownSourcePaths.size} source paths, ` +
      `${sourceContents.size} source files`
  );

  // 3. Resolve known contract addresses to artifacts
  console.log("\n🔍 Step 3: Resolving contract artifacts...");
  const rpcUrls = new Map<string, string>();

  if (state.chains?.l1?.rpcUrl) {
    rpcUrls.set("L1", state.chains.l1.rpcUrl);
  }
  if (state.chains?.l2) {
    for (const l2 of state.chains.l2) {
      rpcUrls.set(`L2-${l2.chainId}`, l2.rpcUrl);
    }
  }

  const resolvedContracts = await resolveContracts(state, outDir, rpcUrls);

  // 4. Collect traces from all chains
  console.log("\n🔍 Step 4: Collecting execution traces...");
  const chainTraces = [];
  let totalTransactions = 0;
  let totalTraceFailures = 0;

  if (state.chains?.l1?.rpcUrl) {
    const l1Traces = await collectChainTraces(state.chains.l1.rpcUrl, "L1");
    chainTraces.push(l1Traces.contractPCs);
    totalTransactions += l1Traces.transactions;
    totalTraceFailures += l1Traces.traceFailures;
  }

  if (!options.l1Only && state.chains?.l2) {
    for (const l2 of state.chains.l2) {
      const l2Traces = await collectChainTraces(l2.rpcUrl, `L2-${l2.chainId}`);
      chainTraces.push(l2Traces.contractPCs);
      totalTransactions += l2Traces.transactions;
      totalTraceFailures += l2Traces.traceFailures;
    }
  }

  const allTraces = mergeTraces(chainTraces);
  console.log(`  Total: ${allTraces.size} unique contract addresses with trace data`);

  // 5. For unresolved traced addresses, try bytecode matching
  console.log("\n🔍 Step 5: Resolving remaining contract addresses...");
  const allProviders = new Map<string, providers.JsonRpcProvider>();
  for (const [label, url] of rpcUrls) {
    allProviders.set(label, createProvider(url));
  }

  // Build a set of already-resolved addresses
  const resolvedAddrs = new Set(resolvedContracts.map((c) => c.address));

  for (const [addr] of allTraces) {
    if (resolvedAddrs.has(addr)) continue;

    // Try to resolve via bytecode matching from L1 first, then L2s
    for (const [, provider] of allProviders) {
      const resolved = await resolveByBytecode(addr, provider, outDir);
      if (resolved) {
        resolvedContracts.push(resolved);
        resolvedAddrs.add(addr);
        break;
      }
    }
  }

  console.log(`  Total resolved contracts: ${resolvedContracts.length}`);

  // 6. Map traces to source locations
  console.log("\n🔍 Step 6: Mapping traces to source locations...");
  const fileHitLines = new Map<string, Set<number>>();

  // artifact source id + compilation target identifies the build-info it was compiled under.
  const mapForArtifact = new Map<string, SourceIdMap>();
  let unresolvedBuildInfo = 0;
  const sourceIdMapOf = (contract: (typeof resolvedContracts)[number]): SourceIdMap => {
    const cached = mapForArtifact.get(contract.artifactPath);
    if (cached) return cached;

    let selected: SourceIdMap | null = null;
    try {
      const artifact = JSON.parse(fs.readFileSync(contract.artifactPath, "utf-8"));
      const rawMeta = artifact.metadata || artifact.rawMetadata || "{}";
      const metadata = typeof rawMeta === "string" ? JSON.parse(rawMeta) : rawMeta;
      const target = Object.keys(metadata?.settings?.compilationTarget || {})[0];
      if (target !== undefined && artifact.id !== undefined) {
        selected = selectBuildInfo(buildInfos, artifact.id, target)?.sourceIdMap ?? null;
      }
    } catch {
      selected = null;
    }

    if (!selected) {
      // Falling back to the newest map may misattribute this contract's lines, so it is counted and
      // reported rather than passed over quietly.
      unresolvedBuildInfo++;
      selected = buildInfos[0].sourceIdMap;
    }
    mapForArtifact.set(contract.artifactPath, selected);
    return selected;
  };

  for (const contract of resolvedContracts) {
    const pcs = allTraces.get(contract.address);
    if (!pcs || pcs.size === 0) continue;

    const locations = resolveSourceLocations(contract.sourceMap, pcs, sourceIdMapOf(contract), sourceContents);

    for (const [filePath, lines] of locations) {
      let existing = fileHitLines.get(filePath);
      if (!existing) {
        existing = new Set();
        fileHitLines.set(filePath, existing);
      }
      for (const line of lines) {
        existing.add(line);
      }
    }
  }

  console.log(`  Coverage data for ${fileHitLines.size} source files`);

  // Refuse to write a report that would look like "this ran and covered nothing".
  assertTracesUsable({
    transactions: totalTransactions,
    traceFailures: totalTraceFailures,
    tracedContracts: allTraces.size,
    hitSourceFiles: fileHitLines.size,
  });

  // 7. Compute executable lines and extract function data
  console.log("\n🔍 Step 7: Computing executable lines and extracting functions...");
  const decodedContracts = resolvedContracts
    .filter((c) => c.sourceMap !== null)
    .map((c) => ({ contractMap: c.sourceMap as ContractSourceMap, sourceIdMap: sourceIdMapOf(c) }));

  if (unresolvedBuildInfo > 0) {
    console.warn(
      `  ⚠️  ${unresolvedBuildInfo} artifact(s) could not be matched to a build-info; their lines were ` +
        "decoded with the newest map and may be misattributed."
    );
  }

  // Build a map of source file -> list of contract names that compile from it
  // (used for function extraction — we need the contract name for qualified names)
  const fileToContractNames = new Map<string, Set<string>>();
  for (const contract of resolvedContracts) {
    // The artifact's compilationTarget tells us which file this contract comes from.
    // We can infer the file from the source map: the majority of entries point to the main file.
    // Simpler: use the contract name and find it in source files via function parsing.
    const name = contract.name.replace(/ \(impl\)$/, ""); // strip " (impl)" suffix
    // Get the compilation target file from the artifact metadata
    try {
      const artifact = JSON.parse(fs.readFileSync(contract.artifactPath, "utf-8"));
      const rawMeta = artifact.metadata || artifact.rawMetadata || "{}";
      const metadata = typeof rawMeta === "string" ? JSON.parse(rawMeta) : rawMeta;
      const target = metadata.settings?.compilationTarget;
      if (target) {
        for (const filePath of Object.keys(target)) {
          let names = fileToContractNames.get(filePath);
          if (!names) {
            names = new Set();
            fileToContractNames.set(filePath, names);
          }
          names.add(name);
        }
      }
    } catch {
      // Skip if metadata unavailable
    }
  }

  const coverageData: FileCoverage[] = [];
  let totalFunctions = 0;
  let totalFunctionsHit = 0;

  // Include all source files that have contract code (not just hit files)
  for (const filePath of knownSourcePaths) {
    // Only process contract source files
    if (!filePath.startsWith("contracts/") && !filePath.includes("/contracts/")) continue;

    const executableLines = getExecutableLines(filePath, decodedContracts, sourceContents);
    if (executableLines.size === 0) continue;

    const hitLines = fileHitLines.get(filePath) || new Set<number>();
    const lineHits = new Map<number, number>();

    // Mark all executable lines, with hit count 1 for covered, 0 for uncovered
    for (const line of executableLines) {
      lineHits.set(line, hitLines.has(line) ? 1 : 0);
    }

    // Extract function data for contracts compiled from this file
    const contractNames = fileToContractNames.get(filePath);
    let functions: Array<{ qualifiedName: string; line: number; hit: boolean }> | undefined;

    if (contractNames) {
      functions = [];
      for (const contractName of contractNames) {
        const fnInfos = extractFunctions(contractName, filePath, sourceContents);
        const content = sourceContents.get(filePath);
        const fileLineCount = content ? content.split("\n").length : undefined;
        const fnHits = resolveFunctionHits(fnInfos, hitLines, fileLineCount);
        for (const fn of fnInfos) {
          const hit = fnHits.get(fn.qualifiedName) || false;
          functions.push({ qualifiedName: fn.qualifiedName, line: fn.line, hit });
          totalFunctions++;
          if (hit) totalFunctionsHit++;
        }
      }
    }

    coverageData.push({
      filePath,
      lineHits,
      executableLines,
      functions,
    });
  }

  if (totalFunctions > 0) {
    console.log(`  Functions: ${totalFunctionsHit}/${totalFunctions} hit`);
  }

  // 8. Filter and generate output
  console.log("\n🔍 Step 8: Generating coverage report...");
  const filteredCoverage = filterCoverageFiles(coverageData, {
    excludeInterfaces: true,
    excludePatterns: [
      /\/Config\.sol$/, // Pure constants
      /\/Messaging\.sol$/, // Struct definitions
      /\/L2ContractAddresses\.sol$/, // Address constants
    ],
  });

  const lcovContent = generateLcov(filteredCoverage);
  const lcovPath = path.join(coverageDir, "anvil-lcov.info");
  writeLcov(lcovContent, lcovPath);

  const summary = generateSummary(filteredCoverage);
  const summaryPath = path.join(coverageDir, "anvil-coverage-summary.txt");
  fs.mkdirSync(coverageDir, { recursive: true });
  fs.writeFileSync(summaryPath, summary);

  console.log(summary);
  console.log(`  📄 LCOV written to: ${lcovPath}`);
  console.log(`  📄 Summary written to: ${summaryPath}`);

  // 9. Optionally generate HTML report
  if (options.html) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const { spawnSync } = require("child_process");
      const htmlDir = path.join(coverageDir, "html");
      const result = spawnSync(
        "genhtml",
        [
          lcovPath,
          "-o",
          htmlDir,
          "--branch-coverage",
          "--ignore-errors",
          "category",
          "--ignore-errors",
          "inconsistent",
        ],
        { stdio: "inherit" }
      );
      if (result.status === 0) {
        console.log(`  🌐 HTML report generated: ${htmlDir}/index.html`);
      } else {
        console.warn("  ⚠️  genhtml failed (is lcov installed?). Skipping HTML report.");
      }
    } catch {
      console.warn("  ⚠️  genhtml not available. Skipping HTML report.");
    }
  }

  return { lcovPath, summaryPath, summary };
}
