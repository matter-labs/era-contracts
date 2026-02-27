import * as fs from "fs";
import * as path from "path";
import { Contract, Wallet, providers } from "ethers";
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
import { loadBytecodeFromOut } from "./utils";
import { dummyL1MessageRootAbi, migratorFacetAbi } from "./contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS } from "./const";

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
    const config: AnvilConfig = JSON.parse(fs.readFileSync(this.configPath, "utf-8"));
    const portOffset = parseInt(process.env.ANVIL_INTEROP_PORT_OFFSET || "0", 10);
    if (portOffset) {
      config.chains = config.chains.map((c) => ({ ...c, port: c.port + portOffset }));
    }
    return config;
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

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
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

    // Replace L1MessageRoot proxy code with DummyL1MessageRoot
    // This preserves all storage (chain registrations, batch roots) but bypasses proof verification
    if (l1Addresses.messageRoot) {
      const dummyBytecode = loadBytecodeFromOut("DummyL1MessageRoot.sol/DummyL1MessageRoot.json");
      const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
      await l1Provider.send("anvil_setCode", [l1Addresses.messageRoot, dummyBytecode]);

      // Set stored addresses since immutables are lost after code replacement
      const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
      const wallet = new Wallet(privateKey, l1Provider);
      const dummy = new Contract(l1Addresses.messageRoot, dummyL1MessageRootAbi(), wallet);
      const setAddrTx = await dummy.setStoredAddresses(
        l1Addresses.bridgehub,
        l1Addresses.l1AssetTracker,
        11, // ERA_GATEWAY_CHAIN_ID
        { gasLimit: 500_000 }
      );
      await setAddrTx.wait();
      console.log(`   Replaced L1MessageRoot proxy (${l1Addresses.messageRoot}) with DummyL1MessageRoot`);
    }

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
    console.log("\n=== Step 3+4: Register & Initialize L2 Chains ===\n");

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    // Batch-register all chains in a single forge call (avoids nonce conflicts)
    const configs = l2Chains.map((l2Chain) => {
      const chainConfig = chainConfigs.find((c) => c.chainId === l2Chain.chainId);
      return {
        chainId: l2Chain.chainId,
        rpcUrl: l2Chain.rpcUrl,
        baseToken: ETH_TOKEN_ADDRESS,
        validiumMode: false,
        isGateway: chainConfig?.isGateway || false,
      };
    });

    const regDone = timeIt(`registerChains batch [${configs.map((c) => c.chainId).join(",")}]`);
    const chainAddresses = await registry.registerChainBatch(configs);
    regDone();

    for (const addr of chainAddresses) {
      console.log(`  Chain ${addr.chainId} registered at: ${addr.diamondProxy}`);
    }

    // Initialize all L2 chains in parallel (each goes to a separate Anvil instance)
    console.log("\nInitializing L2 system contracts (in parallel)...\n");
    await Promise.all(
      chainAddresses.map(async (chain) => {
        const l2Chain = l2Chains.find((c) => c.chainId === chain.chainId);
        if (!l2Chain) {
          throw new Error(`L2 chain ${chain.chainId} not found`);
        }
        const done = timeIt(`initializeL2 chain ${chain.chainId}`);
        await registry.initializeL2SystemContracts(chain.chainId, chain.diamondProxy, l2Chain.rpcUrl);
        done();
        console.log(`  Chain ${chain.chainId} system contracts initialized`);
      })
    );

    // Unpause deposits on all chains (deposits are paused by default during initializeNewChain)
    console.log("\nUnpausing deposits on all chains...");
    const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    const wallet = new Wallet(privateKey, l1Provider);
    for (const chain of chainAddresses) {
      const migrator = new Contract(chain.diamondProxy, migratorFacetAbi(), wallet);
      const tx = await migrator.unpauseDeposits({ gasLimit: 500_000 });
      await tx.wait();
      console.log(`  Deposits unpaused on chain ${chain.chainId}`);
    }

    const state = this.loadState();
    state.chainAddresses = chainAddresses;
    this.saveState(state);

    return { chainAddresses };
  }

  async step5SetupGateway(
    l1RpcUrl: string,
    gatewayChainId: number,
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses,
    gwRpcUrl?: string,
    gwSettledChainIds?: number[],
    l2ChainRpcUrls?: Map<number, string>
  ): Promise<{ gatewayCTMAddr: string }> {
    console.log("\n=== Step 5: Setting Up Gateway ===\n");

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
    const gatewaySetup = new GatewaySetup(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);

    const gatewayCTMAddr = await gatewaySetup.designateAsGateway(
      gatewayChainId,
      gwRpcUrl,
      gwSettledChainIds,
      l2ChainRpcUrls
    );

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

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

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
