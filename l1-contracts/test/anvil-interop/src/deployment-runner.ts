import * as fs from "fs";
import * as path from "path";
import type { providers } from "ethers";
import type { AnvilManager } from "./anvil-manager";
import { ForgeDeployer } from "./deployer";
import { ChainRegistry } from "./chain-registry";
import { GatewaySetup } from "./gateway-setup";
import { BatchSettler } from "./batch-settler";
import { L1ToL2Relayer } from "./l1-to-l2-relayer";
import { L2ToL2Relayer } from "./l2-to-l2-relayer";
import type {
  AnvilConfig,
  ChainAddresses,
  ChainInfo,
  CoreDeployedAddresses,
  CTMDeployedAddresses,
  DeploymentState,
} from "./types";
import { getDefaultAccountPrivateKey } from "./utils";
import { ETH_TOKEN_ADDRESS } from "./const";

function timeIt(label: string): () => void {
  const start = Date.now();
  console.log(`⏱️  [TIMING] Starting: ${label}`);
  return () => console.log(`⏱️  [TIMING] Finished: ${label} in ${((Date.now() - start) / 1000).toFixed(1)}s`);
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
    const chainsPath = path.join(this.stateDir, "chains.json");
    if (fs.existsSync(chainsPath)) {
      return JSON.parse(fs.readFileSync(chainsPath, "utf-8"));
    }
    return {};
  }

  saveState(state: DeploymentState): void {
    fs.writeFileSync(path.join(this.stateDir, "chains.json"), JSON.stringify(state, null, 2));
  }

  async step1StartChains(anvilManager: AnvilManager): Promise<{ chains: ChainInfo }> {
    console.log("=== Step 1: Starting Anvil Chains ===\n");

    const config = this.getConfig();

    await Promise.all(
      config.chains.map((chainConfig) =>
        anvilManager.startChain({
          chainId: chainConfig.chainId,
          port: chainConfig.port,
          isL1: chainConfig.isL1,
        })
      )
    );

    const l1Chain = anvilManager.getL1Chain();
    const l2Chains = anvilManager.getL2Chains();

    const chainInfo: ChainInfo = {
      l1: l1Chain || null,
      l2: l2Chains,
      config: config.chains,
    };

    const state = this.loadState();
    state.chains = chainInfo;
    this.saveState(state);

    return { chains: chainInfo };
  }

  async step2DeployL1(l1RpcUrl: string): Promise<{
    l1Addresses: CoreDeployedAddresses;
    ctmAddresses: CTMDeployedAddresses;
  }> {
    console.log("\n=== Step 2: Deploying L1 Contracts ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const deployer = new ForgeDeployer(l1RpcUrl, privateKey);

    let done = timeIt("deployL1Core (forge script)");
    const l1Addresses = await deployer.deployL1Core();
    done();
    console.log("\nL1 Core Addresses:");
    console.log(`  Bridgehub: ${l1Addresses.bridgehub}`);
    console.log(`  L1SharedBridge: ${l1Addresses.l1SharedBridge}`);

    // Accept bridgehub admin (required for Anvil)
    done = timeIt("acceptBridgehubAdmin");
    await deployer.acceptBridgehubAdmin(l1Addresses.bridgehub);
    done();

    done = timeIt("deployCTM (forge script)");
    const ctmAddresses = await deployer.deployCTM(l1Addresses.bridgehub);
    done();
    console.log("\nCTM Addresses:");
    console.log(`  ChainTypeManager: ${ctmAddresses.chainTypeManager}`);

    done = timeIt("registerCTM (forge script)");
    await deployer.registerCTM(l1Addresses.bridgehub, ctmAddresses.chainTypeManager);
    done();

    const state = this.loadState();
    state.l1Addresses = l1Addresses;
    state.ctmAddresses = ctmAddresses;
    this.saveState(state);

    return { l1Addresses, ctmAddresses };
  }

  async step3And4RegisterAndInitChains(
    l1RpcUrl: string,
    l2Chains: Array<{ chainId: number; rpcUrl: string }>,
    chainConfigs: AnvilConfig["chains"],
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ): Promise<{
    chainAddresses: ChainAddresses[];
  }> {
    console.log("\n=== Step 3+4: Register & Initialize L2 Chains (pipelined) ===\n");

    const privateKey = getDefaultAccountPrivateKey();
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    const chainAddresses: ChainAddresses[] = [];
    const initPromises: Promise<void>[] = [];

    // Register chains sequentially on L1 (nonce constraint), but start L2 init
    // immediately after each registration — L2 inits go to separate chains so
    // they can run concurrently with the next L1 registration.
    for (const l2Chain of l2Chains) {
      const chainConfig = chainConfigs.find((c) => c.chainId === l2Chain.chainId);
      const isGateway = chainConfig?.isGateway || false;

      const done = timeIt(`registerChain ${l2Chain.chainId} (forge script)`);
      const addresses = await registry.registerChain({
        chainId: l2Chain.chainId,
        rpcUrl: l2Chain.rpcUrl,
        baseToken: ETH_TOKEN_ADDRESS,
        validiumMode: false,
        isGateway,
      });
      done();

      chainAddresses.push(addresses);
      console.log(`  Chain ${l2Chain.chainId} registered at: ${addresses.diamondProxy}`);

      // Fire off L2 init immediately (runs on separate L2 Anvil instance)
      const initDone = timeIt(`initializeL2 chain ${l2Chain.chainId}`);
      initPromises.push(
        registry
          .initializeL2SystemContracts(l2Chain.chainId, addresses.diamondProxy, l2Chain.rpcUrl)
          .then(() => {
            initDone();
            console.log(`  Chain ${l2Chain.chainId} system contracts initialized`);
          })
      );
    }

    // Wait for any remaining L2 inits to complete
    await Promise.all(initPromises);

    const state = this.loadState();
    state.chainAddresses = chainAddresses;
    this.saveState(state);

    return { chainAddresses };
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
    l1Provider: providers.JsonRpcProvider,
    l2Providers: Map<number, providers.JsonRpcProvider>,
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
