import { spawn } from "child_process";
import { JsonRpcProvider } from "ethers";
import type { AnvilChain } from "./types";
import { waitForChainReady, formatChainInfo } from "./utils";

export class AnvilManager {
  private chains: Map<number, AnvilChain> = new Map();

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
      "--auto-impersonate", // Allow impersonating any address without signatures
    ];

    const process = spawn("anvil", args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    process.stdout?.on("data", (data) => {
      const output = data.toString();
      if (output.includes("Listening on")) {
        console.log(`   Anvil listening for chain ${chainId}`);
      }
    });

    process.stderr?.on("data", (data) => {
      console.error(`   Anvil error (chain ${chainId}): ${data.toString()}`);
    });

    process.on("exit", (code) => {
      console.log(`   Anvil process exited for chain ${chainId} with code ${code}`);
    });

    const chain: AnvilChain = {
      chainId,
      port,
      isL1,
      rpcUrl,
      process,
    };

    this.chains.set(chainId, chain);

    const isReady = await waitForChainReady(rpcUrl);
    if (!isReady) {
      throw new Error(`Failed to start ${formatChainInfo(chainId, port, isL1)}`);
    }

    console.log(`✅ ${formatChainInfo(chainId, port, isL1)} started successfully`);
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
