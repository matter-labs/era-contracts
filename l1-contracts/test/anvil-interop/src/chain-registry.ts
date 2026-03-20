import * as path from "path";
import { providers, Wallet } from "ethers";
import type { ChainConfig, ChainAddresses, CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { parseForgeScriptOutput, ensureDirectoryExists, saveTomlConfig } from "./utils";
import { SystemContractsDeployer } from "./system-contracts-deployer";
import { L2GenesisUpgradeDeployer } from "./l2-genesis-upgrade-deployer";
import { runForgeScript } from "./forge";

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

    const scriptPath = "deploy-scripts/RegisterZKChain.s.sol:RegisterZKChainScript";
    const sig = "runForTest()";

    // Paths relative to project root (must start with /)
    const chainConfigRelPath = configPath.replace(this.projectRoot, "");
    const chainOutputRelPath = outputPath.replace(this.projectRoot, "");

    // V29 RegisterZKChain.runForTest() reads from L1_OUTPUT for addresses, ZK_CHAIN_CONFIG for chain params
    const envVars = {
      L1_OUTPUT: "/test/anvil-interop/outputs/l1-core-output.toml",
      ZK_CHAIN_CONFIG: chainConfigRelPath,
      ZK_CHAIN_OUT: chainOutputRelPath,
    };

    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.l1RpcUrl,
      privateKey: this.privateKey,
      projectRoot: this.projectRoot,
      sig,
    });

    const output = parseForgeScriptOutput(outputPath);

    console.log(`✅ Chain ${config.chainId} registered`);

    return {
      chainId: config.chainId,
      diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
    };
  }

  async registerChainBatch(configs: ChainConfig[]): Promise<ChainAddresses[]> {
    console.log(`📝 Registering ${configs.length} L2 chains sequentially...`);

    const results: ChainAddresses[] = [];
    for (const config of configs) {
      const result = await this.registerChain(config);
      results.push(result);
    }
    return results;
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async initializeL2SystemContracts(chainId: number, _chainProxy: string, l2RpcUrl: string): Promise<void> {
    console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

    const useGenesisUpgradeDeployer = process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE !== "0";
    const deployer = useGenesisUpgradeDeployer
      ? new L2GenesisUpgradeDeployer(
          l2RpcUrl,
          this.privateKey,
          this.l1Addresses.l1SharedBridge,
          this.l1Addresses.ctmDeploymentTracker,
          this.l1Addresses.governance
        )
      : new SystemContractsDeployer(l2RpcUrl, this.privateKey);

    if (useGenesisUpgradeDeployer) {
      console.log("   Using L2GenesisUpgrade deployer path");
    } else {
      console.log("   Using direct SystemContractsDeployer path");
    }
    await deployer.deployAllSystemContracts(chainId);

    console.log(`✅ L2 system contracts initialized for chain ${chainId}`);
  }

  private async generateChainConfig(config: ChainConfig): Promise<string> {
    const configPath = path.join(__dirname, `../config/chain-${config.chainId}.toml`);

    const ownerAddress = await this.wallet.getAddress();

    const chainConfig = {
      owner_address: ownerAddress,
      initialize_legacy_bridge: false,
      governance: this.l1Addresses.governance,
      create2_factory_address: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
      create2_salt: "0x00000000000000000000000000000000000000000000000000000000000000ff",
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
        validator_sender_operator_prove: ownerAddress,
        validator_sender_operator_execute: ownerAddress,
        allow_evm_emulator: false,
      },
    };

    saveTomlConfig(configPath, chainConfig);

    return configPath;
  }
}
