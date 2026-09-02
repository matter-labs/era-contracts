import type { ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  ANVIL_GAS_PRICE_WEI,
  DEFAULT_GATEWAY_RPC_URL,
  DEFAULT_ZK_GOVERNANCE_COMMIT,
  SIGINT_EXIT_CODE,
  SIGTERM_EXIT_CODE,
  V31_UPGRADE_NAME,
} from "./constants";
import {
  L1_CONTRACTS_DIR,
  envAnvilPort,
  envFlag,
  envHasGateway,
  fundBundleTargets,
  isRpcReady,
  locateProtocolOps,
  parseInteger,
  readToml,
  requireFile,
  requireTomlString,
  startAnvilFork,
  stopAnvil,
  writeCombinedLog,
} from "./common";
import { broadcastUpgrade, prepareUpgrade, verifyUpgrade } from "./operations";
import { packDeployBundle } from "./pack";

function resolveDeployer(): string {
  if (process.env.DEPLOYER_ADDR) return ethers.utils.getAddress(process.env.DEPLOYER_ADDR);
  let privateKey = process.env.DEPLOYER_PK;
  if (!privateKey && process.env.DEPLOYER_PK_FILE) {
    requireFile(process.env.DEPLOYER_PK_FILE, "DEPLOYER_PK_FILE");
    privateKey = fs.readFileSync(process.env.DEPLOYER_PK_FILE, "utf8").replace(/\s/g, "");
  }
  if (!privateKey) {
    throw new Error("Set DEPLOYER_ADDR, DEPLOYER_PK, or DEPLOYER_PK_FILE before running");
  }
  return new ethers.Wallet(privateKey).address;
}

export async function regenerateAndVerify(environment: string): Promise<void> {
  const forkUrl = process.env.L1_FORK_URL;
  if (!forkUrl) throw new Error("L1_FORK_URL is required");
  const port = envAnvilPort(environment);
  const rpcUrl = `http://localhost:${port}`;
  console.log(`Env:          ${environment} (anvil port ${port})`);

  const outputDirectory = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", environment);
  const permanentValuesPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${environment}.toml`);
  const v31InputPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, `${environment}.toml`);
  requireFile(permanentValuesPath, "config");
  requireFile(v31InputPath, "config");
  const permanentValues = readToml(permanentValuesPath);
  const v31Input = readToml(v31InputPath);
  const bridgehub = requireTomlString(v31Input, "bridgehub_proxy_address", v31InputPath);
  const deployer = resolveDeployer();
  const zkAssetId = requireTomlString(permanentValues, "zk_token_asset_id", permanentValuesPath);
  const hasGateway = envHasGateway(permanentValues);
  const gatewayRpcUrl = process.env.GW_RPC_URL ?? DEFAULT_GATEWAY_RPC_URL;
  const zkGovernanceCommit = process.env.ZK_GOVERNANCE_COMMIT ?? DEFAULT_ZK_GOVERNANCE_COMMIT;
  console.log(`Bridgehub:    ${bridgehub}`);
  console.log(`Deployer EOA: ${deployer}`);
  console.log(`ZK asset id:  ${zkAssetId}`);
  console.log(`New gateway:  ${hasGateway ? "yes" : "no (ZK funding best-effort)"}`);
  console.log(`GW RPC:       ${gatewayRpcUrl}`);
  console.log(`zk-gov commit: ${zkGovernanceCommit}`);
  const protocolOps = locateProtocolOps();
  console.log(`Using protocol_ops at: ${protocolOps}`);

  const keepAnvil = envFlag("KEEP_ANVIL");
  let anvil: ChildProcess | undefined;
  const cleanup = async (): Promise<void> => {
    if (!anvil) return;
    if (keepAnvil) {
      console.log(`Leaving anvil (pid ${anvil.pid}) running on ${rpcUrl} (KEEP_ANVIL=1)`);
      anvil.unref();
      return;
    }
    console.log(`Stopping anvil (pid ${anvil.pid})...`);
    await stopAnvil(anvil);
    anvil = undefined;
  };
  const interruptHandler = (): void => {
    void cleanup().finally(() => process.exit(SIGINT_EXIT_CODE));
  };
  const terminateHandler = (): void => {
    void cleanup().finally(() => process.exit(SIGTERM_EXIT_CODE));
  };
  process.once("SIGINT", interruptHandler);
  process.once("SIGTERM", terminateHandler);

  try {
    const skipPrepare = envFlag("SKIP_PREPARE");
    if (!skipPrepare) {
      const transactionsPath = path.join(outputDirectory, "transactions.txt");
      const transactions = fs.existsSync(transactionsPath) ? fs.readFileSync(transactionsPath) : undefined;
      fs.rmSync(outputDirectory, { recursive: true, force: true });
      fs.mkdirSync(outputDirectory, { recursive: true });
      if (transactions) fs.writeFileSync(transactionsPath, transactions);
    } else {
      fs.mkdirSync(outputDirectory, { recursive: true });
    }

    if (await isRpcReady(rpcUrl)) {
      console.log(`=== Step 0: reusing anvil on ${rpcUrl} ===`);
    } else {
      console.log(`=== Step 0: anvil fork on port ${port} ===`);
      anvil = await startAnvilFork({
        port,
        forkUrl,
        forkBlock: parseInteger(process.env.FORK_BLOCK, "FORK_BLOCK"),
        logPath: path.join(outputDirectory, "anvil.log"),
      });
    }
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    const forkedAtBlock = await provider.getBlockNumber();
    console.log(`Forked at block: ${forkedAtBlock}`);

    const prepareDirectory = path.join(outputDirectory, "prepare");
    const manifestPath = path.join(prepareDirectory, "manifest.json");
    if (skipPrepare && fs.existsSync(manifestPath)) {
      console.log(`=== Step 1: SKIPPED (SKIP_PREPARE=1, reusing existing ${prepareDirectory}) ===`);
    } else {
      console.log("=== Step 1: upgrade-prepare-all (this takes ~12 min) ===");
      await prepareUpgrade({
        protocolOps,
        environment,
        bridgehub,
        rpcUrl,
        deployer,
        outputDirectory: prepareDirectory,
      });
    }

    console.log("=== Step 1b: pack the deploy bundle ===");
    process.env.DEPLOYER_ADDR = deployer;
    process.env.FORKED_AT_BLOCK = String(forkedAtBlock);
    process.env.ZK_GOVERNANCE_COMMIT = zkGovernanceCommit;
    packDeployBundle(environment);

    const forkDirectory = path.join(outputDirectory, "fork-rehearsal");
    const forkTransactionsPath = path.join(forkDirectory, "transactions.txt");
    const combinedTransactionsPath = path.join(forkDirectory, "transactions.combined.txt");
    const realTransactionsPath = path.join(outputDirectory, "transactions.txt");
    if (envFlag("SKIP_BROADCAST") && fs.existsSync(path.join(forkDirectory, "executed.json"))) {
      console.log(`=== Steps 2-3: SKIPPED (SKIP_BROADCAST=1, reusing ${forkDirectory}/executed.json) ===`);
      console.log("=== Step 4: verify-upgrade (PUVT) ===");
      writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
      await verifyUpgrade({
        protocolOps,
        environment,
        ecosystemTomlPath: path.join(outputDirectory, "ecosystem.toml"),
        rpcUrl,
        gatewayRpcUrl,
        transactionsLogPath: combinedTransactionsPath,
        zkGovernanceCommit,
      });
      console.log("=== Done ===");
      return;
    }

    console.log("=== Step 2: resolve NTV + ZK token, fund every bundle target ===");
    await fundBundleTargets({
      rpcUrl,
      bridgehub,
      zkAssetId,
      hasGateway,
      manifestPath,
      ecosystemTomlPath: path.join(outputDirectory, "ecosystem.toml"),
      deployer,
    });

    console.log("=== Step 3: upgrade-broadcast --unlocked --out ===");
    fs.rmSync(forkDirectory, { recursive: true, force: true });
    fs.mkdirSync(forkDirectory, { recursive: true });
    await provider.send("anvil_setNextBlockBaseFeePerGas", [`0x${ANVIL_GAS_PRICE_WEI.toString(16)}`]);
    await broadcastUpgrade({
      protocolOps,
      manifestPath,
      rpcUrl,
      outputPath: path.join(forkDirectory, "executed.json"),
    });

    console.log("=== Step 4: verify-upgrade (PUVT) ===");
    writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
    await verifyUpgrade({
      protocolOps,
      environment,
      ecosystemTomlPath: path.join(outputDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit,
    });
    console.log("=== Done ===");
  } finally {
    process.removeListener("SIGINT", interruptHandler);
    process.removeListener("SIGTERM", terminateHandler);
    await cleanup();
  }
}
