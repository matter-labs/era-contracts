import * as fs from "fs";
import * as path from "path";
import * as zlib from "zlib";
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
import { getGwSettledChainIds } from "./utils";
import { migratorFacetAbi } from "./contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS } from "./const";

export interface StartChainOptions {
  blockTime?: number;
  timestamp?: number;
  /** Map of chainId → file path. Anvil will dump state to these files on exit. */
  dumpStatePaths?: Record<number, string>;
}

export interface FullDeploymentResult {
  chains: ChainInfo;
  l1Addresses: CoreDeployedAddresses;
  ctmAddresses: CTMDeployedAddresses;
  chainAddresses: ChainAddresses[];
}

function timeIt(label: string): () => void {
  const start = Date.now();
  console.log(`⏱️  [TIMING] Starting: ${label}`);
  return () => console.log(`⏱️  [TIMING] Finished: ${label} in ${((Date.now() - start) / 1000).toFixed(1)}s`);
}

export class DeploymentRunner {
  private stateDir: string;
  private configDir: string;
  private configPath: string;

  constructor(baseDir: string = __dirname + "/..") {
    this.stateDir = path.join(baseDir, "outputs/state");
    this.configDir = path.join(baseDir, "config");
    this.configPath = path.join(this.configDir, "anvil-config.json");
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

  /** Read protocol version from configs/genesis/era/latest.json (the source of truth). */
  getProtocolVersionString(): string {
    const genesisPath = path.resolve(this.configDir, "../../../../configs/genesis/era/latest.json");
    const genesis = JSON.parse(fs.readFileSync(genesisPath, "utf-8"));
    const { major, minor, patch } = genesis.protocol_semantic_version;
    return `v${major}.${minor}.${patch}`;
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

  async step1StartChains(
    anvilManager: AnvilManager,
    startChainOptions?: StartChainOptions
  ): Promise<{ chains: ChainInfo }> {
    console.log("=== Step 1: Starting Anvil Chains ===\n");

    const config = this.getConfig();

    const { dumpStatePaths, ...baseOptions } = startChainOptions || {};
    await Promise.all(
      config.chains.map((chainConfig) =>
        anvilManager.startChain({
          chainId: chainConfig.chainId,
          port: chainConfig.port,
          isL1: chainConfig.isL1,
          ...baseOptions,
          dumpStatePath: dumpStatePaths?.[chainConfig.chainId],
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

    // Unpause deposits on all chains in parallel using explicit nonces
    console.log("\nUnpausing deposits on all chains...");
    const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    const wallet = new Wallet(privateKey, l1Provider);
    const baseNonce = await wallet.getTransactionCount();
    await Promise.all(
      chainAddresses.map(async (chain, i) => {
        const migrator = new Contract(chain.diamondProxy, migratorFacetAbi(), wallet);
        const tx = await migrator.unpauseDeposits({ gasLimit: 500_000, nonce: baseNonce + i });
        await tx.wait();
        console.log(`  Deposits unpaused on chain ${chain.chainId}`);
      })
    );

    const state = this.loadState();
    state.chainAddresses = chainAddresses;
    this.saveState(state);

    return { chainAddresses };
  }

  /**
   * Decompress a hex-gzip state file (produced by --dump-state) into native JSON
   * that --load-state CLI accepts. Writes a temp file and returns its path.
   *
   * State files from --dump-state contain a hex-encoded gzip string ("0x1f8b08...").
   * The --load-state CLI expects native JSON (SerializableState struct), so we
   * decompress on the fly. This avoids anvil version issues with anvil_loadState RPC.
   */
  private decompressStateFile(hexGzipFile: string, outputFile: string): void {
    const raw = JSON.parse(fs.readFileSync(hexGzipFile, "utf-8"));
    if (typeof raw === "string" && raw.startsWith("0x1f8b")) {
      // Hex-encoded gzip: decode hex → decompress gzip → native JSON
      const gzipBuf = Buffer.from(raw.slice(2), "hex");
      const nativeJson = zlib.gunzipSync(gzipBuf);
      fs.writeFileSync(outputFile, nativeJson);
    } else {
      // Already native JSON — copy as-is
      fs.copyFileSync(hexGzipFile, outputFile);
    }
  }

  /**
   * Start all chains from pre-generated Anvil state files.
   * Skips deployment steps 2-5 entirely — chains boot with state already loaded.
   *
   * Uses --load-state CLI for maximum compatibility across anvil versions.
   * State files from --dump-state are hex-gzip; we decompress to native JSON first.
   */
  async loadChainStates(anvilManager: AnvilManager, stateDir: string): Promise<FullDeploymentResult> {
    console.log(`\n=== Loading Pre-Generated Chain States from ${stateDir} ===\n`);

    const config = this.getConfig();

    // Load addresses saved alongside chain states
    const addressesPath = path.join(stateDir, "addresses.json");
    if (!fs.existsSync(addressesPath)) {
      throw new Error(`addresses.json not found in ${stateDir}`);
    }
    const addresses = JSON.parse(fs.readFileSync(addressesPath, "utf-8"));
    const { l1Addresses, ctmAddresses, chainAddresses, testTokens } = addresses;

    // Decompress hex-gzip state files to native JSON for --load-state CLI.
    // This is more portable than anvil_loadState RPC across anvil versions.
    const tmpDir = path.join(stateDir, ".tmp");
    fs.mkdirSync(tmpDir, { recursive: true });

    const loadStatePaths: Record<number, string> = {};
    for (const chainConfig of config.chains) {
      const stateFile = path.join(stateDir, `${chainConfig.chainId}.json`);
      if (!fs.existsSync(stateFile)) {
        throw new Error(`State file not found: ${stateFile}`);
      }
      const nativeFile = path.join(tmpDir, `${chainConfig.chainId}.json`);
      this.decompressStateFile(stateFile, nativeFile);
      loadStatePaths[chainConfig.chainId] = nativeFile;
    }

    // Start all chains with --load-state pointing to the decompressed native JSON
    await Promise.all(
      config.chains.map((chainConfig) =>
        anvilManager.startChain({
          chainId: chainConfig.chainId,
          port: chainConfig.port,
          isL1: chainConfig.isL1,
          loadStatePath: loadStatePaths[chainConfig.chainId],
        })
      )
    );

    // Clean up temp files
    for (const tmpFile of Object.values(loadStatePaths)) {
      fs.unlinkSync(tmpFile);
    }
    fs.rmdirSync(tmpDir);

    const l1Chain = anvilManager.getL1Chain();
    const l2Chains = anvilManager.getL2Chains();

    const chainInfo: ChainInfo = {
      l1: l1Chain || null,
      l2: l2Chains,
      config: config.chains,
    };

    // Populate deployment state so downstream tools (TBM, tests) work
    const state = this.loadState();
    state.chains = chainInfo;
    state.l1Addresses = l1Addresses;
    state.ctmAddresses = ctmAddresses;
    state.chainAddresses = chainAddresses;
    if (testTokens) {
      state.testTokens = testTokens;
    }
    this.saveState(state);

    console.log(`  L1: chain ${l1Chain?.chainId} at ${l1Chain?.rpcUrl}`);
    for (const l2 of l2Chains) {
      console.log(`  L2: chain ${l2.chainId} at ${l2.rpcUrl}`);
    }
    console.log("\n=== Chain States Loaded ===\n");

    return { chains: chainInfo, l1Addresses, ctmAddresses, chainAddresses };
  }

  /** Resolve the chain-states directory for the current protocol version. */
  getChainStatesDir(): string {
    const version = this.getProtocolVersionString();
    return path.resolve(this.configDir, "..", "chain-states", version);
  }

  /** Check whether pre-generated chain states exist for the current protocol version. */
  hasChainStates(): boolean {
    const stateDir = this.getChainStatesDir();
    return fs.existsSync(path.join(stateDir, "addresses.json"));
  }

  /**
   * Build dumpStatePaths map for all chains in the config.
   * Pass the result as StartChainOptions.dumpStatePaths so Anvil
   * will dump state to these files on exit (via --dump-state flag).
   */
  buildDumpStatePaths(outputDir: string): Record<number, string> {
    const config = this.getConfig();
    fs.mkdirSync(outputDir, { recursive: true });
    const paths: Record<number, string> = {};
    for (const chainConfig of config.chains) {
      paths[chainConfig.chainId] = path.join(outputDir, `${chainConfig.chainId}.json`);
    }
    return paths;
  }

  /**
   * Stop all chains to trigger --dump-state file writes.
   * Chains must have been started with dumpStatePaths in StartChainOptions.
   */
  async dumpAllStates(anvilManager: AnvilManager, outputDir: string): Promise<void> {
    console.log("\n=== Dumping Chain States (stopping Anvil to trigger --dump-state) ===\n");
    await anvilManager.stopAll();

    // Verify all state files were written
    const config = this.getConfig();
    for (const chainConfig of config.chains) {
      const statePath = path.join(outputDir, `${chainConfig.chainId}.json`);
      if (!fs.existsSync(statePath)) {
        throw new Error(`State file not written: ${statePath}`);
      }
      // Strip transactions and historical_states to reduce file size.
      // --load-state needs block, accounts, best_block_number, and blocks (for block hash lookup).
      const raw = JSON.parse(fs.readFileSync(statePath, "utf-8"));
      delete raw.transactions;
      delete raw.historical_states;
      fs.writeFileSync(statePath, JSON.stringify(raw, null, 2));

      const size = fs.statSync(statePath).size;
      console.log(`  Chain ${chainConfig.chainId} state saved (${(size / 1024).toFixed(0)} KB)`);
    }
  }

  async runFullDeployment(
    anvilManager: AnvilManager,
    startChainOptions?: StartChainOptions
  ): Promise<FullDeploymentResult> {
    const config = this.getConfig();

    // Step 1: Start all chains
    const { chains } = await this.step1StartChains(anvilManager, startChainOptions);
    if (!chains.l1) {
      throw new Error("L1 chain not found");
    }

    // Step 2: Deploy L1 contracts
    const { l1Addresses, ctmAddresses } = await this.step2DeployL1(chains.l1.rpcUrl);

    // Step 3+4: Register & initialize all L2 chains
    const { chainAddresses } = await this.step3And4RegisterAndInitChains(
      chains.l1.rpcUrl,
      chains.l2,
      chains.config,
      l1Addresses,
      ctmAddresses
    );

    // Step 5: Setup gateway if configured
    const gatewayConfig = config.chains.find((c) => c.isGateway);
    if (gatewayConfig) {
      const gwChain = chains.l2.find((c) => c.chainId === gatewayConfig.chainId);
      const l2ChainRpcUrls = new Map<number, string>();
      for (const l2Chain of chains.l2) {
        l2ChainRpcUrls.set(l2Chain.chainId, l2Chain.rpcUrl);
      }
      const gwSettledChainIds = getGwSettledChainIds(config.chains);
      await this.step5SetupGateway(
        chains.l1.rpcUrl,
        gatewayConfig.chainId,
        l1Addresses,
        ctmAddresses,
        gwChain?.rpcUrl,
        gwSettledChainIds,
        l2ChainRpcUrls
      );
    }

    return { chains, l1Addresses, ctmAddresses, chainAddresses };
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

  async startDaemons(
    l1Provider: providers.JsonRpcProvider,
    l2Providers: Map<number, providers.JsonRpcProvider>,
    chainAddresses: Map<number, ChainAddresses>,
    config: AnvilConfig
  ): Promise<{ settler: BatchSettler; l1ToL2Relayer: L1ToL2Relayer; l2ToL2Relayer: L2ToL2Relayer }> {
    console.log("\n=== Starting Daemons ===\n");

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
