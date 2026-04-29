import * as fs from "fs";
import * as path from "path";
import * as zlib from "zlib";
import { Contract, ContractFactory, Wallet, ethers, providers } from "ethers";
import { createViemClient, createViemSdk } from "@matterlabs/zksync-js/viem";
import { createPublicClient, createWalletClient, http } from "viem";
import type { Address, Chain, Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
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
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS, INTEROP_CENTER_ADDR } from "./core/const";
import { getInteropTestPrivateKey, isLiveInteropMode } from "./core/accounts";
import { encodeNtvAssetId } from "./core/data-encoding";
import { deployTestTokens } from "./helpers/deploy-test-token";
import { depositERC20ToL2 } from "./helpers/l1-deposit-helper";
import { registerAndMigrateTestTokens } from "./helpers/token-balance-migration-helper";

const ZERO_ADDRESS = ethers.constants.AddressZero;
const LIVE_CHAIN_PORT_PLACEHOLDER = 0;
const LIVE_TEST_TOKEN_DECIMALS = 18;
const LIVE_CHAIN_NATIVE_CURRENCY = { name: "Ether", symbol: "ETH", decimals: 18 } as const;

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
  private zkToken?: { l1Address: string; assetId: string };

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

  isLiveMode(): boolean {
    return isLiveInteropMode();
  }

  private getRequiredEnv(name: string): string {
    const value = process.env[name]?.trim();
    if (!value) {
      throw new Error(`${name} is required when ANVIL_INTEROP_LIVE=1`);
    }
    return value;
  }

  private async resolveLiveChainId(label: string, rpcUrl: string): Promise<number> {
    const provider = new providers.JsonRpcProvider(rpcUrl);
    const network = await provider.getNetwork();
    console.log(`  ${label}: discovered chain ID ${network.chainId}`);
    return network.chainId;
  }

  private asViemPrivateKey(privateKey: string): Hex {
    if (!ethers.utils.isHexString(privateKey, 32)) {
      throw new Error("LIVE_SOURCE_PRIVATE_KEY must be a 32-byte 0x-prefixed private key");
    }
    return privateKey as Hex;
  }

  private asViemAddress(address: string, label: string): Address {
    if (!ethers.utils.isAddress(address)) {
      throw new Error(`${label} must be an EVM address, got ${address}`);
    }
    return ethers.utils.getAddress(address) as Address;
  }

  private makeLiveViemChain(chainId: number, name: string, rpcUrl: string): Chain {
    return {
      id: chainId,
      name,
      nativeCurrency: LIVE_CHAIN_NATIVE_CURRENCY,
      rpcUrls: {
        default: { http: [rpcUrl] },
      },
    };
  }

  private createLiveZksyncSdk(params: {
    privateKey: string;
    l1RpcUrl: string;
    l1ChainId: number;
    l2RpcUrl: string;
    l2ChainId: number;
    l2Name: string;
  }) {
    const account = privateKeyToAccount(this.asViemPrivateKey(params.privateKey));
    const l1Chain = this.makeLiveViemChain(params.l1ChainId, "Live Interop L1", params.l1RpcUrl);
    const l2Chain = this.makeLiveViemChain(params.l2ChainId, params.l2Name, params.l2RpcUrl);

    const l1 = createPublicClient({ chain: l1Chain, transport: http(params.l1RpcUrl) });
    const l2 = createPublicClient({ chain: l2Chain, transport: http(params.l2RpcUrl) });
    const l1Wallet = createWalletClient({ account, chain: l1Chain, transport: http(params.l1RpcUrl) });
    const l2Wallet = createWalletClient({ account, chain: l2Chain, transport: http(params.l2RpcUrl) });
    const client = createViemClient({ l1, l2, l1Wallet, l2Wallet });

    return { account, client, sdk: createViemSdk(client) };
  }

  private emptyLiveL1Addresses(params: {
    bridgehub: string;
    l1AssetRouter: string;
    l1Nullifier?: string;
    l1NativeTokenVault?: string;
  }): CoreDeployedAddresses {
    return {
      bridgehub: params.bridgehub,
      stateTransitionManager: ZERO_ADDRESS,
      validatorTimelock: ZERO_ADDRESS,
      l1SharedBridge: params.l1AssetRouter,
      l1NullifierProxy: params.l1Nullifier ?? ZERO_ADDRESS,
      l1NativeTokenVault: params.l1NativeTokenVault ?? ZERO_ADDRESS,
      l1AssetTracker: ZERO_ADDRESS,
      l1ERC20Bridge: ZERO_ADDRESS,
      governance: ZERO_ADDRESS,
      transparentProxyAdmin: ZERO_ADDRESS,
      blobVersionedHashRetriever: ZERO_ADDRESS,
      messageRoot: ZERO_ADDRESS,
      ctmDeploymentTracker: ZERO_ADDRESS,
      l1ChainAssetHandler: ZERO_ADDRESS,
      chainRegistrationSender: ZERO_ADDRESS,
    };
  }

  private async discoverLiveZkToken(
    sourceRpcUrl: string,
    sourceAddress: string
  ): Promise<{ l1Address: string; assetId: string } | undefined> {
    const provider = new providers.JsonRpcProvider(sourceRpcUrl);
    const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("IInteropCenter"), provider);
    const assetId: string = await interopCenter.ZK_TOKEN_ASSET_ID();

    if (assetId === ethers.constants.HashZero) {
      console.warn("  The ZK token has not yet been bridged to the source chain; fixed ZK fee tests will be skipped.");
      return undefined;
    }

    const zkTokenAddress: string = await interopCenter.getZKTokenAddress();
    if (ethers.utils.getAddress(zkTokenAddress) === ZERO_ADDRESS) {
      console.warn("  The ZK token has not yet been bridged to the source chain; fixed ZK fee tests will be skipped.");
      return undefined;
    }

    const zkToken = new Contract(zkTokenAddress, getAbi("TestnetERC20Token"), provider);
    const zkBalance = await zkToken.balanceOf(sourceAddress);
    if (zkBalance.isZero()) {
      console.warn("  ZK token balance is zero; fixed ZK fee tests will be skipped.");
    }

    console.log(`  Source chain ZK token assetId: ${assetId}`);
    return { l1Address: ZERO_ADDRESS, assetId };
  }

  async setupLiveState(): Promise<DeploymentState> {
    console.log("\n=== Live Interop State Setup ===\n");

    const gwRpcUrl = this.getRequiredEnv("LIVE_GW_RPC");
    const chainARpcUrl = this.getRequiredEnv("LIVE_CHAIN_A_RPC");
    const chainBRpcUrl = this.getRequiredEnv("LIVE_CHAIN_B_RPC");

    const [gwChainId, chainAId, chainBId] = await Promise.all([
      this.resolveLiveChainId("Gateway", gwRpcUrl),
      this.resolveLiveChainId("Chain A", chainARpcUrl),
      this.resolveLiveChainId("Chain B", chainBRpcUrl),
    ]);

    const l1RpcUrl = this.getRequiredEnv("LIVE_L1_RPC");
    const privateKey = getInteropTestPrivateKey();

    const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    const l1ChainId = (await l1Provider.getNetwork()).chainId;
    const sourceL1Wallet = new Wallet(privateKey, l1Provider);
    const sourceAddress = sourceL1Wallet.address;
    const liveZkToken = await this.discoverLiveZkToken(chainARpcUrl, sourceAddress);

    const chainALiveSdk = this.createLiveZksyncSdk({
      privateKey,
      l1RpcUrl,
      l1ChainId,
      l2RpcUrl: chainARpcUrl,
      l2ChainId: chainAId,
      l2Name: "Live Interop Chain A",
    });
    const liveAddresses = await chainALiveSdk.client.ensureAddresses();

    const testTokens: Record<number, string> = {};
    const testTokenAssetIds: Record<number, string> = {};

    for (const [chainId, chainRpcUrl] of [[chainAId, chainARpcUrl]] as const) {
      const l1TokenFactory = new ContractFactory(
        getAbi("TestnetERC20Token"),
        getCreationBytecode("TestnetERC20Token"),
        sourceL1Wallet
      );
      const token = await l1TokenFactory.deploy(
        process.env.LIVE_TEST_TOKEN_NAME || "Live Interop Test Token",
        process.env.LIVE_TEST_TOKEN_SYMBOL || "LIT",
        LIVE_TEST_TOKEN_DECIMALS
      );
      await token.deployed();

      const mintAmount = ethers.utils.parseUnits(
        process.env.LIVE_TEST_TOKEN_AMOUNT || "1000",
        LIVE_TEST_TOKEN_DECIMALS
      );
      const mintAmountBigInt = BigInt(mintAmount.toString());
      const mintTx = await token.mint(sourceAddress, mintAmount);
      await mintTx.wait();

      const targetLiveSdk = this.createLiveZksyncSdk({
        privateKey,
        l1RpcUrl,
        l1ChainId,
        l2RpcUrl: chainRpcUrl,
        l2ChainId: chainId,
        l2Name: `Live Interop Chain ${chainId}`,
      });
      const l1TokenAddress = this.asViemAddress(token.address, "L1 test token");
      const assetId = encodeNtvAssetId(l1ChainId, token.address);
      console.log(`  Depositing L1 test token ${token.address} to chain ${chainId}...`);
      const deposit = await targetLiveSdk.sdk.deposits.create({
        token: l1TokenAddress,
        amount: mintAmountBigInt,
        to: targetLiveSdk.account.address,
      });
      const depositReceipt = await targetLiveSdk.sdk.deposits.wait(deposit, { for: "l2" });
      if (!depositReceipt) {
        throw new Error(`Live token deposit to chain ${chainId} did not produce an L2 receipt`);
      }

      const l2Provider = new providers.JsonRpcProvider(chainRpcUrl);
      const l2TokenAddress = await targetLiveSdk.sdk.tokens.toL2Address(l1TokenAddress);
      const l2Token = new Contract(l2TokenAddress, getAbi("TestnetERC20Token"), new Wallet(privateKey, l2Provider));
      const l2Balance = await l2Token.balanceOf(sourceAddress);
      if (l2Balance.lt(mintAmount)) {
        throw new Error(
          `Live token deposit to chain ${chainId} completed but L2 balance is ${l2Balance.toString()}, expected at least ${mintAmount.toString()}`
        );
      }

      testTokens[chainId] = l2TokenAddress;
      testTokenAssetIds[chainId] = assetId;
      console.log(`  Chain ${chainId} live test token: ${l2TokenAddress}`);
      console.log(`  Chain ${chainId} live test token assetId: ${assetId}`);
    }

    const liveState: DeploymentState = {
      chains: {
        l1: null,
        l2: [
          { chainId: gwChainId, rpcUrl: gwRpcUrl, port: LIVE_CHAIN_PORT_PLACEHOLDER },
          { chainId: chainAId, rpcUrl: chainARpcUrl, port: LIVE_CHAIN_PORT_PLACEHOLDER },
          { chainId: chainBId, rpcUrl: chainBRpcUrl, port: LIVE_CHAIN_PORT_PLACEHOLDER },
        ],
        config: [
          { chainId: gwChainId, port: LIVE_CHAIN_PORT_PLACEHOLDER, role: "gateway", settlement: "l1" },
          { chainId: chainAId, port: LIVE_CHAIN_PORT_PLACEHOLDER, role: "gwSettled", settlement: "gateway" },
          { chainId: chainBId, port: LIVE_CHAIN_PORT_PLACEHOLDER, role: "gwSettled", settlement: "gateway" },
        ],
      },
      l1Addresses: this.emptyLiveL1Addresses({
        bridgehub: liveAddresses.bridgehub,
        l1AssetRouter: liveAddresses.l1AssetRouter,
        l1Nullifier: liveAddresses.l1Nullifier,
        l1NativeTokenVault: liveAddresses.l1NativeTokenVault,
      }),
      ctmAddresses: {
        chainTypeManager: ZERO_ADDRESS,
        chainAdmin: ZERO_ADDRESS,
        diamondProxy: ZERO_ADDRESS,
        adminFacet: ZERO_ADDRESS,
        gettersFacet: ZERO_ADDRESS,
        mailboxFacet: ZERO_ADDRESS,
        executorFacet: ZERO_ADDRESS,
        verifier: ZERO_ADDRESS,
        validiumL1DAValidator: ZERO_ADDRESS,
        rollupL1DAValidator: ZERO_ADDRESS,
      },
      chainAddresses: [],
      testTokens,
      testTokenAssetIds,
    };
    if (liveZkToken) {
      liveState.zkToken = liveZkToken;
    }

    this.saveState(liveState);
    console.log("\n=== Live Interop State Saved ===\n");
    return liveState;
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

  private async deployL1ZkToken(l1RpcUrl: string): Promise<{ l1Address: string; assetId: string }> {
    console.log("\nDeploying L1 ZK token for fixed-fee interop coverage...");

    const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, new providers.JsonRpcProvider(l1RpcUrl));
    const factory = new ContractFactory(getAbi("TestnetERC20Token"), getCreationBytecode("TestnetERC20Token"), wallet);
    const token = await factory.deploy("ZK Token", "ZK", 18);
    await token.deployed();

    const mintAmount = ethers.utils.parseUnits("1000000", 18);
    const mintTx = await token.mint(wallet.address, mintAmount);
    await mintTx.wait();

    this.zkToken = {
      l1Address: token.address,
      assetId: encodeNtvAssetId((await wallet.getChainId()) as number, token.address),
    };

    const state = this.loadState();
    state.zkToken = this.zkToken;
    this.saveState(state);

    console.log(`  L1 ZK token deployed at ${this.zkToken.l1Address}`);
    console.log(`  L1 ZK token assetId: ${this.zkToken.assetId}`);

    return this.zkToken;
  }

  private async seedWrappedZkOnEthChains(state: DeploymentState): Promise<void> {
    if (!state.chains?.l1 || !state.chains.l2 || !state.l1Addresses || !state.zkToken) {
      throw new Error("Deployment state incomplete for wrapped ZK seeding");
    }

    const gatewayChain = state.chains.l2.find((chain) =>
      state.chains!.config.some((cfg) => cfg.chainId === chain.chainId && cfg.role === "gateway")
    );
    const targetConfigs = state.chains.config.filter(
      (chainConfig) =>
        chainConfig.role !== "l1" && (!chainConfig.baseToken || chainConfig.baseToken === ETH_TOKEN_ADDRESS)
    );
    const amount = ethers.utils.parseUnits("1000", 18);

    console.log("\nSeeding wrapped ZK balances on ETH-base-token L2 chains...");

    for (const chainConfig of targetConfigs) {
      const l2Chain = state.chains.l2.find((chain) => chain.chainId === chainConfig.chainId);
      if (!l2Chain) {
        throw new Error(`Missing L2 chain info for chain ${chainConfig.chainId}`);
      }

      await depositERC20ToL2({
        l1RpcUrl: state.chains.l1.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: chainConfig.chainId,
        l1Addresses: state.l1Addresses,
        tokenAddress: state.zkToken.l1Address,
        amount,
        gwRpcUrl: chainConfig.role === "gwSettled" ? gatewayChain?.rpcUrl : undefined,
      });
    }
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

    const zkToken = await this.deployL1ZkToken(l1RpcUrl);

    done = timeIt("deployCTM (forge script)");
    const ctmAddresses = await deployer.deployCTM(l1Addresses.bridgehub, zkToken.assetId);
    done();
    console.log("\nCTM Addresses:");
    console.log(`  ChainTypeManager: ${ctmAddresses.chainTypeManager}`);

    done = timeIt("registerCTM (forge script)");
    await deployer.registerCTM(l1Addresses.bridgehub, ctmAddresses.chainTypeManager);
    done();

    const state = this.loadState();
    state.l1Addresses = l1Addresses;
    state.ctmAddresses = ctmAddresses;
    state.zkToken = zkToken;
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
    const { l1Addresses, ctmAddresses, chainAddresses, testTokens, customBaseTokens, zkToken } = addresses;

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
    if (zkToken) {
      state.zkToken = zkToken;
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

    const stateAfterTbm = this.loadState();
    await this.seedWrappedZkOnEthChains(stateAfterTbm);

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
