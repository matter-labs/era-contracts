import { spawn, execSync } from "child_process";
import { providers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import type { AnvilChain } from "../core/types";
import { waitForChainReady, formatChainInfo } from "../core/utils";

export class AnvilManager {
  private chains: Map<number, AnvilChain> = new Map();
  private pidFilePath: string;

  constructor() {
    const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";
    this.pidFilePath = path.join(__dirname, `../../outputs/anvil-pids${runSuffix}.json`);
  }

  /**
   * Kill any existing process listening on the given port.
   * Prevents stale anvil instances (e.g. from KEEP_CHAINS=1) from poisoning a fresh run.
   */
  private killProcessOnPort(port: number): void {
    try {
      const output = execSync(`lsof -ti :${port}`, { encoding: "utf-8" }).trim();
      if (output) {
        const pids = output
          .split("\n")
          .map((p) => p.trim())
          .filter(Boolean);
        for (const pid of pids) {
          try {
            process.kill(Number(pid), "SIGKILL");
          } catch {
            // Process may have already exited
          }
        }
        console.log(`   Killed stale process(es) on port ${port}: ${pids.join(", ")}`);
      }
    } catch {
      // lsof exits non-zero when no process is found — that's fine
    }
  }

  private resolveAnvilBinary(): string {
    const envBinary = process.env.ANVIL_BIN?.trim();
    if (envBinary) {
      return envBinary;
    }

    const homeDir = process.env.HOME;
    const knownPaths = [
      homeDir ? path.join(homeDir, ".foundry/bin/anvil") : "",
      "/opt/homebrew/bin/anvil",
      "/usr/local/bin/anvil",
    ];

    for (const binaryPath of knownPaths) {
      if (binaryPath && fs.existsSync(binaryPath)) {
        return binaryPath;
      }
    }

    return "anvil";
  }

  async startChain(
    config: Omit<AnvilChain, "rpcUrl" | "process"> & {
      blockTime?: number;
      timestamp?: number;
      dumpStatePath?: string;
      loadStatePath?: string;
    }
  ): Promise<void> {
    const { chainId, port, role, blockTime, timestamp, dumpStatePath, loadStatePath } = config;
    const isL1 = role === "l1";
    const rpcUrl = `http://127.0.0.1:${port}`;

    // Kill any stale process (e.g. from a previous KEEP_CHAINS run) on this port
    this.killProcessOnPort(port);

    console.log(`🚀 Starting ${formatChainInfo(chainId, port, isL1)}...`);
    const anvilBinary = this.resolveAnvilBinary();

    // Log resolved binary for debugging CI issues
    const binaryExists = fs.existsSync(anvilBinary);
    console.log(`   anvil binary: ${anvilBinary} (exists: ${binaryExists})`);
    if (!binaryExists && anvilBinary !== "anvil") {
      console.error(`❌ Anvil binary not found at ${anvilBinary}`);
    }

    const homeDir = process.env.HOME;
    const foundryBinPath = homeDir ? path.join(homeDir, ".foundry/bin") : "";
    const enrichedPath = foundryBinPath ? `${foundryBinPath}:${process.env.PATH || ""}` : process.env.PATH;

    const effectiveBlockTime = blockTime ?? 1;
    const args = [
      "--port",
      port.toString(),
      "--chain-id",
      chainId.toString(),
      "--accounts",
      "10",
      "--balance",
      "10000",
      "--gas-limit",
      "100000000", // Increase block gas limit to 100M to accommodate L2 genesis upgrade
      "--auto-impersonate", // Allow impersonating any address without signatures
    ];

    // Enable step-level tracing when running in coverage mode.
    // This is required for debug_traceTransaction to return non-empty structLogs.
    if (process.env.ANVIL_COVERAGE_MODE === "1") {
      args.push("--steps-tracing");
    }

    if (effectiveBlockTime > 0) {
      args.push("--block-time", effectiveBlockTime.toString());
    }

    if (timestamp !== undefined) {
      args.push("--timestamp", timestamp.toString());
    }

    if (dumpStatePath) {
      args.push("--dump-state", dumpStatePath);
    }

    if (loadStatePath) {
      args.push("--load-state", loadStatePath);
    }

    // Use pipe for stderr to capture error output, ignore stdin/stdout for detach
    const childProcess = spawn(anvilBinary, args, {
      stdio: ["ignore", "ignore", "pipe"],
      detached: true, // Detach from parent process
      env: {
        ...process.env,
        PATH: enrichedPath,
      },
    });

    // Collect stderr output for diagnostics
    let stderrOutput = "";
    if (childProcess.stderr) {
      childProcess.stderr.on("data", (data: Buffer) => {
        stderrOutput += data.toString();
      });
    }

    // Track early exit
    let exitCode: number | null = null;
    childProcess.once("exit", (code) => {
      exitCode = code;
    });

    await new Promise<void>((resolve, reject) => {
      childProcess.once("spawn", resolve);
      childProcess.once("error", (error) => {
        reject(new Error(`Failed to spawn anvil (${anvilBinary}): ${error.message}`));
      });
    });

    // Unref the process so the parent can exit while child continues
    childProcess.unref();

    const chain: AnvilChain = {
      chainId,
      port,
      role,
      rpcUrl,
      process: childProcess,
    };

    this.chains.set(chainId, chain);

    // Save PID to file for tracking
    this.savePids();

    const isReady = await waitForChainReady(rpcUrl);
    if (!isReady) {
      // Log diagnostics to help debug CI failures
      if (exitCode !== null) {
        console.error(`   anvil process exited early with code ${exitCode}`);
      }
      if (stderrOutput) {
        console.error(`   anvil stderr: ${stderrOutput.trim()}`);
      }
      console.error(`   anvil command: ${anvilBinary} ${args.join(" ")}`);
      throw new Error(`Failed to start ${formatChainInfo(chainId, port, isL1)}`);
    }

    console.log(`✅ ${formatChainInfo(chainId, port, isL1)} started successfully`);
  }

  private savePids(): void {
    const pids: Record<number, number> = {};
    for (const [chainId, chain] of this.chains) {
      if (chain.process && chain.process.pid) {
        pids[chainId] = chain.process.pid;
      }
    }

    const dir = path.dirname(this.pidFilePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(this.pidFilePath, JSON.stringify(pids, null, 2));
  }

  async stopChain(chainId: number): Promise<void> {
    const chain = this.chains.get(chainId);
    if (!chain || !chain.process) {
      console.warn(`⚠️  No process found for chain ${chainId}`);
      return;
    }

    console.log(`🛑 Stopping chain ${chainId}...`);

    return new Promise((resolve) => {
      if (chain.process) {
        chain.process.on("exit", () => {
          console.log(`✅ Chain ${chainId} stopped`);
          resolve();
        });

        chain.process.kill("SIGTERM");

        setTimeout(() => {
          if (chain.process && !chain.process.killed) {
            console.log(`   Force killing chain ${chainId}...`);
            chain.process.kill("SIGKILL");
          }
          resolve();
        }, 5000);
      } else {
        resolve();
      }
    });
  }

  async stopAll(): Promise<void> {
    console.log("🛑 Stopping all Anvil chains...");
    const stopPromises = Array.from(this.chains.keys()).map((chainId) => this.stopChain(chainId));
    await Promise.all(stopPromises);
    this.chains.clear();

    // Clean up PID file
    if (fs.existsSync(this.pidFilePath)) {
      fs.unlinkSync(this.pidFilePath);
    }

    console.log("✅ All chains stopped");
  }

  getProvider(chainId: number): providers.JsonRpcProvider {
    const chain = this.chains.get(chainId);
    if (!chain) {
      throw new Error(`Chain ${chainId} not found`);
    }
    return new providers.JsonRpcProvider(chain.rpcUrl);
  }

  getL1Chain(): AnvilChain | undefined {
    return Array.from(this.chains.values()).find((chain) => chain.role === "l1");
  }

  getL2Chains(): AnvilChain[] {
    return Array.from(this.chains.values()).filter((chain) => chain.role !== "l1");
  }
}
