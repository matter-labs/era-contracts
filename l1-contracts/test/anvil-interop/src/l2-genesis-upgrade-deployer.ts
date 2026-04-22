import * as path from "path";
import { Contract, providers, utils } from "ethers";
import {
  buildAdditionalForceDeploymentsData,
  buildFixedForceDeploymentsData,
  getBytecodeInfo,
} from "./l2-genesis-helper";
import { impersonateAndRun, loadBytecodeFromOut } from "./utils";
import { encodeNtvAssetId } from "./data-encoding";
import { l2ComplexUpgraderAbi, l2GenesisUpgradeAbi, l2BridgehubAbi } from "./contracts";
import {
  ETH_TOKEN_ADDRESS,
  L1_CHAIN_ID,
  L2_ASSET_ROUTER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
  L2_GENESIS_UPGRADE_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_NTV_BEACON_DEPLOYER_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
  SERVICE_TX_SENDER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "./const";

interface PredeployedContractSpec {
  address: string;
  name: string;
  artifactPath: string;
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
const INTEROP_TEST_CHAIN_IDS = [10, 11, 12, 13];

const PREDEPLOY_CONTRACTS: PredeployedContractSpec[] = [
  {
    address: SYSTEM_CONTEXT_ADDR,
    name: "MockSystemContext",
    artifactPath: "MockSystemContext.sol/MockSystemContext.json",
  },
  {
    address: L2_TO_L1_MESSENGER_ADDR,
    name: "MockL2ToL1Messenger",
    artifactPath: "MockL2ToL1Messenger.sol/MockL2ToL1Messenger.json",
  },
  {
    address: L2_BASE_TOKEN_ADDR,
    name: "MockL2BaseToken",
    artifactPath: "MockL2BaseToken.sol/MockL2BaseToken.json",
  },
  {
    address: L2_COMPLEX_UPGRADER_ADDR,
    name: "L2ComplexUpgrader",
    artifactPath: "L2ComplexUpgrader.sol/L2ComplexUpgrader.json",
  },
  {
    address: L2_GENESIS_UPGRADE_ADDR,
    name: "L2GenesisUpgrade",
    artifactPath: "L2GenesisUpgrade.sol/L2GenesisUpgrade.json",
  },
  {
    address: L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    name: "SystemContractProxyAdmin",
    artifactPath: "SystemContractProxyAdmin.sol/SystemContractProxyAdmin.json",
  },
  {
    address: L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
    name: "L2WrappedBaseToken",
    artifactPath: "L2WrappedBaseToken.sol/L2WrappedBaseToken.json",
  },
  {
    address: L2_NTV_BEACON_DEPLOYER_ADDR,
    name: "UpgradeableBeaconDeployer",
    artifactPath: "UpgradeableBeaconDeployer.sol/UpgradeableBeaconDeployer.json",
  },
  {
    address: L2_MESSAGE_ROOT_ADDR,
    name: "L2MessageRoot",
    artifactPath: "L2MessageRoot.sol/L2MessageRoot.json",
  },
  {
    address: L2_BRIDGEHUB_ADDR,
    name: "L2Bridgehub",
    artifactPath: "L2Bridgehub.sol/L2Bridgehub.json",
  },
  {
    address: L2_ASSET_ROUTER_ADDR,
    name: "L2AssetRouter",
    artifactPath: "L2AssetRouter.sol/L2AssetRouter.json",
  },
  {
    address: L2_NATIVE_TOKEN_VAULT_ADDR,
    name: "L2NativeTokenVaultDev",
    artifactPath: "L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json",
  },
  {
    address: L2_CHAIN_ASSET_HANDLER_ADDR,
    name: "L2ChainAssetHandler",
    artifactPath: "L2ChainAssetHandler.sol/L2ChainAssetHandler.json",
  },
  {
    address: L2_MESSAGE_VERIFICATION_ADDR,
    name: "MockL2MessageVerification",
    artifactPath: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  },
];

/**
 * Alternative deployer that initializes L2 contracts through L2GenesisUpgrade.
 *
 * The flow emulates the real upgrade path:
 * - call L2ComplexUpgrader.upgrade(...)
 * - delegatecall into L2GenesisUpgrade.genesisUpgrade(...)
 *
 * This keeps `msg.sender` as L2ComplexUpgrader for system `onlyUpgrader` guards.
 */
export class L2GenesisUpgradeDeployer {
  private l2Provider: providers.JsonRpcProvider;
  private contractsRoot: string;
  private ctmDeployerAddress: string;
  private l1AssetRouterAddress: string;
  private governanceAddress: string;
  private l1ChainId: number;

  constructor(
    l2RpcUrl: string,
    _privateKey: string,
    l1AssetRouterAddress: string,
    ctmDeployerAddress: string,
    governanceAddress: string,
    l1ChainId: number = L1_CHAIN_ID
  ) {
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    this.contractsRoot = path.resolve(__dirname, "../../../..");
    this.l1AssetRouterAddress = l1AssetRouterAddress;
    this.ctmDeployerAddress = ctmDeployerAddress;
    this.governanceAddress = governanceAddress;
    this.l1ChainId = l1ChainId;
  }

  private async ensureSystemContract(address: string, artifactPath: string, name: string): Promise<void> {
    const bytecode = loadBytecodeFromOut(artifactPath);
    if (!bytecode || bytecode === "0x") {
      throw new Error(`No bytecode found for ${name} at ${artifactPath}`);
    }

    // Always deploy — anvil-zksync pre-populates system addresses with built-in stubs
    // that lack functions added in later protocol versions (e.g. L2ComplexUpgrader's
    // forceDeployAndUpgradeUniversal). Overwrite with the correct l1-contracts bytecode.
    await this.l2Provider.send("anvil_setCode", [address, bytecode]);
    console.log(`   ✅ ${name} deployed at ${address}`);
  }

  private async ensurePredeployedContracts(): Promise<void> {
    await Promise.all(
      PREDEPLOY_CONTRACTS.map((contractSpec) =>
        this.ensureSystemContract(contractSpec.address, contractSpec.artifactPath, contractSpec.name)
      )
    );
  }

  private async callGenesisUpgradeViaComplexUpgrader(
    chainId: number,
    fixedData: string,
    additionalData: string
  ): Promise<void> {
    const l2ComplexUpgraderAbiData = l2ComplexUpgraderAbi();
    const l2GenesisUpgradeAbiData = l2GenesisUpgradeAbi();
    const l2GenesisUpgradeInterface = new utils.Interface(l2GenesisUpgradeAbiData);
    const genesisUpgradeCalldata = l2GenesisUpgradeInterface.encodeFunctionData("genesisUpgrade", [
      true,
      chainId,
      this.ctmDeployerAddress,
      fixedData,
      additionalData,
    ]);

    await impersonateAndRun(this.l2Provider, L2_FORCE_DEPLOYER_ADDR, async (forceDeployerSigner) => {
      const l2ComplexUpgrader = new Contract(L2_COMPLEX_UPGRADER_ADDR, l2ComplexUpgraderAbiData, forceDeployerSigner);

      console.log("   Running L2ComplexUpgrader.upgrade(...L2GenesisUpgrade.genesisUpgrade)");
      const tx = await l2ComplexUpgrader.upgrade(L2_GENESIS_UPGRADE_ADDR, genesisUpgradeCalldata, {
        gasLimit: 30_000_000,
      });
      await tx.wait();
      console.log("   ✅ L2GenesisUpgrade executed via L2ComplexUpgrader");
    });
  }

  private async assertCodePresent(address: string, name: string): Promise<void> {
    const code = await this.l2Provider.getCode(address);
    if (code === "0x" || code === "0x0") {
      throw new Error(`Missing deployed bytecode at ${address} (${name})`);
    }
  }

  private async assertPostDeploymentCode(): Promise<void> {
    const expectedContracts: Array<{ addr: string; name: string }> = [
      { addr: L2_BRIDGEHUB_ADDR, name: "L2Bridgehub" },
      { addr: L2_ASSET_ROUTER_ADDR, name: "L2AssetRouter" },
      { addr: L2_NATIVE_TOKEN_VAULT_ADDR, name: "L2NativeTokenVault" },
      { addr: L2_MESSAGE_ROOT_ADDR, name: "L2MessageRoot" },
      { addr: L2_CHAIN_ASSET_HANDLER_ADDR, name: "L2ChainAssetHandler" },
      { addr: L2_MESSAGE_VERIFICATION_ADDR, name: "L2MessageVerification" },
    ];

    await Promise.all(expectedContracts.map((c) => this.assertCodePresent(c.addr, c.name)));
  }

  async deployAllSystemContracts(chainId: number): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId} via L2GenesisUpgrade...`);

    const bytecodeInfo = getBytecodeInfo(this.contractsRoot);
    const fixedData = buildFixedForceDeploymentsData(
      chainId,
      this.l1AssetRouterAddress,
      bytecodeInfo,
      this.governanceAddress,
      this.l1ChainId
    );
    const additionalData = buildAdditionalForceDeploymentsData(ETH_TOKEN_ADDRESS);

    await this.ensurePredeployedContracts();
    await this.callGenesisUpgradeViaComplexUpgrader(chainId, fixedData, additionalData);
    await this.assertPostDeploymentCode();

    console.log(`✅ L2GenesisUpgrade deployment flow completed for chain ${chainId}`);
  }
}
