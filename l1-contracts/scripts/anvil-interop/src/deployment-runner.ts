import * as fs from "fs";
import * as path from "path";
import type { JsonRpcProvider } from "ethers";
import { AnvilManager } from "./anvil-manager";
import { ForgeDeployer } from "./deployer";
import { ChainRegistry } from "./chain-registry";
import { GatewaySetup } from "./gateway-setup";
import { BatchSettler } from "./batch-settler";
import { L1ToL2Relayer } from "./l1-to-l2-relayer";
import { L2ToL2Relayer } from "./l2-to-l2-relayer";
import type { AnvilConfig, ChainAddresses, CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { getDefaultAccountPrivateKey, sleep } from "./utils";

export interface ChainInfo {
  l1: { chainId: number; rpcUrl: string; port: number } | null;
  l2: Array<{ chainId: number; rpcUrl: string; port: number }>;
  config: AnvilConfig["chains"];
}

export interface DeploymentState {
  chains?: ChainInfo;
  l1Addresses?: CoreDeployedAddresses;
  ctmAddresses?: CTMDeployedAddresses;
  chainAddresses?: ChainAddresses[];
}

export class DeploymentRunner {
  private stateDir: string;
  private configPath: string;

  constructor(baseDir: string = __dirname + "/..") {
    this.stateDir = path.join(baseDir, "outputs/state");
    this.configPath = path.join(baseDir, "config/anvil-config.json");
    fs.mkdirSync(this.stateDir, { recursive: true });
  }

  getConfig(): AnvilConfig {
    return JSON.parse(fs.readFileSync(this.configPath, "utf-8"));
  }

  loadState(): DeploymentState {
    const state: DeploymentState = {};

    const chainsPath = path.join(this.stateDir, "chains.json");
    if (fs.existsSync(chainsPath)) {
      state.chains = JSON.parse(fs.readFileSync(chainsPath, "utf-8"));
    }

    const l1DeploymentPath = path.join(this.stateDir, "l1-deployment.json");
    if (fs.existsSync(l1DeploymentPath)) {
      const deployment = JSON.parse(fs.readFileSync(l1DeploymentPath, "utf-8"));
      state.l1Addresses = deployment.l1Addresses;
      state.ctmAddresses = deployment.ctmAddresses;
    }

    const chainAddressesPath = path.join(this.stateDir, "chain-addresses.json");
    if (fs.existsSync(chainAddressesPath)) {
      state.chainAddresses = JSON.parse(fs.readFileSync(chainAddressesPath, "utf-8"));
    }

    return state;
  }

  saveChains(chainInfo: ChainInfo): void {
    fs.writeFileSync(path.join(this.stateDir, "chains.json"), JSON.stringify(chainInfo, null, 2));
  }

  saveL1Deployment(l1Addresses: CoreDeployedAddresses, ctmAddresses: CTMDeployedAddresses): void {
    fs.writeFileSync(
      path.join(this.stateDir, "l1-deployment.json"),
      JSON.stringify({ l1Addresses, ctmAddresses }, null, 2)
    );
  }

  saveChainAddresses(chainAddresses: ChainAddresses[]): void {
    fs.writeFileSync(path.join(this.stateDir, "chain-addresses.json"), JSON.stringify(chainAddresses, null, 2));
  }

  async step1StartChains(
    anvilManager: AnvilManager
  ): Promise<{ chains: ChainInfo }> {
    console.log("=== Step 1: Starting Anvil Chains ===\n");

    const config = this.getConfig();

    for (const chainConfig of config.chains) {
      await anvilManager.startChain({
        chainId: chainConfig.chainId,
        port: chainConfig.port,
        isL1: chainConfig.isL1,
      });
    }

    await sleep(2000);

    const l1Chain = anvilManager.getL1Chain();
    const l2Chains = anvilManager.getL2Chains();

    const chainInfo: ChainInfo = {
      l1: l1Chain || null,
      l2: l2Chains,
      config: config.chains,
    };

    this.saveChains(chainInfo);

    return { chains: chainInfo };
  }

  async step2DeployL1(l1RpcUrl: string): Promise<{
    l1Addresses: CoreDeployedAddresses;
    ctmAddresses: CTMDeployedAddresses;
  }> {
    console.log("\n=== Step 2: Deploying L1 Contracts ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const deployer = new ForgeDeployer(l1RpcUrl, privateKey);

    const l1Addresses = await deployer.deployL1Core();
    console.log("\nL1 Core Addresses:");
    console.log(`  Bridgehub: ${l1Addresses.bridgehub}`);
    console.log(`  L1SharedBridge: ${l1Addresses.l1SharedBridge}`);

    // Accept bridgehub admin (required for Anvil)
    await deployer.acceptBridgehubAdmin(l1Addresses.bridgehub);

    const ctmAddresses = await deployer.deployCTM(l1Addresses.bridgehub);
    console.log("\nCTM Addresses:");
    console.log(`  ChainTypeManager: ${ctmAddresses.chainTypeManager}`);

    await deployer.registerCTM(l1Addresses.bridgehub, ctmAddresses.chainTypeManager);

    this.saveL1Deployment(l1Addresses, ctmAddresses);

    return { l1Addresses, ctmAddresses };
  }

  async step3RegisterChains(
    l1RpcUrl: string,
    l2Chains: Array<{ chainId: number; rpcUrl: string }>,
    chainConfigs: AnvilConfig["chains"],
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ): Promise<{
    chainAddresses: ChainAddresses[];
  }> {
    console.log("\n=== Step 3: Registering L2 Chains ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    const chainAddresses: ChainAddresses[] = [];

    for (const l2Chain of l2Chains) {
      const chainConfig = chainConfigs.find((c) => c.chainId === l2Chain.chainId);
      const isGateway = chainConfig?.isGateway || false;

      const addresses = await registry.registerChain({
        chainId: l2Chain.chainId,
        rpcUrl: l2Chain.rpcUrl,
        baseToken: "0x0000000000000000000000000000000000000001",
        validiumMode: false,
        isGateway,
      });

      chainAddresses.push(addresses);

      console.log(`  Chain ${l2Chain.chainId} registered at: ${addresses.diamondProxy}`);
    }

    this.saveChainAddresses(chainAddresses);

    return { chainAddresses };
  }

  async step4InitializeL2(
    l1RpcUrl: string,
    chainAddresses: ChainAddresses[],
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ): Promise<void> {
    console.log("\n=== Step 4: Initializing L2 System Contracts ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    for (const chain of chainAddresses) {
      await registry.initializeL2SystemContracts(chain.chainId, chain.diamondProxy);
      console.log(`  Chain ${chain.chainId} system contracts initialized`);
    }
  }

  async step5SetupGateway(
    l1RpcUrl: string,
    gatewayChainId: number,
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ): Promise<{ gatewayCTMAddr: string }> {
    console.log("\n=== Step 5: Setting Up Gateway ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const gatewaySetup = new GatewaySetup(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    const gatewayCTMAddr = await gatewaySetup.designateAsGateway(gatewayChainId);

    console.log(`  Gateway CTM: ${gatewayCTMAddr}`);

    return { gatewayCTMAddr };
  }

  async step6StartBatchSettler(
    l1Provider: JsonRpcProvider,
    l2Providers: Map<number, JsonRpcProvider>,
    chainAddresses: Map<number, ChainAddresses>,
    config: AnvilConfig
  ): Promise<{ settler: BatchSettler; l1ToL2Relayer: L1ToL2Relayer; l2ToL2Relayer: L2ToL2Relayer }> {
    console.log("\n=== Step 6: Starting Daemons ===\n");

    const privateKey = getDefaultAccountPrivateKey();

    // Start L1→L2 Relayer
    console.log("Starting L1→L2 Transaction Relayer...");
    const l1ToL2Relayer = new L1ToL2Relayer(
      l1Provider,
      l2Providers,
      privateKey,
      this.loadState().l1Addresses!,
      chainAddresses,
      2000 // Poll every 2 seconds
    );
    await l1ToL2Relayer.start();

    // Start L2→L2 Cross-Chain Relayer
    console.log("\nStarting L2→L2 Cross-Chain Relayer...");
    const l2ToL2Relayer = new L2ToL2Relayer(
      l1Provider,
      l2Providers,
      privateKey,
      this.loadState().l1Addresses!,
      chainAddresses,
      2000 // Poll every 2 seconds
    );
    await l2ToL2Relayer.start();

    // Start Batch Settler
    console.log("\nStarting Batch Settler...");
    const settler = new BatchSettler(
      l1Provider,
      l2Providers,
      privateKey,
      chainAddresses,
      config.batchSettler.pollingIntervalMs,
      config.batchSettler.batchSizeLimit
    );
    await settler.start();

    console.log("\n✅ All daemons started");

    return { settler, l1ToL2Relayer, l2ToL2Relayer };
  }
}
