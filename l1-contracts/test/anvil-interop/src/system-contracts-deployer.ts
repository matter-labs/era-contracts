import * as fs from "fs";
import * as path from "path";
import { providers, Contract, Wallet, utils } from "ethers";
import { impersonateAndRun } from "./utils";
import { encodeNtvAssetId } from "./data-encoding";
import {
  l2BridgehubAbi,
  interopCenterAbi,
  interopHandlerAbi,
  l2AssetRouterAbi,
  l2AssetTrackerAbi,
  l2NativeTokenVaultAbi,
  l2NativeTokenVaultDevAbi,
} from "./contracts";
import {
  ETH_TOKEN_ADDRESS,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  SERVICE_TX_SENDER_ADDR,
  SYSTEM_CONTEXT_ADDR,
  LEGACY_SHARED_BRIDGE_PLACEHOLDER,
} from "./const";

/**
 * SystemContractsDeployer
 *
 * Systematically deploys L2 system contracts needed for InteropCenter
 * This is a helper class that deploys contracts in the correct order
 * and handles initialization properly.
 */
export class SystemContractsDeployer {
  private l2Provider: providers.JsonRpcProvider;
  private l2Wallet: Wallet;
  private contractsRoot: string;

  constructor(l2RpcUrl: string, privateKey: string) {
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    this.l2Wallet = new Wallet(privateKey, this.l2Provider);
    this.contractsRoot = path.resolve(__dirname, "../../../..");
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private isOne(value: any): boolean {
    return value?.toString?.() === "1";
  }

  /**
   * Deploy a system contract at a specific address using anvil_setCode
   */
  private async deploySystemContract(address: string, contractPath: string, name: string): Promise<void> {
    const existingCode = await this.l2Provider.getCode(address);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ ${name} already deployed at ${address}`);
      return;
    }

    console.log(`   Deploying ${name} at ${address}...`);

    const fullPath = path.join(this.contractsRoot, contractPath);
    const artifact = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
    const bytecode = artifact.deployedBytecode?.object || artifact.bytecode?.object;

    if (!bytecode || bytecode === "0x") {
      throw new Error(`No bytecode found for ${name} at ${contractPath}`);
    }

    await this.l2Provider.send("anvil_setCode", [address, bytecode]);
    console.log(`   ✅ ${name} deployed`);
  }

  /**
   * Initialize a contract by impersonating an account
   */
  private async initializeContract(
    contractAddress: string,
    abi: string[],
    initFunction: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: any[],
    impersonatedAccount: string,
    name: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    txOverrides?: Record<string, any>
  ): Promise<void> {
    await impersonateAndRun(this.l2Provider, impersonatedAccount, async (signer) => {
      const contract = new Contract(contractAddress, abi, this.l2Provider);
      const contractWithSigner = contract.connect(signer);

      console.log(`   Initializing ${name}...`);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const tx = await (contractWithSigner as any)[initFunction](...args, txOverrides || {});
      await tx.wait();
      console.log(`   ✅ ${name} initialized`);
    });
  }

  /**
   * Deploy all system contracts needed for InteropCenter
   */
  async deployAllSystemContracts(chainId: number): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId}...`);

    // 1. MockSystemContext at 0x800b
    await this.deploySystemContract(
      SYSTEM_CONTEXT_ADDR,
      "l1-contracts/out/MockSystemContext.sol/MockSystemContext.json",
      "MockSystemContext"
    );

    // 2. L2ToL1Messenger at 0x8008
    await this.deployL2ToL1Messenger();

    // 3. L2BaseToken at 0x800a
    await this.deployL2BaseToken();

    // 4. L2Bridgehub at 0x010002
    await this.deployL2Bridgehub(chainId);

    // 5. L2MessageVerification at 0x10009
    await this.deployL2MessageVerification();

    // 6-7. InteropCenter and InteropHandler are V31-only, skip in v29
    console.log("   ⏭️  Skipping InteropCenter (v31-only)");
    console.log("   ⏭️  Skipping L2InteropHandler (v31-only)");

    // 8. L2AssetRouter at 0x010003
    await this.deployL2AssetRouter();

    // 9. L2ChainAssetHandler at 0x1000a
    await this.deployL2ChainAssetHandler();

    // 10. L2AssetTracker is V31-only, skip in v29
    console.log("   ⏭️  Skipping L2AssetTracker (v31-only)");

    // 11. L2NativeTokenVault at 0x010004
    await this.deployL2NativeTokenVault();

    // 12. Register asset handlers for test tokens
    await this.registerAssetHandlers(chainId);

    console.log(`✅ All system contracts deployed for chain ${chainId}`);
  }

  /**
   * Deploy L2MessageVerification system contract.
   * For anvil interop we deploy the mock implementation that always verifies inclusion.
   */
  private async deployL2MessageVerification(): Promise<void> {
    await this.deploySystemContract(
      L2_MESSAGE_VERIFICATION_ADDR,
      "l1-contracts/out/MockL2MessageVerification.sol/MockL2MessageVerification.json",
      "L2MessageVerification"
    );
  }

  /**
   * Deploy L2ToL1Messenger system contract
   */
  private async deployL2ToL1Messenger(): Promise<void> {
    // Check if already deployed
    const existingCode = await this.l2Provider.getCode(L2_TO_L1_MESSENGER_ADDR);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ L2ToL1Messenger already deployed at ${L2_TO_L1_MESSENGER_ADDR}`);
      return;
    }

    console.log(`   Deploying L2ToL1Messenger at ${L2_TO_L1_MESSENGER_ADDR}...`);

    // Anvil is standard EVM, not zkSync EVM, so we MUST use the standard EVM mock
    // instead of zkout (which contains zkSync-specific bytecode that won't work in Anvil)
    console.log("   Using MockL2ToL1Messenger (standard EVM) instead of zkout (zkSync EVM)...");
    await this.deployMockL2ToL1Messenger();
  }

  /**
   * Deploy mock L2ToL1Messenger (compiled version)
   */
  private async deployMockL2ToL1Messenger(): Promise<void> {
    // Use the compiled MockL2ToL1Messenger bytecode
    const mockPath = path.join(this.contractsRoot, "l1-contracts/out/MockL2ToL1Messenger.sol/MockL2ToL1Messenger.json");

    const artifact = JSON.parse(fs.readFileSync(mockPath, "utf-8"));
    const bytecode = artifact.deployedBytecode?.object;

    if (!bytecode || bytecode === "0x") {
      throw new Error("MockL2ToL1Messenger bytecode not found - run forge build first");
    }

    await this.l2Provider.send("anvil_setCode", [L2_TO_L1_MESSENGER_ADDR, bytecode]);
    console.log("   ✅ MockL2ToL1Messenger deployed");
  }

  /**
   * Deploy L2BaseToken system contract
   */
  private async deployL2BaseToken(): Promise<void> {
    // Check if already deployed
    const existingCode = await this.l2Provider.getCode(L2_BASE_TOKEN_ADDR);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ L2BaseToken already deployed at ${L2_BASE_TOKEN_ADDR}`);
      return;
    }

    console.log(`   Deploying L2BaseToken at ${L2_BASE_TOKEN_ADDR}...`);

    // Anvil is standard EVM, not zkSync EVM, so we MUST use the minimal mock
    // instead of zkout (which contains zkSync-specific bytecode that won't work in Anvil)
    console.log("   Using minimal L2BaseToken mock (standard EVM) instead of zkout (zkSync EVM)...");
    await this.deployMinimalL2BaseToken();
  }

  /**
   * Deploy minimal mock L2BaseToken if real one not available
   */
  private async deployMinimalL2BaseToken(): Promise<void> {
    // Use the compiled MockL2BaseToken bytecode
    const mockPath = path.join(this.contractsRoot, "l1-contracts/out/MockL2BaseToken.sol/MockL2BaseToken.json");

    const artifact = JSON.parse(fs.readFileSync(mockPath, "utf-8"));
    const bytecode = artifact.deployedBytecode?.object;

    if (!bytecode || bytecode === "0x") {
      throw new Error("MockL2BaseToken bytecode not found - run forge build first");
    }

    await this.l2Provider.send("anvil_setCode", [L2_BASE_TOKEN_ADDR, bytecode]);
    console.log("   ✅ MockL2BaseToken deployed");
  }

  /**
   * Deploy and initialize L2Bridgehub
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  private async deployL2Bridgehub(_chainId: number): Promise<void> {
    const l2BridgehubAbiData = l2BridgehubAbi();

    // Check if already initialized
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbiData, this.l2Provider);
    let isInitialized = false;
    try {
      const l1ChainId = await l2Bridgehub.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ L2Bridgehub already initialized");
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_BRIDGEHUB_ADDR,
        "l1-contracts/out/Bridgehub.sol/Bridgehub.json",
        "Bridgehub (as L2Bridgehub)"
      );

      const ownerAddress = await this.l2Wallet.getAddress();
      await this.initializeContract(
        L2_BRIDGEHUB_ADDR,
        l2BridgehubAbiData,
        "initL2",
        [1, ownerAddress, 100],
        L2_COMPLEX_UPGRADER_ADDR,
        "L2Bridgehub"
      );
    }

    // Register chains
    await this.registerChainsOnBridgehub(l2Bridgehub);
  }

  /**
   * Register chains on L2Bridgehub
   */
  private async registerChainsOnBridgehub(l2Bridgehub: Contract): Promise<void> {
    const chains = [10, 11, 12];
    const abiCoder = new utils.AbiCoder();
    const ethAssetId = utils.keccak256(abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS]));

    for (const targetChainId of chains) {
      try {
        const existingAssetId = await l2Bridgehub.baseTokenAssetId(targetChainId);
        if (existingAssetId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
          console.log(`   ✅ Chain ${targetChainId} already registered on L2Bridgehub`);
          continue;
        }
      } catch {
        // Will register
      }

      console.log(`   Registering chain ${targetChainId} on L2Bridgehub...`);

      await impersonateAndRun(this.l2Provider, SERVICE_TX_SENDER_ADDR, async (signer) => {
        const l2BridgehubWithSigner = l2Bridgehub.connect(signer);

        const tx = await l2BridgehubWithSigner.registerChainForInterop(targetChainId, ethAssetId);
        await tx.wait();
      });
      console.log(`   ✅ Chain ${targetChainId} registered`);
    }
  }

  /**
   * Deploy and initialize InteropCenter
   */
  private async deployInteropCenter(): Promise<void> {
    const interopCenterAbiData = interopCenterAbi();

    const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbiData, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopCenter.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ InteropCenter already initialized");
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      // V31-only: InteropCenter not available in v29
      console.log("   ⏭️  InteropCenter deployment skipped (v31-only)");

      const ownerAddress = await this.l2Wallet.getAddress();
      await this.initializeContract(
        INTEROP_CENTER_ADDR,
        interopCenterAbiData,
        "initL2",
        [1, ownerAddress],
        L2_COMPLEX_UPGRADER_ADDR,
        "InteropCenter"
      );
    }

    // Unpause if needed
    const interopCenterWithOwner = interopCenter.connect(this.l2Wallet);
    const isPaused = await interopCenterWithOwner.paused();
    if (isPaused) {
      console.log("   Unpausing InteropCenter...");
      const tx = await interopCenterWithOwner.unpause();
      await tx.wait();
      console.log("   ✅ InteropCenter unpaused");
    } else {
      console.log("   ✅ InteropCenter already unpaused");
    }
  }

  /**
   * Deploy and initialize L2InteropHandler
   */
  private async deployL2InteropHandler(): Promise<void> {
    // V31-only: InteropHandler not available in v29
    console.log("   ⏭️  InteropHandler deployment skipped (v31-only)");

    // Initialize L2InteropHandler
    const interopHandlerAbiData = interopHandlerAbi();

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbiData, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopHandler.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ L2InteropHandler already initialized");
        isInitialized = true;
      }
    } catch {
      // Contract not deployed yet, will initialize below
    }

    if (!isInitialized) {
      await this.initializeContract(
        L2_INTEROP_HANDLER_ADDR,
        interopHandlerAbiData,
        "initL2",
        [1], // L1 chain ID = 1
        L2_COMPLEX_UPGRADER_ADDR,
        "L2InteropHandler"
      );
    }
  }

  /**
   * Deploy and initialize L2AssetRouter for token bridging
   */
  private async deployL2AssetRouter(): Promise<void> {
    const l2AssetRouterAbiData = l2AssetRouterAbi();

    const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbiData, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetRouter.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ L2AssetRouter already initialized");
        isInitialized = true;
      }
    } catch {
      // Will deploy and initialize
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_ASSET_ROUTER_ADDR,
        "l1-contracts/out/L2AssetRouter.sol/L2AssetRouter.json",
        "L2AssetRouter"
      );

      const ownerAddress = await this.l2Wallet.getAddress();
      const abiCoder = new utils.AbiCoder();
      const ethAssetId = utils.keccak256(abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS]));

      await this.initializeContract(
        L2_ASSET_ROUTER_ADDR,
        l2AssetRouterAbiData,
        "initL2",
        [
          1, // L1 chain ID
          270, // Era chain ID
          "0x0000000000000000000000000000000000000001", // L1AssetRouter (dummy)
          LEGACY_SHARED_BRIDGE_PLACEHOLDER,
          ethAssetId, // Base token asset ID
          ownerAddress,
        ],
        L2_COMPLEX_UPGRADER_ADDR,
        "L2AssetRouter"
      );
    }
  }

  /**
   * Deploy and initialize L2ChainAssetHandler at 0x1000a
   */
  private async deployL2ChainAssetHandler(): Promise<void> {
    // Check if already deployed
    let isDeployed = false;
    try {
      const code = await this.l2Provider.getCode(L2_CHAIN_ASSET_HANDLER_ADDR);
      if (code !== "0x") {
        console.log("   ✅ L2ChainAssetHandler already deployed");
        isDeployed = true;
      }
    } catch {
      // Will deploy
    }

    if (!isDeployed) {
      await this.deploySystemContract(
        L2_CHAIN_ASSET_HANDLER_ADDR,
        "l1-contracts/out/ChainAssetHandler.sol/ChainAssetHandler.json",
        "ChainAssetHandler (as L2ChainAssetHandler)"
      );

      // For now, just deploy without initialization
      // Full initialization would require bridgehub, message root, asset router addresses
      console.log("   ⚠️  L2ChainAssetHandler deployed but not initialized");
    }
  }

  /**
   * Deploy and initialize L2AssetTracker at 0x1000f
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  private async deployL2AssetTracker(_chainId: number): Promise<void> {
    const l2AssetTrackerAbiData = l2AssetTrackerAbi();

    const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAbiData, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetTracker.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ L2AssetTracker already initialized");
        isInitialized = true;
      }
    } catch {
      // Will deploy and initialize
    }

    if (!isInitialized) {
      // V31-only: L2AssetTracker not available in v29
      console.log("   ⏭️  L2AssetTracker deployment skipped (v31-only)");

      // Initialize via L2ComplexUpgrader
      const abiCoder = new utils.AbiCoder();

      // Calculate ETH asset ID (utils.keccak256(abi.encode(1, 0x0000...0001)))
      const ethAssetId = utils.keccak256(abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS]));

      await this.initializeContract(
        L2_ASSET_TRACKER_ADDR,
        l2AssetTrackerAbiData,
        "setAddresses",
        [
          1, // L1 chain ID
          ethAssetId, // Base token asset ID
        ],
        L2_COMPLEX_UPGRADER_ADDR,
        "L2AssetTracker"
      );
    }
  }

  /**
   * Deploy L2NativeTokenVault for token management
   */
  private async deployL2NativeTokenVault(): Promise<void> {
    const l2NativeTokenVaultAbiData = l2NativeTokenVaultAbi();
    const l2NativeTokenVaultDevAbiData = l2NativeTokenVaultDevAbi();

    const l2NativeTokenVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbiData, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2NativeTokenVault.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log("   ✅ L2NativeTokenVault already initialized");
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        "l1-contracts/out/L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json",
        "L2NativeTokenVaultDev"
      );

      const l2NativeTokenVaultDev = new Contract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        l2NativeTokenVaultDevAbiData,
        this.l2Wallet
      );

      const ownerAddress = await this.l2Wallet.getAddress();
      const abiCoder = new utils.AbiCoder();
      const ethAssetId = utils.keccak256(abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS]));

      const l2TokenProxyBytecodeHash = utils.keccak256(utils.toUtf8Bytes("anvil-l2-token-proxy"));
      const legacyBridgeAddress = LEGACY_SHARED_BRIDGE_PLACEHOLDER;
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      const baseTokenBridgingData: [string, number, string] = [ethAssetId, 1, ETH_TOKEN_ADDRESS];
      const baseTokenMetadata: [string, string, number] = ["Ether", "ETH", 18];
      const initializationGasLimit = 30_000_000;

      // Ensure a non-empty beacon address exists before initL2 so initialization remains single-path.
      let bridgedTokenBeacon = await l2NativeTokenVaultDev.bridgedTokenBeacon();
      if (bridgedTokenBeacon === zeroAddress) {
        const deployBridgedTokenTx = await l2NativeTokenVaultDev.deployBridgedStandardERC20(ownerAddress);
        await deployBridgedTokenTx.wait();
        bridgedTokenBeacon = await l2NativeTokenVaultDev.bridgedTokenBeacon();
      }
      if (bridgedTokenBeacon === zeroAddress) {
        throw new Error("Failed to set bridged token beacon before initL2");
      }

      await this.initializeContract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        l2NativeTokenVaultAbiData,
        "initL2",
        [
          1, // L1 chain ID
          ownerAddress,
          l2TokenProxyBytecodeHash,
          legacyBridgeAddress,
          bridgedTokenBeacon,
          zeroAddress, // no WETH token in anvil setup
          baseTokenBridgingData,
          baseTokenMetadata,
        ],
        L2_COMPLEX_UPGRADER_ADDR,
        "L2NativeTokenVault",
        { gasLimit: initializationGasLimit }
      );

      console.log("   ✅ L2NativeTokenVault deployed and initialized (dev bridged token beacon configured)");
    }
  }

  /**
   * Register asset handlers for tokens
   */
  private async registerAssetHandlers(chainId: number): Promise<void> {
    // Get test token addresses from state
    // Use process.cwd() which gives the directory from where the script was run
    // This is more reliable than __dirname with ts-node
    const stateFile = path.join(process.cwd(), "outputs/state/chains.json");

    console.log(`   Checking for test tokens in: ${stateFile}`);
    if (!fs.existsSync(stateFile)) {
      console.log("   ⚠️  State file not found, skipping asset handler registration");
      return;
    }

    const state = JSON.parse(fs.readFileSync(stateFile, "utf-8"));
    if (!state.testTokens || !state.testTokens[chainId]) {
      console.log(`   ⚠️  No test token for chain ${chainId}, skipping asset handler registration`);
      return;
    }

    const tokenAddress = state.testTokens[chainId];
    const assetId = encodeNtvAssetId(chainId, tokenAddress);

    console.log(`   Registering asset handler for token ${tokenAddress}...`);
    console.log(`   Asset ID: ${assetId}`);

    const l2AssetRouterAbiData2 = l2AssetRouterAbi();

    const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbiData2, this.l2Provider);

    // Check if asset handler already registered
    const currentHandler = await l2AssetRouter.assetHandlerAddress(assetId);
    if (currentHandler === "0x0000000000000000000000000000000000000000") {
      // Register L2NativeTokenVault as the handler
      // We need to impersonate L2NativeTokenVault to call setLegacyTokenAssetHandler
      await impersonateAndRun(this.l2Provider, L2_NATIVE_TOKEN_VAULT_ADDR, async (signer) => {
        const l2AssetRouterWithSigner = l2AssetRouter.connect(signer);

        const tx = await l2AssetRouterWithSigner.setLegacyTokenAssetHandler(assetId);
        await tx.wait();
      });

      console.log(`   ✅ Asset handler registered: ${L2_NATIVE_TOKEN_VAULT_ADDR}`);
    } else {
      console.log(`   ✅ Asset handler already registered: ${currentHandler}`);
    }

    // Now register the token in L2NativeTokenVault
    const l2NativeTokenVaultAbiData2 = l2NativeTokenVaultAbi();

    const l2NativeTokenVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbiData2, this.l2Provider);

    // Check if token is already registered
    const registeredAssetId = await l2NativeTokenVault.assetId(tokenAddress);
    if (registeredAssetId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
      console.log("   ✅ Token already registered in L2NativeTokenVault");
      return;
    }

    // Check if token contract exists on this L2 chain
    const tokenCode = await this.l2Provider.getCode(tokenAddress);
    if (tokenCode === "0x" || tokenCode === "0x0") {
      console.log(`   ⚠️  Token ${tokenAddress} not deployed on chain ${chainId}, skipping registration`);
      console.log("      (Deploy test tokens with 'yarn deploy:test-token' if needed)");
      return;
    }

    // Call registerToken()
    console.log(`   Calling registerToken(${tokenAddress})...`);
    try {
      const l2NativeTokenVaultWithWallet = l2NativeTokenVault.connect(this.l2Wallet);
      const registerTx = await l2NativeTokenVaultWithWallet.registerToken(tokenAddress);
      await registerTx.wait();

      console.log("   ✅ Token registered in L2NativeTokenVault");
      console.log(`      assetId: ${assetId}`);
    } catch (error: unknown) {
      console.error(`   ❌ registerToken failed: ${(error as Error).message}`);
      throw error;
    }
  }
}
