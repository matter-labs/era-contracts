import * as path from "path";
import * as fs from "fs";
import { ethers, providers, Wallet } from "ethers";
import type {
  ChainConfig,
  ChainAddresses,
  CoreDeployedAddresses,
  CTMDeployedAddresses,
  AnvilConfig,
} from "../core/types";
import { parseForgeScriptOutput, ensureDirectoryExists, saveTomlConfig } from "../core/utils";
import { SystemContractsDeployer } from "./system-contracts-deployer";
import { L2GenesisUpgradeDeployer } from "./l2-genesis-upgrade-deployer";
import { runForgeScript } from "../core/forge";

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
    this.projectRoot = path.resolve(__dirname, "../../../..");
    this.outputDir = path.join(__dirname, "../../outputs");
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
    const ctmOutputRelPath = "/test/anvil-interop/outputs/ctm-output.toml";
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
      PERMANENT_VALUES_INPUT: "/test/anvil-interop/config/permanent-values.toml",
    };

    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.l1RpcUrl,
      privateKey: this.privateKey,
      projectRoot: this.projectRoot,
      sig,
      args,
    });

    const output = parseForgeScriptOutput(outputPath);

    console.log(`✅ Chain ${config.chainId} registered`);

    return {
      chainId: config.chainId,
      diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
    };
  }

  async registerChainBatch(configs: ChainConfig[]): Promise<ChainAddresses[]> {
    console.log(`📝 Registering ${configs.length} L2 chains in batch...`);

    // Generate all config files first
    for (const config of configs) {
      await this.generateChainConfig(config);
    }

    const chainIds = configs.map((c) => c.chainId);
    const scriptPath = "deploy-scripts/ctm/RegisterZKChain.s.sol:RegisterZKChainScript";
    const sig = "runForTestBatch(address,uint256[])";
    // Encode chainIds array as ABI: [id1,id2,id3]
    const chainIdsArg = `[${chainIds.join(",")}]`;
    const args = `${this.ctmAddresses.chainTypeManager} ${chainIdsArg}`;

    const envVars = {
      CTM_OUTPUT: "/test/anvil-interop/outputs/ctm-output.toml",
      PERMANENT_VALUES_INPUT: "/test/anvil-interop/config/permanent-values.toml",
    };

    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.l1RpcUrl,
      privateKey: this.privateKey,
      projectRoot: this.projectRoot,
      sig,
      args,
    });

    // Parse per-chain outputs
    const results: ChainAddresses[] = [];
    for (const config of configs) {
      const outputPath = path.join(this.outputDir, `chain-${config.chainId}-output.toml`);
      const output = parseForgeScriptOutput(outputPath);
      console.log(`✅ Chain ${config.chainId} registered`);
      results.push({
        chainId: config.chainId,
        diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
      });
    }
    return results;
  }

  private computeInteropChainIds(chainId: number, config: AnvilConfig): number[] {
    const l2Chains = config.chains.filter((c) => !c.isL1);
    const thisChain = l2Chains.find((c) => c.chainId === chainId);

    if (thisChain?.isGateway) {
      // GW chain: only GW-settled chains + itself
      return l2Chains.filter((c) => c.settlement === "gateway" || c.chainId === chainId).map((c) => c.chainId);
    }

    // Non-GW L2 chains: all other L2 chain IDs + GW
    return l2Chains.map((c) => c.chainId);
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async initializeL2SystemContracts(chainId: number, _chainProxy: string, l2RpcUrl: string): Promise<void> {
    console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

    const configPath = path.join(__dirname, "../../config/anvil-config.json");
    let gatewayChainId = 1;
    let interopChainIds: number[] | undefined;
    if (fs.existsSync(configPath)) {
      const config: AnvilConfig = JSON.parse(fs.readFileSync(configPath, "utf-8"));
      gatewayChainId = config.chains?.find((chain) => chain.isGateway)?.chainId ?? 1;
      interopChainIds = this.computeInteropChainIds(chainId, config);
    }

    const useGenesisUpgradeDeployer = process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE !== "0";
    const deployer = useGenesisUpgradeDeployer
      ? new L2GenesisUpgradeDeployer(
          l2RpcUrl,
          this.privateKey,
          this.l1Addresses.l1SharedBridge,
          this.l1Addresses.ctmDeploymentTracker,
          this.l1Addresses.governance,
          this.l1Addresses.chainRegistrationSender,
          gatewayChainId
        )
      : new SystemContractsDeployer(l2RpcUrl, this.privateKey, this.l1Addresses.l1SharedBridge);

    if (useGenesisUpgradeDeployer) {
      console.log("   Using L2GenesisUpgrade deployer path");
    } else {
      console.log("   Using direct SystemContractsDeployer path");
    }
    await deployer.deployAllSystemContracts(chainId, interopChainIds);

    console.log(`✅ L2 system contracts initialized for chain ${chainId}`);
  }

  private async generateChainConfig(config: ChainConfig): Promise<string> {
    const configPath = path.join(__dirname, `../../config/chain-${config.chainId}.toml`);

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
        governance_security_council_address: ethers.constants.AddressZero,
        governance_min_delay: 0,
        validator_sender_operator_eth: ownerAddress,
        validator_sender_operator_blobs_eth: ownerAddress,
        allow_evm_emulator: false,
      },
    };

    saveTomlConfig(configPath, chainConfig);

    return configPath;
  }
}
