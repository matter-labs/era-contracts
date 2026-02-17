import { exec } from "child_process";
import { promisify } from "util";
import * as path from "path";
import * as fs from "fs";
import { providers, Contract, Wallet, utils } from "ethers";
import type { ChainConfig, ChainAddresses, CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { parseForgeScriptOutput, ensureDirectoryExists, saveTomlConfig, loadAbiFromOut } from "./utils";
import { buildComplexUpgraderCalldata, getL2ComplexUpgraderAddress } from "./l2-genesis-helper";
import { SystemContractsDeployer } from "./system-contracts-deployer";
import {
  ETH_TOKEN_ADDRESS,
  INTEROP_CENTER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  SERVICE_TX_SENDER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "./const";

const execAsync = promisify(exec);

export class ChainRegistry {
  private l1RpcUrl: string;
  private privateKey: string;
  private l1Provider: providers.JsonRpcProvider;
  private wallet: Wallet;
  private projectRoot: string;
  private outputDir: string;
  private l1Addresses: CoreDeployedAddresses;
  private ctmAddresses: CTMDeployedAddresses;

  constructor(
    l1RpcUrl: string,
    privateKey: string,
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ) {
    this.l1RpcUrl = l1RpcUrl;
    this.privateKey = privateKey;
    this.l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    this.wallet = new Wallet(privateKey, this.l1Provider);
    this.projectRoot = path.resolve(__dirname, "../../..");
    this.outputDir = path.join(__dirname, "../outputs");
    this.l1Addresses = l1Addresses;
    this.ctmAddresses = ctmAddresses;
    ensureDirectoryExists(this.outputDir);
  }

  async registerChain(config: ChainConfig): Promise<ChainAddresses> {
    console.log(`📝 Registering L2 chain ${config.chainId}...`);

    const configPath = await this.generateChainConfig(config);
    const outputPath = path.join(this.outputDir, `chain-${config.chainId}-output.toml`);

    const scriptPath = "deploy-scripts/ctm/RegisterZKChain.s.sol:RegisterZKChainScript";
    const sig = "runForTest(address,uint256)";
    const args = `${this.ctmAddresses.chainTypeManager} ${config.chainId}`;

    // Paths relative to project root (must start with /)
    const ctmOutputRelPath = "/scripts/anvil-interop/outputs/ctm-output.toml";
    const chainConfigRelPath = configPath.replace(this.projectRoot, "");
    const chainOutputRelPath = outputPath.replace(this.projectRoot, "");

    const envVars = {
      CHAIN_CONFIG: configPath,
      CHAIN_OUTPUT: outputPath,
      BRIDGEHUB_ADDR: this.l1Addresses.bridgehub,
      CTM_ADDR: this.ctmAddresses.chainTypeManager,
      CTM_OUTPUT: ctmOutputRelPath,
      ZK_CHAIN_CONFIG: chainConfigRelPath,
      ZK_CHAIN_OUT: chainOutputRelPath,
      PERMANENT_VALUES_INPUT: "/scripts/anvil-interop/config/permanent-values.toml",
    };

    await this.runForgeScript(scriptPath, envVars, sig, args);

    const output = parseForgeScriptOutput(outputPath);

    console.log(`✅ Chain ${config.chainId} registered`);

    return {
      chainId: config.chainId,
      diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
    };
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async initializeL2SystemContracts(chainId: number, _chainProxy: string, l2RpcUrl: string): Promise<void> {
    console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

    // Use SystemContractsDeployer for systematic deployment
    const deployer = new SystemContractsDeployer(l2RpcUrl, this.privateKey);
    await deployer.deployAllSystemContracts(chainId);

    console.log(`✅ L2 system contracts initialized for chain ${chainId}`);
  }

  // LEGACY CODE BELOW - Keeping for reference, can be removed later
  async initializeL2SystemContractsLEGACY(chainId: number, _chainProxy: string, l2RpcUrl: string): Promise<void> {
    console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

    // Connect directly to L2 chain
    const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    const l2Wallet = new Wallet(this.privateKey, l2Provider);

    // Get the contracts root (go up from scripts/anvil-interop to contracts/)
    const contractsRoot = path.resolve(this.projectRoot, "..");

    console.log(`   Using Anvil unlocked mode to deploy system contracts...`);
    console.log(`   - Chain ID: ${chainId}`);
    console.log(`   - L2 RPC: ${l2RpcUrl}`);

    // Deploy mock SystemContext at 0x800b
    // This is needed because InteropCenter calls currentSettlementLayerChainId()
    // Check if SystemContext already has code
    const existingSystemContextCode = await l2Provider.getCode(SYSTEM_CONTEXT_ADDR);
    if (existingSystemContextCode === "0x" || existingSystemContextCode === "0x0") {
      console.log(`   Deploying mock SystemContext at ${SYSTEM_CONTEXT_ADDR}...`);

      // Read MockSystemContext bytecode from compiled artifact
      const mockSystemContextPath = path.join(
        contractsRoot,
        "l1-contracts/out/MockSystemContext.sol/MockSystemContext.json"
      );
      const mockSystemContextArtifact = JSON.parse(fs.readFileSync(mockSystemContextPath, "utf-8"));
      const mockSystemContextBytecode = mockSystemContextArtifact.deployedBytecode.object;

      await l2Provider.send("anvil_setCode", [SYSTEM_CONTEXT_ADDR, mockSystemContextBytecode]);
      console.log(`   ✅ Mock SystemContext deployed`);
    } else {
      console.log(`   ✅ SystemContext already deployed`);
    }

    // Deploy L2Bridgehub at 0x010002
    // This is needed because InteropCenter calls L2_BRIDGEHUB.baseTokenAssetId()
    const l2BridgehubAbi = loadAbiFromOut("L2Bridgehub.sol/L2Bridgehub.json");

    // Check if L2Bridgehub already has code and is initialized
    let isL2BridgehubInitialized = false;
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbi, l2Provider);

    try {
      const l1ChainId = await l2Bridgehub.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
        console.log(`   ✅ L2Bridgehub already initialized on chain ${chainId}`);
        isL2BridgehubInitialized = true;
      }
    } catch {
      // Contract might not exist yet, will deploy below
    }

    if (!isL2BridgehubInitialized) {
      console.log(`   Deploying L2Bridgehub at ${L2_BRIDGEHUB_ADDR}...`);

      // Read L2Bridgehub bytecode from compiled artifact
      const l2BridgehubPath = path.join(
        contractsRoot,
        "l1-contracts/out/L2Bridgehub.sol/L2Bridgehub.json"
      );
      const l2BridgehubArtifact = JSON.parse(fs.readFileSync(l2BridgehubPath, "utf-8"));
      const l2BridgehubBytecode = l2BridgehubArtifact.deployedBytecode.object;

      await l2Provider.send("anvil_setCode", [L2_BRIDGEHUB_ADDR, l2BridgehubBytecode]);

      // Initialize L2Bridgehub using L2_COMPLEX_UPGRADER
      await l2Provider.send("anvil_impersonateAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      const ownerAddress = await l2Wallet.getAddress();
      console.log(`   Initializing L2Bridgehub with owner: ${ownerAddress}...`);

      const impersonatedSigner = await l2Provider.getSigner(L2_COMPLEX_UPGRADER_ADDR);
      const l2BridgehubWithSigner = l2Bridgehub.connect(impersonatedSigner);

      // Initialize with L1_CHAIN_ID=1, owner, maxChains=100
      const initTx = await l2BridgehubWithSigner.getFunction("initL2")(1, ownerAddress, 100);
      await initTx.wait();

      await l2Provider.send("anvil_stopImpersonatingAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      console.log(`   ✅ L2Bridgehub initialized`);
    }

    // Register chains on L2Bridgehub for interop
    const abiCoder = new utils.AbiCoder();
    const ethAssetId = utils.keccak256(abiCoder.encode(["uint256", "address"], [1, ETH_TOKEN_ADDRESS]));

    // Register common chain IDs for Anvil test environment (10, 11, 12)
    const chainIdsToRegister = [10, 11, 12];

    for (const targetChainId of chainIdsToRegister) {
      try {
        const existingAssetId = await l2Bridgehub.baseTokenAssetId(targetChainId);
        if (existingAssetId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
          console.log(`   ✅ Chain ${targetChainId} already registered on L2Bridgehub`);
          continue;
        }
      } catch {
        // Will register below
      }

      console.log(`   Registering chain ${targetChainId} on L2Bridgehub...`);

      // Use SERVICE_TRANSACTION_SENDER for registration (as defined in Config.sol)
      await l2Provider.send("anvil_impersonateAccount", [SERVICE_TX_SENDER_ADDR]);
      await l2Provider.send("anvil_setBalance", [SERVICE_TX_SENDER_ADDR, "0x56BC75E2D63100000"]);

      const serviceTxSigner = await l2Provider.getSigner(SERVICE_TX_SENDER_ADDR);
      const l2BridgehubWithServiceSigner = l2Bridgehub.connect(serviceTxSigner);

      const registerTx = await l2BridgehubWithServiceSigner.getFunction("registerChainForInterop")(
        targetChainId,
        ethAssetId
      );
      await registerTx.wait();

      await l2Provider.send("anvil_stopImpersonatingAccount", [SERVICE_TX_SENDER_ADDR]);

      console.log(`   ✅ Chain ${targetChainId} registered on L2Bridgehub`);
    }

    // Read InteropCenter bytecode (compiled with Solc, stored in out/)
    const interopCenterPath = path.join(
      contractsRoot,
      "l1-contracts/out/InteropCenter.sol/InteropCenter.json"
    );
    const interopCenterArtifact = JSON.parse(fs.readFileSync(interopCenterPath, "utf-8"));
    // Use deployedBytecode (runtime bytecode) for anvil_setCode, not bytecode (deployment bytecode)
    const interopCenterBytecode = interopCenterArtifact.deployedBytecode.object;

    // Use anvil_setCode to deploy InteropCenter at expected address
    const interopCenterAbi = loadAbiFromOut("InteropCenter.sol/InteropCenter.json");
    const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbi, l2Provider);

    // Check if already initialized by checking L1_CHAIN_ID
    let isAlreadyInitialized = false;
    try {
      const l1ChainId = await interopCenter.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
        console.log(`   ✅ InteropCenter already initialized on chain ${chainId}`);
        isAlreadyInitialized = true;
      }
    } catch {
      // Contract might not exist yet, will deploy below
    }

    if (!isAlreadyInitialized) {
      console.log(`   Deploying InteropCenter at ${INTEROP_CENTER_ADDR}...`);

      await l2Provider.send("anvil_setCode", [INTEROP_CENTER_ADDR, interopCenterBytecode]);

      // Initialize InteropCenter by calling initL2
      // We need to impersonate L2_COMPLEX_UPGRADER to call initL2 (it has onlyUpgrader modifier)
      // Set balance for impersonated account
      await l2Provider.send("anvil_setBalance", [
        L2_COMPLEX_UPGRADER_ADDR,
        "0x56BC75E2D63100000", // 100 ETH
      ]);

      // Impersonate and send initialization transaction
      await l2Provider.send("anvil_impersonateAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      const ownerAddress = await l2Wallet.getAddress();
      console.log(`   Initializing InteropCenter with owner: ${ownerAddress}...`);

      // Create a signer from the impersonated account
      const impersonatedSigner = await l2Provider.getSigner(L2_COMPLEX_UPGRADER_ADDR);
      const interopCenterWithSigner = interopCenter.connect(impersonatedSigner);

      // Call initL2 using getFunction to avoid TypeScript errors
      const initTx = await interopCenterWithSigner.getFunction("initL2")(1, ownerAddress);
      await initTx.wait();

      await l2Provider.send("anvil_stopImpersonatingAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      console.log(`   InteropCenter initialized (L1_CHAIN_ID=1)`);
    }

    // Unpause the contract if it's paused (only owner can unpause)
    const interopCenterWithOwner = interopCenter.connect(l2Wallet);
    const isPaused = await interopCenterWithOwner.getFunction("paused")();
    if (isPaused) {
      console.log(`   Unpausing InteropCenter...`);
      const unpauseTx = await interopCenterWithOwner.getFunction("unpause")();
      await unpauseTx.wait();
      console.log(`   InteropCenter unpaused`);
    } else {
      console.log(`   ✅ InteropCenter already unpaused`);
    }

    console.log(`✅ L2 system contracts initialized for chain ${chainId}`);
  }

  async unpauseDeposits(chainId: number, chainProxy: string): Promise<void> {
    console.log(`🔓 Checking deposit status for chain ${chainId}...`);

    const adminAbi = loadAbiFromOut("AdminFacet.sol/AdminFacet.json");
    const adminContract = new Contract(chainProxy, adminAbi, this.wallet);

    // Check if deposits are already unpaused
    try {
      const paused = await adminContract.areDepositsPaused();
      if (!paused) {
        console.log(`   ✅ Deposits already enabled for chain ${chainId} (no action needed)`);
        return;
      }
    } catch (error) {
      console.log(`   ℹ️  Could not check deposit status, attempting to unpause...`);
    }

    // Unpause deposits
    try {
      const tx = await adminContract.unpauseDeposits();
      console.log(`   Transaction sent: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`✅ Deposits unpaused for chain ${chainId} (block ${receipt?.blockNumber})`);
    } catch (error: any) {
      if (error.message?.includes("DepositsNotPaused")) {
        console.log(`   ✅ Deposits already enabled for chain ${chainId}`);
      } else {
        throw error;
      }
    }
  }

  private async generateChainConfig(config: ChainConfig): Promise<string> {
    const configPath = path.join(__dirname, `../config/chain-${config.chainId}.toml`);

    const ownerAddress = await this.wallet.getAddress();

    const chainConfig = {
      owner_address: ownerAddress,
      chain: {
        chain_chain_id: config.chainId,
        base_token_addr: config.baseToken,
        bridgehub_create_new_chain_salt: config.chainId * 1000000,
        validium_mode: config.validiumMode,
        base_token_gas_price_multiplier_nominator: 1,
        base_token_gas_price_multiplier_denominator: 1,
        governance_security_council_address: "0x0000000000000000000000000000000000000000",
        governance_min_delay: 0,
        validator_sender_operator_eth: ownerAddress,
        validator_sender_operator_blobs_eth: ownerAddress,
        allow_evm_emulator: false,
      },
    };

    saveTomlConfig(configPath, chainConfig);

    return configPath;
  }


  private async runForgeScript(
    scriptPath: string,
    envVars: Record<string, string>,
    sig?: string,
    args?: string
  ): Promise<string> {
    const env = {
      ...process.env,
      ...envVars,
    };

    let command = `forge script ${scriptPath} --rpc-url ${this.l1RpcUrl} --private-key ${this.privateKey} --broadcast --legacy`;

    if (sig) {
      command += ` --sig "${sig}"`;
      if (args) {
        command += ` ${args}`;
      }
    }

    console.log(`   Running: ${scriptPath}`);

    try {
      const { stdout, stderr } = await execAsync(command, {
        cwd: this.projectRoot,
        env,
        maxBuffer: 10 * 1024 * 1024,
      });

      if (stderr && !stderr.includes("Warning")) {
        console.warn("   Forge stderr:", stderr);
      }

      return stdout;
    } catch (error) {
      const err = error as { message?: string; stdout?: string; stderr?: string };
      console.error("❌ Forge script failed:");
      console.error("   Command:", command);
      console.error("   Error:", err.message);
      if (err.stdout) {
        console.error("   Stdout:", err.stdout);
      }
      if (err.stderr) {
        console.error("   Stderr:", err.stderr);
      }
      throw error;
    }
  }
}
