import * as fs from "fs";
import * as path from "path";
import { providers, Contract, Wallet, utils } from "ethers";
import { loadAbiFromOut } from "./utils";
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

  private isOne(value: any): boolean {
    return value?.toString?.() === "1";
  }

  /**
   * Deploy a system contract at a specific address using anvil_setCode
   */
  private async deploySystemContract(
    address: string,
    contractPath: string,
    name: string
  ): Promise<void> {
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
    args: any[],
    impersonatedAccount: string,
    name: string
  ): Promise<void> {
    await this.l2Provider.send("anvil_impersonateAccount", [impersonatedAccount]);
    await this.l2Provider.send("anvil_setBalance", [impersonatedAccount, "0x56BC75E2D63100000"]);

    const contract = new Contract(contractAddress, abi, this.l2Provider);
    const signer = await this.l2Provider.getSigner(impersonatedAccount);
    const contractWithSigner = contract.connect(signer);

    console.log(`   Initializing ${name}...`);
    const tx = await (contractWithSigner as any)[initFunction](...args);
    await tx.wait();

    await this.l2Provider.send("anvil_stopImpersonatingAccount", [impersonatedAccount]);
    console.log(`   ✅ ${name} initialized`);
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

    // 6. InteropCenter at 0x1000d
    await this.deployInteropCenter();

    // 7. L2InteropHandler at 0x1000e
    await this.deployL2InteropHandler();

    // 8. L2AssetRouter at 0x010003
    await this.deployL2AssetRouter();

    // 9. L2ChainAssetHandler at 0x1000a
    await this.deployL2ChainAssetHandler();

    // 10. L2AssetTracker at 0x1000f
    await this.deployL2AssetTracker(chainId);

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
    console.log(`   Using MockL2ToL1Messenger (standard EVM) instead of zkout (zkSync EVM)...`);
    await this.deployMockL2ToL1Messenger();
  }

  /**
   * Deploy mock L2ToL1Messenger (compiled version)
   */
  private async deployMockL2ToL1Messenger(): Promise<void> {
    // Use the compiled MockL2ToL1Messenger bytecode
    const mockPath = path.join(
      this.contractsRoot,
      "l1-contracts/out/MockL2ToL1Messenger.sol/MockL2ToL1Messenger.json"
    );

    const artifact = JSON.parse(fs.readFileSync(mockPath, "utf-8"));
    const bytecode = artifact.deployedBytecode?.object;

    if (!bytecode || bytecode === "0x") {
      throw new Error("MockL2ToL1Messenger bytecode not found - run forge build first");
    }

    await this.l2Provider.send("anvil_setCode", [L2_TO_L1_MESSENGER_ADDR, bytecode]);
    console.log(`   ✅ MockL2ToL1Messenger deployed`);
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
    console.log(`   Using minimal L2BaseToken mock (standard EVM) instead of zkout (zkSync EVM)...`);
    await this.deployMinimalL2BaseToken();
  }

  /**
   * Deploy minimal mock L2BaseToken if real one not available
   */
  private async deployMinimalL2BaseToken(): Promise<void> {
    // Use the compiled MockL2BaseToken bytecode
    const mockPath = path.join(
      this.contractsRoot,
      "l1-contracts/out/MockL2BaseToken.sol/MockL2BaseToken.json"
    );

    const artifact = JSON.parse(fs.readFileSync(mockPath, "utf-8"));
    const bytecode = artifact.deployedBytecode?.object;

    if (!bytecode || bytecode === "0x") {
      throw new Error("MockL2BaseToken bytecode not found - run forge build first");
    }

    await this.l2Provider.send("anvil_setCode", [L2_BASE_TOKEN_ADDR, bytecode]);
    console.log(`   ✅ MockL2BaseToken deployed`);
  }

  /**
   * Deploy and initialize L2Bridgehub
   */
  private async deployL2Bridgehub(chainId: number): Promise<void> {
    const l2BridgehubAbi = loadAbiFromOut("L2Bridgehub.sol/L2Bridgehub.json");

    // Check if already initialized
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbi, this.l2Provider);
    let isInitialized = false;
    try {
      const l1ChainId = await l2Bridgehub.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ L2Bridgehub already initialized`);
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_BRIDGEHUB_ADDR,
        "l1-contracts/out/L2Bridgehub.sol/L2Bridgehub.json",
        "L2Bridgehub"
      );

      const ownerAddress = await this.l2Wallet.getAddress();
      await this.initializeContract(
        L2_BRIDGEHUB_ADDR,
        l2BridgehubAbi,
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
    const ethAssetId = utils.keccak256(
      abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS])
    );

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

      await this.l2Provider.send("anvil_impersonateAccount", [SERVICE_TX_SENDER_ADDR]);
      await this.l2Provider.send("anvil_setBalance", [SERVICE_TX_SENDER_ADDR, "0x56BC75E2D63100000"]);

      const signer = await this.l2Provider.getSigner(SERVICE_TX_SENDER_ADDR);
      const l2BridgehubWithSigner = l2Bridgehub.connect(signer);

      const tx = await l2BridgehubWithSigner.registerChainForInterop(targetChainId, ethAssetId);
      await tx.wait();

      await this.l2Provider.send("anvil_stopImpersonatingAccount", [SERVICE_TX_SENDER_ADDR]);
      console.log(`   ✅ Chain ${targetChainId} registered`);
    }
  }

  /**
   * Deploy and initialize InteropCenter
   */
  private async deployInteropCenter(): Promise<void> {
    const interopCenterAbi = loadAbiFromOut("InteropCenter.sol/InteropCenter.json");

    const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopCenter.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ InteropCenter already initialized`);
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        INTEROP_CENTER_ADDR,
        "l1-contracts/out/InteropCenter.sol/InteropCenter.json",
        "InteropCenter"
      );

      const ownerAddress = await this.l2Wallet.getAddress();
      await this.initializeContract(
        INTEROP_CENTER_ADDR,
        interopCenterAbi,
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
      console.log(`   Unpausing InteropCenter...`);
      const tx = await interopCenterWithOwner.unpause();
      await tx.wait();
      console.log(`   ✅ InteropCenter unpaused`);
    } else {
      console.log(`   ✅ InteropCenter already unpaused`);
    }
  }

  /**
   * Deploy and initialize L2InteropHandler
   */
  private async deployL2InteropHandler(): Promise<void> {
    await this.deploySystemContract(
      L2_INTEROP_HANDLER_ADDR,
      "l1-contracts/out/InteropHandler.sol/InteropHandler.json",
      "L2InteropHandler"
    );

    // Initialize L2InteropHandler
    const interopHandlerAbi = loadAbiFromOut("InteropHandler.sol/InteropHandler.json");

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopHandler.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ L2InteropHandler already initialized`);
        isInitialized = true;
      }
    } catch {}

    if (!isInitialized) {
      await this.initializeContract(
        L2_INTEROP_HANDLER_ADDR,
        interopHandlerAbi,
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
    const l2AssetRouterAbi = loadAbiFromOut("L2AssetRouter.sol/L2AssetRouter.json");

    const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetRouter.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ L2AssetRouter already initialized`);
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
      const ethAssetId = utils.keccak256(
        abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS])
      );

      await this.initializeContract(
        L2_ASSET_ROUTER_ADDR,
        l2AssetRouterAbi,
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
    const l2ChainAssetHandlerAbi = loadAbiFromOut("L2ChainAssetHandler.sol/L2ChainAssetHandler.json");

    const l2ChainAssetHandler = new Contract(L2_CHAIN_ASSET_HANDLER_ADDR, l2ChainAssetHandlerAbi, this.l2Provider);

    // Check if already deployed
    let isDeployed = false;
    try {
      const code = await this.l2Provider.getCode(L2_CHAIN_ASSET_HANDLER_ADDR);
      if (code !== "0x") {
        console.log(`   ✅ L2ChainAssetHandler already deployed`);
        isDeployed = true;
      }
    } catch {
      // Will deploy
    }

    if (!isDeployed) {
      await this.deploySystemContract(
        L2_CHAIN_ASSET_HANDLER_ADDR,
        "l1-contracts/out/L2ChainAssetHandler.sol/L2ChainAssetHandler.json",
        "L2ChainAssetHandler"
      );

      // For now, just deploy without initialization
      // Full initialization would require bridgehub, message root, asset router addresses
      console.log(`   ⚠️  L2ChainAssetHandler deployed but not initialized`);
    }
  }

  /**
   * Deploy and initialize L2AssetTracker at 0x1000f
   */
  private async deployL2AssetTracker(chainId: number): Promise<void> {
    const l2AssetTrackerAbi = loadAbiFromOut("L2AssetTracker.sol/L2AssetTracker.json");

    const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetTracker.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ L2AssetTracker already initialized`);
        isInitialized = true;
      }
    } catch {
      // Will deploy and initialize
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_ASSET_TRACKER_ADDR,
        "l1-contracts/out/L2AssetTracker.sol/L2AssetTracker.json",
        "L2AssetTracker"
      );

      // Initialize via L2ComplexUpgrader
      const abiCoder = new utils.AbiCoder();

      // Calculate ETH asset ID (utils.keccak256(abi.encode(1, 0x0000...0001)))
      const ethAssetId = utils.keccak256(
        abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS])
      );

      await this.initializeContract(
        L2_ASSET_TRACKER_ADDR,
        l2AssetTrackerAbi,
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
    const l2NativeTokenVaultAbi = loadAbiFromOut("L2NativeTokenVault.sol/L2NativeTokenVault.json");
    const l2NativeTokenVaultDevAbi = loadAbiFromOut("L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json");

    const l2NativeTokenVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2NativeTokenVault.L1_CHAIN_ID();
      if (this.isOne(l1ChainId)) {
        console.log(`   ✅ L2NativeTokenVault already initialized`);
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

      const ownerAddress = await this.l2Wallet.getAddress();
      const abiCoder = new utils.AbiCoder();
      const ethAssetId = utils.keccak256(
        abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS])
      );

      await this.initializeContract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        l2NativeTokenVaultAbi,
        "initL2",
        [
          1, // L1 chain ID
          ownerAddress,
          utils.keccak256(utils.toUtf8Bytes("anvil-l2-token-proxy")), // non-zero placeholder hash for anvil setup
          "0x0000000000000000000000000000000000000000", // no legacy bridge in anvil setup
          "0x0000000000000000000000000000000000000000", // no bridged token beacon in anvil setup
          "0x0000000000000000000000000000000000000000", // no WETH token in anvil setup
          [ethAssetId, 1, ETH_TOKEN_ADDRESS],
          ["Ether", "ETH", 18],
        ],
        L2_COMPLEX_UPGRADER_ADDR,
        "L2NativeTokenVault"
      );

      // In Anvil, use the dev helper to deploy a beacon + implementation so bridged token deployment
      // works in plain EVM mode during executeBundle.
      const l2NativeTokenVaultDev = new Contract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        l2NativeTokenVaultDevAbi,
        this.l2Wallet
      );
      const deployBridgedTokenTx = await l2NativeTokenVaultDev.deployBridgedStandardERC20(ownerAddress);
      await deployBridgedTokenTx.wait();

      console.log(`   ✅ L2NativeTokenVault deployed and initialized (dev bridged token beacon configured)`);
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
      console.log(`   ⚠️  State file not found, skipping asset handler registration`);
      return;
    }

    const state = JSON.parse(fs.readFileSync(stateFile, "utf-8"));
    if (!state.testTokens || !state.testTokens[chainId]) {
      console.log(`   ⚠️  No test token for chain ${chainId}, skipping asset handler registration`);
      return;
    }

    const tokenAddress = state.testTokens[chainId];
    const abiCoder = new utils.AbiCoder();
    // Asset ID format: utils.keccak256(abi.encode(chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress))
    const assetId = utils.keccak256(abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress]));

    console.log(`   Registering asset handler for token ${tokenAddress}...`);
    console.log(`   Asset ID: ${assetId}`);

    const l2AssetRouterAbi = loadAbiFromOut("L2AssetRouter.sol/L2AssetRouter.json");

    const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi, this.l2Provider);

    // Check if asset handler already registered
    const currentHandler = await l2AssetRouter.assetHandlerAddress(assetId);
    if (currentHandler === "0x0000000000000000000000000000000000000000") {
      // Register L2NativeTokenVault as the handler
      // We need to impersonate L2NativeTokenVault to call setLegacyTokenAssetHandler
      await this.l2Provider.send("anvil_impersonateAccount", [L2_NATIVE_TOKEN_VAULT_ADDR]);
      await this.l2Provider.send("anvil_setBalance", [L2_NATIVE_TOKEN_VAULT_ADDR, "0x56BC75E2D63100000"]);

      const signer = await this.l2Provider.getSigner(L2_NATIVE_TOKEN_VAULT_ADDR);
      const l2AssetRouterWithSigner = l2AssetRouter.connect(signer);

      const tx = await l2AssetRouterWithSigner.setLegacyTokenAssetHandler(assetId);
      await tx.wait();

      await this.l2Provider.send("anvil_stopImpersonatingAccount", [L2_NATIVE_TOKEN_VAULT_ADDR]);

      console.log(`   ✅ Asset handler registered: ${L2_NATIVE_TOKEN_VAULT_ADDR}`);
    } else {
      console.log(`   ✅ Asset handler already registered: ${currentHandler}`);
    }

    // Now register the token in L2NativeTokenVault
    const l2NativeTokenVaultAbi = loadAbiFromOut("L2NativeTokenVault.sol/L2NativeTokenVault.json");

    const l2NativeTokenVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi, this.l2Provider);

    // Check if token is already registered
    const registeredAssetId = await l2NativeTokenVault.assetId(tokenAddress);
    if (registeredAssetId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
      console.log(`   ✅ Token already registered in L2NativeTokenVault`);
      return;
    }

    // Check if token contract exists on this L2 chain
    const tokenCode = await this.l2Provider.getCode(tokenAddress);
    if (tokenCode === "0x" || tokenCode === "0x0") {
      console.log(`   ⚠️  Token ${tokenAddress} not deployed on chain ${chainId}, skipping registration`);
      console.log(`      (Deploy test tokens with 'yarn deploy:test-token' if needed)`);
      return;
    }

    // Call registerToken()
    console.log(`   Calling registerToken(${tokenAddress})...`);
    try {
      const l2NativeTokenVaultWithWallet = l2NativeTokenVault.connect(this.l2Wallet);
      const registerTx = await l2NativeTokenVaultWithWallet.registerToken(tokenAddress);
      await registerTx.wait();

      console.log(`   ✅ Token registered in L2NativeTokenVault`);
      console.log(`      assetId: ${assetId}`);
    } catch (error: any) {
      console.error(`   ❌ registerToken failed: ${error.message}`);
      throw error;
    }
  }
}
