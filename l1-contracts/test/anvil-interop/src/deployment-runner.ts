import * as fs from "fs";
import * as path from "path";
import * as zlib from "zlib";
import { Contract, ContractFactory, Wallet, providers } from "ethers";
import type { AnvilManager } from "./daemons/anvil-manager";
import { ForgeDeployer } from "./deployers/deployer";
import { ChainRegistry } from "./deployers/chain-registry";
import { GatewaySetup } from "./deployers/gateway-setup";
import type {
  AnvilConfig,
  AnvilChainConfig,
  ChainAddresses,
  ChainInfo,
  CoreDeployedAddresses,
  CTMDeployedAddresses,
  DeploymentState,
  L2ChainInfo,
  PriorityRequestData,
} from "./core/types";
import { getChainIdsByRole, timeIt } from "./core/utils";
import { getAbi, getCreationBytecode } from "./core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS } from "./core/const";
import { deployTestTokens } from "./helpers/deploy-test-token";
import { registerAndMigrateTestTokens } from "./helpers/token-balance-migration-helper";

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

export class DeploymentRunner {
  private stateDir: string;
  private configDir: string;
  private configPath: string;
  /** Maps chainId → deployed L1 base token address for chains with custom base tokens. */
  private customBaseTokens: Map<number, string> = new Map();

  constructor(baseDir: string = __dirname + "/..") {
    const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";
    this.stateDir = path.join(baseDir, `outputs/state${runSuffix}`);
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

  /** Clear cached deployment state so a fresh run doesn't see stale data. */
  clearState(): void {
    this.saveState({});
  }

  private toChainConfigMap(chainConfigs: AnvilConfig["chains"]): Map<number, AnvilConfig["chains"][number]> {
    return new Map(chainConfigs.map((chainConfig) => [chainConfig.chainId, chainConfig]));
  }

  private toRpcUrlMap(l2Chains: L2ChainInfo[]): Map<number, string> {
    return new Map(l2Chains.map((chain) => [chain.chainId, chain.rpcUrl]));
  }

  private getChainConfigOrThrow(
    chainConfigsById: Map<number, AnvilConfig["chains"][number]>,
    chainId: number
  ): AnvilChainConfig {
    const chainConfig = chainConfigsById.get(chainId);
    if (!chainConfig) {
      throw new Error(`Chain config not found for chain ${chainId}`);
    }
    return chainConfig;
  }

  private computeInteropChainIds(chainId: number, chainConfigs: AnvilChainConfig[]): number[] {
    const l2Chains = chainConfigs.filter((chainConfig) => chainConfig.role !== "l1");
    const thisChain = l2Chains.find((chainConfig) => chainConfig.chainId === chainId);
    if (!thisChain || thisChain.settlement === "l1" || !thisChain.settlement || thisChain.role !== "gwSettled") {
      return [];
    }

    return l2Chains
      .filter((chainConfig) => chainConfig.chainId !== chainId)
      .filter((chainConfig) => chainConfig.role === "gwSettled")
      .filter((chainConfig) => chainConfig.settlement === thisChain.settlement)
      .map((chainConfig) => chainConfig.chainId);
  }

  private buildInteropChainMap(chainConfigs: AnvilConfig["chains"]): Map<number, number[]> {
    const l2ChainConfigs = chainConfigs.filter((chainConfig) => chainConfig.role !== "l1");
    return new Map(
      l2ChainConfigs.map((chainConfig) => [
        chainConfig.chainId,
        this.computeInteropChainIds(chainConfig.chainId, chainConfigs),
      ])
    );
  }

  private buildRegistrationConfigs(
    l2Chains: L2ChainInfo[],
    chainConfigsById: Map<number, AnvilConfig["chains"][number]>
  ) {
    return l2Chains.map((l2Chain) => {
      const chainConfig = this.getChainConfigOrThrow(chainConfigsById, l2Chain.chainId);
      const baseToken = this.customBaseTokens.get(chainConfig.chainId) ?? ETH_TOKEN_ADDRESS;
      return {
        chainId: chainConfig.chainId,
        rpcUrl: l2Chain.rpcUrl,
        baseToken,
        validiumMode: false,
      };
    });
  }

  /**
   * Deploy custom ERC20 base tokens on L1 for chains that specify `baseToken: "custom"`.
   * Must be called before chain registration, since the Forge registration script validates
   * that the base token address is a deployed contract.
   */
  private async deployCustomBaseTokens(l1RpcUrl: string, chainConfigs: AnvilChainConfig[]): Promise<void> {
    const chainsNeedingCustomToken = chainConfigs.filter((c) => c.baseToken === "custom");
    if (chainsNeedingCustomToken.length === 0) return;

    console.log(`\nDeploying custom base tokens for ${chainsNeedingCustomToken.length} chain(s)...`);

    const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, new providers.JsonRpcProvider(l1RpcUrl));
    const abi = getAbi("TestnetERC20Token");
    const bytecode = getCreationBytecode("TestnetERC20Token");

    for (const chainConfig of chainsNeedingCustomToken) {
      const factory = new ContractFactory(abi, bytecode, wallet);
      const token = await factory.deploy(`BaseToken${chainConfig.chainId}`, `BT${chainConfig.chainId}`, 18);
      await token.deployed();
      this.customBaseTokens.set(chainConfig.chainId, token.address);
      console.log(`  Chain ${chainConfig.chainId} base token deployed at ${token.address}`);
    }

    // Persist to state so tests can look up custom base token addresses
    const state = this.loadState();
    state.customBaseTokens = Object.fromEntries(this.customBaseTokens);
    this.saveState(state);
  }

  private getGatewayChainOrThrow(gatewayChainId: number, l2Chains: L2ChainInfo[]): L2ChainInfo {
    const gwChain = l2Chains.find((chain) => chain.chainId === gatewayChainId);
    if (!gwChain) {
      throw new Error(`Gateway chain ${gatewayChainId} not found in started L2 chains`);
    }
    return gwChain;
  }

  private async initializeL2Chain(
    registry: ChainRegistry,
    chain: ChainAddresses,
    l2RpcUrlsByChainId: Map<number, string>,
    genesisPriorityTxs: Map<number, PriorityRequestData>
  ): Promise<void> {
    const rpcUrl = l2RpcUrlsByChainId.get(chain.chainId);
    if (!rpcUrl) {
      throw new Error(`L2 chain ${chain.chainId} not found`);
    }
    const genesisTx = genesisPriorityTxs.get(chain.chainId);
    if (!genesisTx) {
      throw new Error(`Genesis tx not found for chain ${chain.chainId}`);
    }
    const done = timeIt(`initializeL2 chain ${chain.chainId}`);
    await registry.initializeL2SystemContracts(chain.chainId, chain.diamondProxy, rpcUrl, genesisTx);
    done();
    console.log(`  Chain ${chain.chainId} system contracts initialized`);
  }

  private async registerInteropChainsForL2Chain(
    registry: ChainRegistry,
    chain: ChainAddresses,
    l2RpcUrlsByChainId: Map<number, string>,
    interopChainIdsByChainId: Map<number, number[]>
  ): Promise<void> {
    const rpcUrl = l2RpcUrlsByChainId.get(chain.chainId);
    if (!rpcUrl) {
      throw new Error(`L2 chain ${chain.chainId} not found`);
    }
    const interopChainIds = interopChainIdsByChainId.get(chain.chainId);
    if (!interopChainIds) {
      throw new Error(`Interop chain plan not found for chain ${chain.chainId}`);
    }

    const done = timeIt(`registerInterop chain ${chain.chainId}`);
    await registry.registerInteropChainsOnL2(chain.chainId, chain.diamondProxy, rpcUrl, interopChainIds);
    done();
    console.log(`  Chain ${chain.chainId} interop registrations completed`);
  }

  private async unpauseChainDeposits(
    wallet: Wallet,
    chain: ChainAddresses,
    nonce: number,
    migratorAbi: ReturnType<typeof getAbi>
  ): Promise<void> {
    const migrator = new Contract(chain.diamondProxy, migratorAbi, wallet);
    const tx = await migrator.unpauseDeposits({ gasLimit: 500_000, nonce });
    await tx.wait();
    console.log(`  Deposits unpaused on chain ${chain.chainId}`);
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
          role: chainConfig.role,
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
    l2Chains: L2ChainInfo[],
    chainConfigs: AnvilConfig["chains"],
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ): Promise<{
    chainAddresses: ChainAddresses[];
  }> {
    console.log("\n=== Step 3+4: Register & Initialize L2 Chains ===\n");

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);
    const chainConfigsById = this.toChainConfigMap(chainConfigs);
    const l2RpcUrlsByChainId = this.toRpcUrlMap(l2Chains);

    // Batch-register all chains in a single forge call (avoids nonce conflicts)
    const configs = this.buildRegistrationConfigs(l2Chains, chainConfigsById);

    const regDone = timeIt(`registerChains batch [${configs.map((c) => c.chainId).join(",")}]`);
    const { chainAddresses, genesisPriorityTxs } = await registry.registerChainBatch(configs);
    regDone();

    for (const addr of chainAddresses) {
      console.log(`  Chain ${addr.chainId} registered at: ${addr.diamondProxy}`);
    }

    // Initialize all L2 chains in parallel (each goes to a separate Anvil instance)
    console.log("\nInitializing L2 system contracts (in parallel)...\n");
    await Promise.all(
      chainAddresses.map((chain) => this.initializeL2Chain(registry, chain, l2RpcUrlsByChainId, genesisPriorityTxs))
    );

    // Unpause deposits on all chains in parallel using explicit nonces
    console.log("\nUnpausing deposits on all chains...");
    const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    const wallet = new Wallet(privateKey, l1Provider);
    const migratorAbi = getAbi("MigratorFacet");
    const baseNonce = await wallet.getTransactionCount();
    await Promise.all(
      chainAddresses.map((chain, i) => this.unpauseChainDeposits(wallet, chain, baseNonce + i, migratorAbi))
    );

    const state = this.loadState();
    state.chainAddresses = chainAddresses;
    this.saveState(state);

    return { chainAddresses };
  }

  async step6RegisterInteropChains(
    l1RpcUrl: string,
    l2Chains: L2ChainInfo[],
    chainConfigs: AnvilConfig["chains"],
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses,
    chainAddresses: ChainAddresses[]
  ): Promise<void> {
    console.log("\n=== Step 6: Register Interop Chains ===\n");

    const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
    const registry = new ChainRegistry(l1RpcUrl, privateKey, l1Addresses, ctmAddresses);
    const l2RpcUrlsByChainId = this.toRpcUrlMap(l2Chains);
    const interopChainIdsByChainId = this.buildInteropChainMap(chainConfigs);

    for (const chain of chainAddresses) {
      await this.registerInteropChainsForL2Chain(registry, chain, l2RpcUrlsByChainId, interopChainIdsByChainId);
    }
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
    const { l1Addresses, ctmAddresses, chainAddresses, testTokens, customBaseTokens } = addresses;

    // Decompress hex-gzip state files to native JSON for --load-state CLI.
    // This is more portable than anvil_loadState RPC across anvil versions.
    const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";
    const tmpDir = path.join(stateDir, `.tmp${runSuffix}`);
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
          role: chainConfig.role,
          loadStatePath: loadStatePaths[chainConfig.chainId],
        })
      )
    );

    // Clean up temp files
    for (const tmpFile of Object.values(loadStatePaths)) {
      fs.unlinkSync(tmpFile);
    }
    fs.rmSync(tmpDir, { recursive: true });

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
    if (customBaseTokens) {
      state.customBaseTokens = customBaseTokens;
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

    // Deploy custom ERC20 base tokens on L1 (before chain registration needs them)
    await this.deployCustomBaseTokens(chains.l1.rpcUrl, config.chains);

    // Step 3+4: Register & initialize all L2 chains
    const { chainAddresses } = await this.step3And4RegisterAndInitChains(
      chains.l1.rpcUrl,
      chains.l2,
      chains.config,
      l1Addresses,
      ctmAddresses
    );

    // Step 5: Setup gateway if configured
    const gatewayConfig = config.chains.find((c) => c.role === "gateway");
    if (gatewayConfig) {
      const gwChain = this.getGatewayChainOrThrow(gatewayConfig.chainId, chains.l2);
      const l2ChainRpcUrls = this.toRpcUrlMap(chains.l2);
      const gwSettledChainIds = getChainIdsByRole(config.chains, "gwSettled");
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

    await this.step6RegisterInteropChains(
      chains.l1.rpcUrl,
      chains.l2,
      chains.config,
      l1Addresses,
      ctmAddresses,
      chainAddresses
    );

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

    const gatewaySetup = new GatewaySetup(l1RpcUrl, l1Addresses, ctmAddresses);

    const gatewayCTMAddr = await gatewaySetup.designateAsGateway(
      gatewayChainId,
      gwRpcUrl,
      gwSettledChainIds,
      l2ChainRpcUrls
    );

    console.log(`  Gateway CTM: ${gatewayCTMAddr}`);

    return { gatewayCTMAddr };
  }

  /**
   * Run full deployment and deploy test tokens.
   *
   * This is the shared setup flow used by both `setup-and-dump-state.ts` and
   * `run-hardhat-interop-test.ts`.  It encapsulates:
   *   1. Run full deployment (start chains + deploy contracts)
   *   2. Deploy test tokens (if not already present in state)
   *
   * Callers can customise behaviour via `DeployAndSetupOptions`.
   */
  async deployAndSetup(anvilManager: AnvilManager, options?: DeployAndSetupOptions): Promise<FullDeploymentResult> {
    const startChainOptions: StartChainOptions | undefined = options?.startChainOptions;

    const result = await this.runFullDeployment(anvilManager, startChainOptions);

    // Deploy test tokens unless the caller opted out.
    if (options?.deployTestTokens !== false) {
      const state = this.loadState();
      const hasTestTokens = state.testTokens && Object.keys(state.testTokens).length > 0;
      if (!hasTestTokens) {
        await deployTestTokens();
      }
    }

    return result;
  }

  /**
   * Full setup: deploy + test tokens + Token Balance Migration (TBM).
   *
   * Used by both `setup-and-dump-state.ts` and `run-hardhat-interop-test.ts` (fresh deploy path).
   * TBM registers and migrates test tokens on GW-settled chains so that
   * assetMigrationNumber matches migrationNumber (required for interop transfers).
   */
  async deployAndSetupWithTBM(
    anvilManager: AnvilManager,
    options?: DeployAndSetupOptions
  ): Promise<FullDeploymentResult> {
    const result = await this.deployAndSetup(anvilManager, options);

    const config = this.getConfig();
    const gwSettledChainIds = getChainIdsByRole(config.chains, "gwSettled");
    const gatewayConfig = config.chains.find((c) => c.role === "gateway");

    if (gwSettledChainIds.length > 0 && gatewayConfig) {
      const state = this.loadState();
      if (state.testTokens && Object.keys(state.testTokens).length > 0) {
        const gwChain = state.chains!.l2.find((c) => c.chainId === gatewayConfig.chainId)!;
        const gwDiamondProxy = state.chainAddresses!.find((c) => c.chainId === gatewayConfig.chainId)!.diamondProxy;
        const l2ChainRpcUrls = new Map(state.chains!.l2.map((c) => [c.chainId, c.rpcUrl]));

        await registerAndMigrateTestTokens({
          gwSettledChainIds,
          l2ChainRpcUrls,
          testTokens: state.testTokens,
          l1RpcUrl: state.chains!.l1!.rpcUrl,
          gwRpcUrl: gwChain.rpcUrl,
          l1AssetTrackerAddr: result.l1Addresses.l1AssetTracker,
          gwDiamondProxyAddr: gwDiamondProxy,
          chainAddresses: state.chainAddresses!,
          logger: (line) => console.log(line),
        });
      }
    }

    return result;
  }
}

export interface DeployAndSetupOptions {
  /** Options forwarded to `runFullDeployment` → `step1StartChains`. */
  startChainOptions?: StartChainOptions;
  /**
   * Whether to deploy test ERC-20 tokens after deployment.
   * Defaults to `true`.  Set to `false` to skip token deployment.
   */
  deployTestTokens?: boolean;
}
