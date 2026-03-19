import * as path from "path";
import * as fs from "fs";
import { ethers, providers, Wallet } from "ethers";
import type {
  ChainConfig,
  ChainAddresses,
  CoreDeployedAddresses,
  CTMDeployedAddresses,
  AnvilConfig,
  PriorityRequestData,
} from "../core/types";
import { parseForgeScriptOutput, ensureDirectoryExists, saveTomlConfig } from "../core/utils";
import { SystemContractsDeployer } from "./system-contracts-deployer";
import { L2GenesisUpgradeDeployer } from "./l2-genesis-upgrade-deployer";
import { runForgeScript } from "../core/forge";
import { GENESIS_UPGRADE_EVENT_SIG } from "../core/const";
import { il1GenesisUpgradeAbi } from "../core/contracts";

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

  async registerChainBatch(
    configs: ChainConfig[]
  ): Promise<{ chainAddresses: ChainAddresses[]; genesisPriorityTxs: Map<number, PriorityRequestData> }> {
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

    // Record L1 block before forge script so we can scan for NewPriorityRequest events after
    const blockBeforeRegistration = await this.l1Provider.getBlockNumber();

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
    const chainAddresses: ChainAddresses[] = [];
    for (const config of configs) {
      const outputPath = path.join(this.outputDir, `chain-${config.chainId}-output.toml`);
      const output = parseForgeScriptOutput(outputPath);
      console.log(`✅ Chain ${config.chainId} registered`);
      chainAddresses.push({
        chainId: config.chainId,
        diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
      });
    }

    // Extract genesis upgrade L2 transactions from L1 GenesisUpgrade events.
    // During createNewChain(), L1GenesisUpgrade.genesisUpgrade() is executed via delegatecall
    // from the diamond proxy, emitting GenesisUpgrade with the full L2CanonicalTransaction.
    const genesisPriorityTxs = await this.extractGenesisTxs(
      chainAddresses,
      blockBeforeRegistration + 1
    );

    return { chainAddresses, genesisPriorityTxs };
  }

  /**
   * Scan L1 blocks for GenesisUpgrade events emitted during chain registration.
   * Each diamond proxy emits exactly one GenesisUpgrade event containing the L2 upgrade tx.
   *
   * Note: The genesis upgrade does NOT emit NewPriorityRequest — the upgrade tx is stored
   * in s.l2SystemContractsUpgradeTxHash and executed by the bootloader in the next batch.
   * We extract it from the GenesisUpgrade event and relay it manually on Anvil.
   */
  private async extractGenesisTxs(
    chainAddresses: ChainAddresses[],
    fromBlock: number
  ): Promise<Map<number, PriorityRequestData>> {
    const genesisUpgradeTopic = ethers.utils.id(GENESIS_UPGRADE_EVENT_SIG);
    const latestBlock = await this.l1Provider.getBlockNumber();

    const genesisTxs = new Map<number, PriorityRequestData>();
    const genesisIface = new ethers.utils.Interface(il1GenesisUpgradeAbi());

    for (const chain of chainAddresses) {
      const logs = await this.l1Provider.getLogs({
        address: chain.diamondProxy,
        topics: [genesisUpgradeTopic],
        fromBlock,
        toBlock: latestBlock,
      });

      if (logs.length === 0) {
        throw new Error(
          `No GenesisUpgrade event found for chain ${chain.chainId} at ${chain.diamondProxy}. ` +
            `Scanned blocks ${fromBlock}..${latestBlock}.`
        );
      }

      // Parse the GenesisUpgrade event — extract L2CanonicalTransaction
      const parsed = genesisIface.parseLog({ topics: logs[0].topics, data: logs[0].data });
      const l2Tx = parsed.args._l2Transaction;
      const fromUint256 = ethers.BigNumber.from(l2Tx.from);
      const toUint256 = ethers.BigNumber.from(l2Tx.to);

      genesisTxs.set(chain.chainId, {
        from: ethers.utils.getAddress(ethers.utils.hexZeroPad(fromUint256.toHexString(), 20)),
        to: ethers.utils.getAddress(ethers.utils.hexZeroPad(toUint256.toHexString(), 20)),
        calldata: l2Tx.data,
        value: ethers.BigNumber.from(l2Tx.value),
      });
      console.log(`   Captured genesis upgrade tx for chain ${chain.chainId}`);
    }

    return genesisTxs;
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

  async initializeL2SystemContracts(
    chainId: number,
    l2RpcUrl: string,
    genesisPriorityTx?: PriorityRequestData
  ): Promise<void> {
    console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

    const configPath = path.join(__dirname, "../../config/anvil-config.json");
    let interopChainIds: number[] | undefined;
    if (fs.existsSync(configPath)) {
      const config: AnvilConfig = JSON.parse(fs.readFileSync(configPath, "utf-8"));
      interopChainIds = this.computeInteropChainIds(chainId, config);
    }

    const useGenesisUpgradeDeployer = process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE !== "0";
    if (useGenesisUpgradeDeployer) {
      if (!genesisPriorityTx) {
        throw new Error(
          `Genesis priority tx required for chain ${chainId} when using L2GenesisUpgrade deployer. ` +
            "Ensure registerChainBatch() captured the NewPriorityRequest events."
        );
      }
      console.log("   Using real genesis upgrade (relaying L1 priority tx)");
      const deployer = new L2GenesisUpgradeDeployer(l2RpcUrl);
      await deployer.deployAllSystemContracts(chainId, genesisPriorityTx, interopChainIds);
    } else {
      console.log("   Using direct SystemContractsDeployer path");
      const deployer = new SystemContractsDeployer(l2RpcUrl, this.privateKey, this.l1Addresses.l1SharedBridge);
      await deployer.deployAllSystemContracts(chainId, interopChainIds);
    }

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
