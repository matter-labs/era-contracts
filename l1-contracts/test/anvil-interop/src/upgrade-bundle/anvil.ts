import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  ANVIL_GAS_PRICE,
  ANVIL_READY_ATTEMPTS,
  ANVIL_READY_DELAY_MS,
  ANVIL_STOP_TIMEOUT_MS,
  SIGINT_EXIT_CODE,
  SIGTERM_EXIT_CODE,
} from "./constants";

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function isReady(provider: ethers.providers.JsonRpcProvider): Promise<boolean> {
  try {
    await provider.send("eth_chainId", []);
    return true;
  } catch {
    return false;
  }
}

async function stopProcess(child: ChildProcess): Promise<void> {
  if (!child.pid || child.exitCode !== null) return;
  const exitPromise = new Promise<boolean>((resolve) => child.once("exit", () => resolve(true)));
  child.kill("SIGTERM");
  const exited = await Promise.race([exitPromise, delay(ANVIL_STOP_TIMEOUT_MS).then(() => false)]);
  if (!exited && child.exitCode === null) child.kill("SIGKILL");
}

export interface AnvilForkOptions {
  port: number;
  forkUrl: string;
  forkBlock?: number;
  logPath: string;
}

export class AnvilFork {
  public readonly rpcUrl: string;
  public readonly provider: ethers.providers.JsonRpcProvider;
  private child?: ChildProcess;
  private disposed = false;

  private constructor(rpcUrl: string, child?: ChildProcess) {
    this.rpcUrl = rpcUrl;
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.child = child;
  }

  public static async connectOrStart(options: AnvilForkOptions): Promise<AnvilFork> {
    const rpcUrl = `http://localhost:${options.port}`;
    const existing = new ethers.providers.JsonRpcProvider(rpcUrl);
    if (await isReady(existing)) {
      console.log(`=== Step 0: reusing anvil on ${rpcUrl} ===`);
      return new AnvilFork(rpcUrl);
    }

    console.log(`=== Step 0: anvil fork on port ${options.port} ===`);
    const args = [
      "--port",
      String(options.port),
      "--auto-impersonate",
      "--disable-block-gas-limit",
      "--gas-price",
      ANVIL_GAS_PRICE.toString(),
      "--fork-url",
      options.forkUrl,
    ];
    if (options.forkBlock !== undefined) {
      console.log(`    pinning fork to block ${options.forkBlock}`);
      args.push("--fork-block-number", String(options.forkBlock));
    }

    fs.mkdirSync(path.dirname(options.logPath), { recursive: true });
    const log = fs.openSync(options.logPath, "w");
    const child = spawn("anvil", args, { stdio: ["ignore", log, log] });
    fs.closeSync(log);
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });

    const fork = new AnvilFork(rpcUrl, child);
    for (let attempt = 0; attempt < ANVIL_READY_ATTEMPTS; attempt += 1) {
      if (await isReady(fork.provider)) return fork;
      if (child.exitCode !== null) {
        throw new Error(`anvil exited with code ${child.exitCode} before becoming ready (see ${options.logPath})`);
      }
      await delay(ANVIL_READY_DELAY_MS);
    }
    await fork.dispose(false);
    throw new Error(`anvil failed to start (see ${options.logPath})`);
  }

  public async run<T>(keepAlive: boolean, action: (fork: AnvilFork) => Promise<T>): Promise<T> {
    const exitAfterCleanup = (exitCode: number): void => {
      void this.dispose(keepAlive).finally(() => process.exit(exitCode));
    };
    const interruptHandler = (): void => exitAfterCleanup(SIGINT_EXIT_CODE);
    const terminateHandler = (): void => exitAfterCleanup(SIGTERM_EXIT_CODE);
    process.once("SIGINT", interruptHandler);
    process.once("SIGTERM", terminateHandler);
    try {
      return await action(this);
    } finally {
      process.removeListener("SIGINT", interruptHandler);
      process.removeListener("SIGTERM", terminateHandler);
      await this.dispose(keepAlive);
    }
  }

  public async setNextBlockBaseFee(): Promise<void> {
    await this.provider.send("anvil_setNextBlockBaseFeePerGas", [ANVIL_GAS_PRICE.toHexString()]);
  }

  private async dispose(keepAlive: boolean): Promise<void> {
    if (this.disposed || !this.child) return;
    this.disposed = true;
    const child = this.child;
    this.child = undefined;
    if (keepAlive) {
      console.log(`Leaving anvil (pid ${child.pid}) running on ${this.rpcUrl} (KEEP_ANVIL=1)`);
      child.unref();
      return;
    }
    console.log(`Stopping anvil (pid ${child.pid})...`);
    await stopProcess(child);
  }
}
