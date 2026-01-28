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
}
