import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  DEFAULT_GATEWAY_RPC_URL,
  DEFAULT_ZK_GOVERNANCE_COMMIT,
  REPLAY_PORT_OFFSET,
  V31_UPGRADE_NAME,
} from "./constants";
import { AnvilFork } from "./anvil";
import { anvilPort, loadUpgradeEnvironment, parseUpgradeEnvironment } from "./environment";
import { L1_CONTRACTS_DIR, REPO_ROOT, fileSha256, requireFile, writeCombinedLog } from "./file-system";
import { fundBundleTargets } from "./funding";
import { verifyBundleIntegrity } from "./integrity";
import { ProtocolOps } from "./operations";

export interface ReplayOptions {
  bundleDirectory: string;
  forkUrl?: string;
  rpcUrl?: string;
  deployerKey?: string;
  verifyOnly: boolean;
}

export async function replayBundleAndVerify(args: ReplayOptions): Promise<void> {
  if (Boolean(args.forkUrl) === Boolean(args.rpcUrl)) {
    throw new Error("replay requires exactly one of forkUrl or rpcUrl");
  }
  requireFile(path.join(args.bundleDirectory, "bundle-metadata.json"), "deploy bundle metadata");
  const metadata = verifyBundleIntegrity(args.bundleDirectory);
  const environment = parseUpgradeEnvironment(metadata.env);
  const deployer = metadata.deployer_address ? ethers.utils.getAddress(metadata.deployer_address) : undefined;
  if (!deployer) throw new Error("bundle metadata has no deployer_address");
  if (args.deployerKey) {
    let signerAddress: string;
    try {
      signerAddress = new ethers.Wallet(args.deployerKey).address;
    } catch {
      throw new Error("the supplied private key is invalid");
    }
    if (signerAddress !== deployer) {
      throw new Error("the supplied private key does not match the bundle deployer");
    }
  }
  const config = loadUpgradeEnvironment(environment);

  console.log(`Env:          ${environment}`);
  console.log(`Bundle:       ${args.bundleDirectory}`);
  console.log(`Deployer:     ${deployer}`);

  const localHashesSha = fileSha256(path.join(REPO_ROOT, "AllContractsHashes.json"));
  if (!metadata.all_contracts_hashes_sha256) throw new Error("bundle metadata has no all_contracts_hashes_sha256");
  if (localHashesSha !== metadata.all_contracts_hashes_sha256) {
    throw new Error(
      "AllContractsHashes.json differs from the bundle's.\n" +
        `  bundle: ${metadata.all_contracts_hashes_sha256} (commit ${metadata.contracts_commit})\n` +
        `  local:  ${localHashesSha}\n` +
        `PUVT will not recognise the deployed bytecode. Check out ${metadata.contracts_commit} first.`
    );
  }

  const protocolOps = new ProtocolOps();
  console.log(`protocol_ops: ${protocolOps.executable}`);
  const workDirectory = path.join(args.bundleDirectory, "replay");
  fs.mkdirSync(workDirectory, { recursive: true });
  if (args.forkUrl && metadata.l1.forked_at_block === null) {
    console.warn(
      "WARNING: the bundle records no fork height — forking at chain tip. " +
        "If the upgrade is live, re-pack with FORKED_AT_BLOCK or pass --rpc."
    );
  }
  const replay = async (
    provider: ethers.providers.JsonRpcProvider,
    rpcUrl: string,
    setNextBlockBaseFee?: () => Promise<void>
  ): Promise<void> => {
    console.log(`L1 RPC:       ${rpcUrl}`);
    const gatewayRpcUrl = process.env.GW_RPC_URL ?? DEFAULT_GATEWAY_RPC_URL;
    console.log(`GW RPC:       ${gatewayRpcUrl}`);

    const manifestPath = path.join(args.bundleDirectory, "prepare/manifest.json");
    const executedPath = path.join(workDirectory, "executed.json");
    const transactionsPath = path.join(workDirectory, "transactions.txt");
    if (args.verifyOnly) {
      console.log("=== Steps 1-2: SKIPPED (--verify-only) ===");
    } else {
      if (args.forkUrl) {
        console.log("=== Step 1: fund every bundle signer (fork only) ===");
        await fundBundleTargets(provider, {
          bridgehubAddress: config.bridgehubAddress,
          zkAssetId: config.zkAssetId,
          hasGateway: config.hasGateway,
          manifestPath,
          ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
          deployerAddress: deployer,
        });
        if (!setNextBlockBaseFee) throw new Error("fork replay requires Anvil RPC controls");
        await setNextBlockBaseFee();
      }
      console.log("=== Step 2: upgrade-broadcast ===");
      await protocolOps.broadcast({
        manifestPath,
        rpcUrl,
        outputPath: executedPath,
        deployer,
        privateKey: args.deployerKey,
      });
    }

    console.log("=== Step 3: verify-upgrade (PUVT) ===");
    const combinedTransactionsPath = path.join(workDirectory, "transactions.combined.txt");
    const realTransactionsPath = path.join(
      L1_CONTRACTS_DIR,
      "upgrade-envs",
      V31_UPGRADE_NAME,
      "output",
      environment,
      "transactions.txt"
    );
    writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, transactionsPath]);
    await protocolOps.verify({
      environment,
      ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit:
        process.env.ZK_GOVERNANCE_COMMIT ?? metadata.zk_governance_commit ?? DEFAULT_ZK_GOVERNANCE_COMMIT,
    });
    console.log("=== Done ===");
  };

  if (args.forkUrl) {
    const anvil = await AnvilFork.connectOrStart({
      port: anvilPort(environment) + REPLAY_PORT_OFFSET,
      forkUrl: args.forkUrl,
      forkBlock: metadata.l1.forked_at_block ?? undefined,
      logPath: path.join(workDirectory, "anvil.log"),
    });
    await anvil.run(process.env.KEEP_ANVIL === "1", ({ provider, rpcUrl }) =>
      replay(provider, rpcUrl, () => anvil.setNextBlockBaseFee())
    );
  } else if (args.rpcUrl) {
    await replay(new ethers.providers.JsonRpcProvider(args.rpcUrl), args.rpcUrl);
  }
}
