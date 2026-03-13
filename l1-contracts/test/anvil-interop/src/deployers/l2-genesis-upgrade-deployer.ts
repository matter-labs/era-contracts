import * as path from "path";
import { ethers, Contract, providers, utils } from "ethers";
import {
  buildAdditionalForceDeploymentsData,
  buildFixedForceDeploymentsData,
  getBytecodeInfo,
} from "./l2-genesis-helper";
import { impersonateAndRun } from "../core/utils";
import { loadBytecodeFromOut } from "../core/artifacts";
import { encodeNtvAssetId } from "../core/data-encoding";
import { l2ComplexUpgraderAbi, l2GenesisUpgradeAbi, l2BridgehubAbi } from "../core/contracts";
import {
  ETH_TOKEN_ADDRESS,
  GW_ASSET_TRACKER_ADDR,
  INTEROP_CENTER_ADDR,
  L1_CHAIN_ID,
  L2_ASSET_ROUTER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BASE_TOKEN_HOLDER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
  L2_GENESIS_UPGRADE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_NTV_BEACON_DEPLOYER_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
  SERVICE_TX_SENDER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";

interface PredeployedContractSpec {
  address: string;
  name: string;
  artifactPath: string;
}

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
    name: "L2NativeTokenVaultZKOS",
    artifactPath: "L2NativeTokenVaultZKOS.sol/L2NativeTokenVaultZKOS.json",
  },
  {
    address: L2_CHAIN_ASSET_HANDLER_ADDR,
    name: "L2ChainAssetHandler",
    artifactPath: "L2ChainAssetHandler.sol/L2ChainAssetHandler.json",
  },
  {
    address: L2_ASSET_TRACKER_ADDR,
    name: "L2AssetTracker",
    artifactPath: "L2AssetTracker.sol/L2AssetTracker.json",
  },
  {
    address: GW_ASSET_TRACKER_ADDR,
    name: "GWAssetTracker",
    artifactPath: "GWAssetTracker.sol/GWAssetTracker.json",
  },
  {
    address: L2_BASE_TOKEN_HOLDER_ADDR,
    name: "BaseTokenHolder",
    artifactPath: "BaseTokenHolder.sol/BaseTokenHolder.json",
  },
  {
    address: INTEROP_CENTER_ADDR,
    name: "InteropCenter",
    artifactPath: "InteropCenter.sol/InteropCenter.json",
  },
  {
    address: L2_INTEROP_HANDLER_ADDR,
    name: "InteropHandler",
    artifactPath: "InteropHandler.sol/InteropHandler.json",
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
  private chainRegistrationSender: string;
  private gatewayChainId: number;
  private l1ChainId: number;

  constructor(
    l2RpcUrl: string,
    _privateKey: string,
    l1AssetRouterAddress: string,
    ctmDeployerAddress: string,
    governanceAddress: string,
    chainRegistrationSender: string,
    gatewayChainId: number,
    l1ChainId: number = L1_CHAIN_ID
  ) {
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    this.contractsRoot = path.resolve(__dirname, "../../../../..");
    this.l1AssetRouterAddress = l1AssetRouterAddress;
    this.ctmDeployerAddress = ctmDeployerAddress;
    this.governanceAddress = governanceAddress;
    this.chainRegistrationSender = chainRegistrationSender;
    this.gatewayChainId = gatewayChainId;
    this.l1ChainId = l1ChainId;
  }

  private async ensureSystemContract(address: string, artifactPath: string, name: string): Promise<void> {
    const existingCode = await this.l2Provider.getCode(address);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ ${name} already deployed at ${address}`);
      return;
    }

    const bytecode = loadBytecodeFromOut(artifactPath);
    if (!bytecode || bytecode === "0x") {
      throw new Error(`No bytecode found for ${name} at ${artifactPath}`);
    }

    console.log(`   Deploying ${name} at ${address}...`);
    await this.l2Provider.send("anvil_setCode", [address, bytecode]);
    console.log(`   ✅ ${name} deployed`);
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

  private async registerInteropChains(currentChainId: number, interopChainIds?: number[]): Promise<void> {
    const l2BridgehubAbiData = l2BridgehubAbi();
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbiData, this.l2Provider);
    const ethAssetId = encodeNtvAssetId(this.l1ChainId, ETH_TOKEN_ADDRESS);

    const baseChainIds = interopChainIds ?? INTEROP_TEST_CHAIN_IDS;
    const chainIds = Array.from(new Set([...baseChainIds, currentChainId, this.gatewayChainId]));

    await impersonateAndRun(this.l2Provider, SERVICE_TX_SENDER_ADDR, async (serviceTxSenderSigner) => {
      const l2BridgehubWithSigner = l2Bridgehub.connect(serviceTxSenderSigner);

      for (const chainId of chainIds) {
        const existingAssetId = await l2Bridgehub.baseTokenAssetId(chainId);
        if (existingAssetId !== ethers.constants.HashZero) {
          console.log(`   ✅ Chain ${chainId} already registered on L2Bridgehub`);
          continue;
        }

        console.log(`   Registering chain ${chainId} on L2Bridgehub...`);
        const registerTx = await l2BridgehubWithSigner.registerChainForInterop(chainId, ethAssetId);
        await registerTx.wait();
        console.log(`   ✅ Chain ${chainId} registered on L2Bridgehub`);
      }
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
      { addr: INTEROP_CENTER_ADDR, name: "InteropCenter" },
      { addr: L2_INTEROP_HANDLER_ADDR, name: "InteropHandler" },
      { addr: L2_ASSET_TRACKER_ADDR, name: "L2AssetTracker" },
      { addr: L2_MESSAGE_VERIFICATION_ADDR, name: "L2MessageVerification" },
      { addr: GW_ASSET_TRACKER_ADDR, name: "GWAssetTracker" },
      { addr: L2_BASE_TOKEN_HOLDER_ADDR, name: "BaseTokenHolder" },
    ];

    await Promise.all(expectedContracts.map((c) => this.assertCodePresent(c.addr, c.name)));
  }

  async deployAllSystemContracts(chainId: number, interopChainIds?: number[]): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId} via L2GenesisUpgrade...`);

    const bytecodeInfo = getBytecodeInfo(this.contractsRoot);
    const fixedData = buildFixedForceDeploymentsData(
      chainId,
      this.l1AssetRouterAddress,
      bytecodeInfo,
      this.gatewayChainId,
      this.governanceAddress,
      this.chainRegistrationSender,
      this.l1ChainId
    );
    const additionalData = buildAdditionalForceDeploymentsData(ETH_TOKEN_ADDRESS);

    await this.ensurePredeployedContracts();
    await this.callGenesisUpgradeViaComplexUpgrader(chainId, fixedData, additionalData);
    await this.registerInteropChains(chainId, interopChainIds);
    await this.assertPostDeploymentCode();

    console.log(`✅ L2GenesisUpgrade deployment flow completed for chain ${chainId}`);
  }
}
