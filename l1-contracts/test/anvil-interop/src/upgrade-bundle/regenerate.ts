import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { DEFAULT_GATEWAY_RPC_URL, DEFAULT_ZK_GOVERNANCE_COMMIT } from "./constants";
import { AnvilFork } from "./anvil";
import { anvilPort, loadUpgradeEnvironment, parseUpgradeEnvironment } from "./environment";
import { parseInteger, requireFile, writeCombinedLog } from "./file-system";
import { fundBundleTargets } from "./funding";
import { ProtocolOps } from "./operations";
import { bundleProvenanceFromEnvironment, packDeployBundle } from "./pack";

function environmentFlag(name: string): boolean {
  return process.env[name] === "1";
}

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
  try {
    return new ethers.Wallet(privateKey).address;
  } catch {
    throw new Error("The configured deployer private key is invalid");
  }
}

export async function regenerateAndVerify(environment: string): Promise<void> {
  const forkUrl = process.env.L1_FORK_URL;
  if (!forkUrl) throw new Error("L1_FORK_URL is required");
  const environmentName = parseUpgradeEnvironment(environment);
  const config = loadUpgradeEnvironment(environmentName);
  const port = anvilPort(environmentName);
  console.log(`Env:          ${environmentName} (anvil port ${port})`);
  const deployer = resolveDeployer();
  const gatewayRpcUrl = process.env.GW_RPC_URL ?? DEFAULT_GATEWAY_RPC_URL;
  const zkGovernanceCommit = process.env.ZK_GOVERNANCE_COMMIT ?? DEFAULT_ZK_GOVERNANCE_COMMIT;
  console.log(`Bridgehub:    ${config.bridgehubAddress}`);
  console.log(`Deployer EOA: ${deployer}`);
  console.log(`ZK asset id:  ${config.zkAssetId}`);
  console.log(`New gateway:  ${config.hasGateway ? "yes" : "no (ZK funding best-effort)"}`);
  console.log(`GW RPC:       ${gatewayRpcUrl}`);
  console.log(`zk-gov commit: ${zkGovernanceCommit}`);
  const protocolOps = new ProtocolOps();
  console.log(`Using protocol_ops at: ${protocolOps.executable}`);

  const skipPrepare = environmentFlag("SKIP_PREPARE");
  if (!skipPrepare) {
    const transactionsPath = path.join(config.outputDirectory, "transactions.txt");
    const transactions = fs.existsSync(transactionsPath) ? fs.readFileSync(transactionsPath) : undefined;
    fs.rmSync(config.outputDirectory, { recursive: true, force: true });
    fs.mkdirSync(config.outputDirectory, { recursive: true });
    if (transactions) fs.writeFileSync(transactionsPath, transactions);
  } else {
    fs.mkdirSync(config.outputDirectory, { recursive: true });
  }

  const anvil = await AnvilFork.connectOrStart({
    port,
    forkUrl,
    forkBlock: parseInteger(process.env.FORK_BLOCK, "FORK_BLOCK"),
    logPath: path.join(config.outputDirectory, "anvil.log"),
  });
  await anvil.run(environmentFlag("KEEP_ANVIL"), async ({ provider, rpcUrl }) => {
    const forkedAtBlock = await provider.getBlockNumber();
    console.log(`Forked at block: ${forkedAtBlock}`);

    const prepareDirectory = path.join(config.outputDirectory, "prepare");
    const manifestPath = path.join(prepareDirectory, "manifest.json");
    if (skipPrepare && fs.existsSync(manifestPath)) {
      console.log(`=== Step 1: SKIPPED (SKIP_PREPARE=1, reusing existing ${prepareDirectory}) ===`);
    } else {
      console.log("=== Step 1: upgrade-prepare-all (this takes ~12 min) ===");
      await protocolOps.prepare({
        environment: environmentName,
        bridgehub: config.bridgehubAddress,
        rpcUrl,
        deployer,
        outputDirectory: prepareDirectory,
      });
    }

    console.log("=== Step 1b: pack the deploy bundle ===");
    packDeployBundle(environmentName, {
      provenance: bundleProvenanceFromEnvironment({
        deployerAddress: deployer,
        forkedAtBlock,
        zkGovernanceCommit,
      }),
    });

    const forkDirectory = path.join(config.outputDirectory, "fork-rehearsal");
    const forkTransactionsPath = path.join(forkDirectory, "transactions.txt");
    const combinedTransactionsPath = path.join(forkDirectory, "transactions.combined.txt");
    const realTransactionsPath = path.join(config.outputDirectory, "transactions.txt");
    if (environmentFlag("SKIP_BROADCAST") && fs.existsSync(path.join(forkDirectory, "executed.json"))) {
      console.log(`=== Steps 2-3: SKIPPED (SKIP_BROADCAST=1, reusing ${forkDirectory}/executed.json) ===`);
      console.log("=== Step 4: verify-upgrade (PUVT) ===");
      writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
      await protocolOps.verify({
        environment: environmentName,
        ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
        rpcUrl,
        gatewayRpcUrl,
        transactionsLogPath: combinedTransactionsPath,
        zkGovernanceCommit,
      });
      console.log("=== Done ===");
      return;
    }

    console.log("=== Step 2: resolve NTV + ZK token, fund every bundle target ===");
    await fundBundleTargets(provider, {
      bridgehubAddress: config.bridgehubAddress,
      zkAssetId: config.zkAssetId,
      hasGateway: config.hasGateway,
      manifestPath,
      ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
      deployerAddress: deployer,
    });

    console.log("=== Step 3: upgrade-broadcast --unlocked --out ===");
    fs.rmSync(forkDirectory, { recursive: true, force: true });
    fs.mkdirSync(forkDirectory, { recursive: true });
    await anvil.setNextBlockBaseFee();
    await protocolOps.broadcast({
      manifestPath,
      rpcUrl,
      outputPath: path.join(forkDirectory, "executed.json"),
    });

    console.log("=== Step 4: verify-upgrade (PUVT) ===");
    writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
    await protocolOps.verify({
      environment: environmentName,
      ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit,
    });
    console.log("=== Done ===");
  });
}
