import * as fs from "fs";
import * as path from "path";
import { JsonRpcProvider, Contract, Wallet } from "ethers";

/**
 * SystemContractsDeployer
 *
 * Systematically deploys L2 system contracts needed for InteropCenter
 * This is a helper class that deploys contracts in the correct order
 * and handles initialization properly.
 */
export class SystemContractsDeployer {
  private l2Provider: JsonRpcProvider;
  private l2Wallet: Wallet;
  private contractsRoot: string;

  constructor(l2RpcUrl: string, privateKey: string) {
    this.l2Provider = new JsonRpcProvider(l2RpcUrl);
    this.l2Wallet = new Wallet(privateKey, this.l2Provider);
    this.contractsRoot = path.resolve(__dirname, "../../../..");
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
    const tx = await contractWithSigner.getFunction(initFunction)(...args);
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
      "0x000000000000000000000000000000000000800b",
      "l1-contracts/out/MockSystemContext.sol/MockSystemContext.json",
      "MockSystemContext"
    );

    // 2. L2ToL1Messenger at 0x8008
    await this.deployL2ToL1Messenger();

    // 3. L2BaseToken at 0x800a
    await this.deployL2BaseToken();

    // 4. L2Bridgehub at 0x010002
    await this.deployL2Bridgehub(chainId);

    // 5. InteropCenter at 0x1000d
    await this.deployInteropCenter();

    // 6. L2InteropHandler at 0x1000e
    await this.deployL2InteropHandler();

    // 7. L2AssetRouter at 0x010003
    await this.deployL2AssetRouter();

    // 8. L2ChainAssetHandler at 0x1000a
    await this.deployL2ChainAssetHandler();

    // 9. L2AssetTracker at 0x1000f
    await this.deployL2AssetTracker(chainId);

    // 10. L2NativeTokenVault at 0x010004
    await this.deployL2NativeTokenVault();

    // 11. Register asset handlers for test tokens
    await this.registerAssetHandlers(chainId);

    console.log(`✅ All system contracts deployed for chain ${chainId}`);
  }

  /**
   * Deploy L2ToL1Messenger system contract
   */
  private async deployL2ToL1Messenger(): Promise<void> {
    const L2_TO_L1_MESSENGER_ADDR = "0x0000000000000000000000000000000000008008";

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
    const L2_TO_L1_MESSENGER_ADDR = "0x0000000000000000000000000000000000008008";

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
    const L2_BASE_TOKEN_ADDR = "0x000000000000000000000000000000000000800a";

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
    const L2_BASE_TOKEN_ADDR = "0x000000000000000000000000000000000000800a";

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
    const L2_BRIDGEHUB_ADDR = "0x0000000000000000000000000000000000010002";

    const l2BridgehubAbi = [
      "function initL2(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfZKChains) external",
      "function registerChainForInterop(uint256 _chainId, bytes32 _baseTokenAssetId) external",
      "function baseTokenAssetId(uint256 _chainId) external view returns (bytes32)",
      "function L1_CHAIN_ID() external view returns (uint256)",
    ];

    // Check if already initialized
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbi, this.l2Provider);
    let isInitialized = false;
    try {
      const l1ChainId = await l2Bridgehub.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
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
        "0x000000000000000000000000000000000000800f", // L2_COMPLEX_UPGRADER
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
    const { keccak256, AbiCoder } = require("ethers");
    const abiCoder = AbiCoder.defaultAbiCoder();
    const ethAssetId = keccak256(
      abiCoder.encode(["uint256", "address"], [1, "0x0000000000000000000000000000000000000001"])
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

      const SERVICE_TX_SENDER = "0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF";
      await this.l2Provider.send("anvil_impersonateAccount", [SERVICE_TX_SENDER]);
      await this.l2Provider.send("anvil_setBalance", [SERVICE_TX_SENDER, "0x56BC75E2D63100000"]);

      const signer = await this.l2Provider.getSigner(SERVICE_TX_SENDER);
      const l2BridgehubWithSigner = l2Bridgehub.connect(signer);

      const tx = await l2BridgehubWithSigner.getFunction("registerChainForInterop")(
        targetChainId,
        ethAssetId
      );
      await tx.wait();

      await this.l2Provider.send("anvil_stopImpersonatingAccount", [SERVICE_TX_SENDER]);
      console.log(`   ✅ Chain ${targetChainId} registered`);
    }
  }

  /**
   * Deploy and initialize InteropCenter
   */
  private async deployInteropCenter(): Promise<void> {
    const INTEROP_CENTER_ADDR = "0x000000000000000000000000000000000001000d";

    const interopCenterAbi = [
      "function initL2(uint256 _l1ChainId, address _owner) external",
      "function unpause() external",
      "function paused() external view returns (bool)",
      "function L1_CHAIN_ID() external view returns (uint256)",
    ];

    const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopCenter.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
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
        "0x000000000000000000000000000000000000800f", // L2_COMPLEX_UPGRADER
        "InteropCenter"
      );
    }

    // Unpause if needed
    const interopCenterWithOwner = interopCenter.connect(this.l2Wallet);
    const isPaused = await interopCenterWithOwner.getFunction("paused")();
    if (isPaused) {
      console.log(`   Unpausing InteropCenter...`);
      const tx = await interopCenterWithOwner.getFunction("unpause")();
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
    const L2_INTEROP_HANDLER_ADDR = "0x000000000000000000000000000000000001000e";
    const L2_COMPLEX_UPGRADER_ADDR = "0x000000000000000000000000000000000000800f";

    await this.deploySystemContract(
      L2_INTEROP_HANDLER_ADDR,
      "l1-contracts/out/InteropHandler.sol/InteropHandler.json",
      "L2InteropHandler"
    );

    // Initialize L2InteropHandler
    const interopHandlerAbi = [
      "function initL2(uint256 _l1ChainId) public",
      "function L1_CHAIN_ID() external view returns (uint256)"
    ];

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopHandler.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
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
    const L2_ASSET_ROUTER_ADDR = "0x0000000000000000000000000000000000010003";

    const l2AssetRouterAbi = [
      "function initL2(uint256 _l1ChainId, uint256 _eraChainId, address _l1AssetRouter, address _legacySharedBridge, bytes32 _baseTokenAssetId, address _aliasedOwner) external",
      "function L1_CHAIN_ID() external view returns (uint256)",
    ];

    const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetRouter.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
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
      const { keccak256, AbiCoder } = require("ethers");
      const abiCoder = AbiCoder.defaultAbiCoder();
      const ethAssetId = keccak256(
        abiCoder.encode(["uint256", "address"], [1, "0x0000000000000000000000000000000000000001"])
      );

      await this.initializeContract(
        L2_ASSET_ROUTER_ADDR,
        l2AssetRouterAbi,
        "initL2",
        [
          1, // L1 chain ID
          270, // Era chain ID
          "0x0000000000000000000000000000000000000001", // L1AssetRouter (dummy)
          "0x0000000000000000000000000000000000000002", // LegacySharedBridge (dummy)
          ethAssetId, // Base token asset ID
          ownerAddress,
        ],
        "0x000000000000000000000000000000000000800f", // L2_COMPLEX_UPGRADER
        "L2AssetRouter"
      );
    }
  }

  /**
   * Deploy and initialize L2ChainAssetHandler at 0x1000a
   */
  private async deployL2ChainAssetHandler(): Promise<void> {
    const L2_CHAIN_ASSET_HANDLER_ADDR = "0x000000000000000000000000000000000001000a";

    const l2ChainAssetHandlerAbi = [
      "function L1_CHAIN_ID() external view returns (uint256)",
      "function migrationNumber(uint256 _chainId) external view returns (uint256)",
    ];

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
    const L2_ASSET_TRACKER_ADDR = "0x000000000000000000000000000000000001000f";
    const L2_COMPLEX_UPGRADER_ADDR = "0x000000000000000000000000000000000000800f";

    const l2AssetTrackerAbi = [
      "function L1_CHAIN_ID() external view returns (uint256)",
      "function BASE_TOKEN_ASSET_ID() external view returns (bytes32)",
      "function setAddresses(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external",
    ];

    const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2AssetTracker.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
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
      const { keccak256, AbiCoder } = require("ethers");
      const abiCoder = AbiCoder.defaultAbiCoder();

      // Calculate ETH asset ID (keccak256(abi.encode(1, 0x0000...0001)))
      const ethAssetId = keccak256(
        abiCoder.encode(["uint256", "address"], [1, "0x0000000000000000000000000000000000000001"])
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
    const L2_NATIVE_TOKEN_VAULT_ADDR = "0x0000000000000000000000000000000000010004";

    const l2NativeTokenVaultAbi = [
      "function L1_CHAIN_ID() external view returns (uint256)",
    ];

    const l2NativeTokenVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi, this.l2Provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await l2NativeTokenVault.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
        console.log(`   ✅ L2NativeTokenVault already initialized`);
        isInitialized = true;
      }
    } catch {
      // Will deploy
    }

    if (!isInitialized) {
      await this.deploySystemContract(
        L2_NATIVE_TOKEN_VAULT_ADDR,
        "l1-contracts/out/L2NativeTokenVault.sol/L2NativeTokenVault.json",
        "L2NativeTokenVault"
      );

      console.log(`   ✅ L2NativeTokenVault deployed (registerToken works without initialization)`);
    }
  }

  /**
   * Register asset handlers for tokens
   */
  private async registerAssetHandlers(chainId: number): Promise<void> {
    const L2_ASSET_ROUTER_ADDR = "0x0000000000000000000000000000000000010003";
    const L2_NATIVE_TOKEN_VAULT_ADDR = "0x0000000000000000000000000000000000010004";

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
    const { keccak256, AbiCoder } = require("ethers");
    const abiCoder = AbiCoder.defaultAbiCoder();
    // Asset ID format: keccak256(abi.encode(chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress))
    const assetId = keccak256(abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress]));

    console.log(`   Registering asset handler for token ${tokenAddress}...`);
    console.log(`   Asset ID: ${assetId}`);

    const l2AssetRouterAbi = [
      "function assetHandlerAddress(bytes32 _assetId) external view returns (address)",
      "function setLegacyTokenAssetHandler(bytes32 _assetId) external",
    ];

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

      const tx = await l2AssetRouterWithSigner.getFunction("setLegacyTokenAssetHandler")(assetId);
      await tx.wait();

      await this.l2Provider.send("anvil_stopImpersonatingAccount", [L2_NATIVE_TOKEN_VAULT_ADDR]);

      console.log(`   ✅ Asset handler registered: ${L2_NATIVE_TOKEN_VAULT_ADDR}`);
    } else {
      console.log(`   ✅ Asset handler already registered: ${currentHandler}`);
    }

    // Now register the token in L2NativeTokenVault
    const l2NativeTokenVaultAbi = [
      "function assetId(address _token) external view returns (bytes32)",
      "function registerToken(address _nativeToken) external",
    ];

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
      const registerTx = await l2NativeTokenVaultWithWallet.getFunction("registerToken")(tokenAddress);
      await registerTx.wait();

      console.log(`   ✅ Token registered in L2NativeTokenVault`);
      console.log(`      assetId: ${assetId}`);
    } catch (error: any) {
      console.error(`   ❌ registerToken failed: ${error.message}`);
      throw error;
    }
  }
}
