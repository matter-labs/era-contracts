import { spawn } from "child_process";
import { JsonRpcProvider } from "ethers";
import * as fs from "fs";
import * as path from "path";
import type { AnvilChain } from "./types";
import { waitForChainReady, formatChainInfo } from "./utils";

export class AnvilManager {
  private chains: Map<number, AnvilChain> = new Map();
  private pidFilePath: string;

  constructor() {
    this.pidFilePath = path.join(__dirname, "../outputs/anvil-pids.json");
  }

  async startChain(config: Omit<AnvilChain, "rpcUrl" | "process">): Promise<void> {
    const { chainId, port, isL1 } = config;
    const rpcUrl = `http://127.0.0.1:${port}`;

    console.log(`🚀 Starting ${formatChainInfo(chainId, port, isL1)}...`);

    const args = [
      "--port",
      port.toString(),
      "--chain-id",
      chainId.toString(),
      "--accounts",
      "10",
      "--balance",
      "10000",
      "--block-time",
      "1",
      "--gas-limit",
      "100000000", // Increase block gas limit to 100M to accommodate L2 genesis upgrade
      "--auto-impersonate", // Allow impersonating any address without signatures
    ];

    const process = spawn("anvil", args, {
      stdio: "ignore", // Must ignore all streams for detached process to truly detach
      detached: true, // Detach from parent process
    });

    // Unref the process so the parent can exit while child continues
    process.unref();

    const chain: AnvilChain = {
      chainId,
      port,
      isL1,
      rpcUrl,
      process,
    };

    this.chains.set(chainId, chain);

    // Save PID to file for tracking
    this.savePids();

    const isReady = await waitForChainReady(rpcUrl);
    if (!isReady) {
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

  loadPids(): void {
    if (!fs.existsSync(this.pidFilePath)) {
      return;
    }

    try {
      const pids = JSON.parse(fs.readFileSync(this.pidFilePath, "utf-8"));
      console.log("📋 Found existing Anvil PIDs:", pids);
      console.log("   (Use 'yarn cleanup' to stop them)");
    } catch (error) {
      console.warn("⚠️  Could not read PID file:", error);
    }
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

  getProvider(chainId: number): JsonRpcProvider {
    const chain = this.chains.get(chainId);
    if (!chain) {
      throw new Error(`Chain ${chainId} not found`);
    }
    return new JsonRpcProvider(chain.rpcUrl);
  }

  getChain(chainId: number): AnvilChain | undefined {
    return this.chains.get(chainId);
  }

  getAllChains(): AnvilChain[] {
    return Array.from(this.chains.values());
  }

  getL1Chain(): AnvilChain | undefined {
    return Array.from(this.chains.values()).find((chain) => chain.isL1);
  }

  getL2Chains(): AnvilChain[] {
    return Array.from(this.chains.values()).filter((chain) => !chain.isL1);
  }
}
