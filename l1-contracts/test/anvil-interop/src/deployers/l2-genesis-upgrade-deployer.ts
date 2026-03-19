import { ethers, providers } from "ethers";
import { impersonateAndRun, relayTx } from "../core/utils";
import { loadBytecodeFromOut } from "../core/artifacts";
import { encodeNtvAssetId } from "../core/data-encoding";
import { l2BridgehubAbi } from "../core/contracts";
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
import type { PriorityRequestData } from "../core/types";

interface PredeployedContractSpec {
  address: string;
  name: string;
  artifactPath: string;
}

const INTEROP_TEST_CHAIN_IDS = [10, 11, 12, 13];

/**
 * Contracts that must be pre-deployed via anvil_setCode before the genesis upgrade runs.
 *
 * The genesis upgrade (with isZKsyncOS=true) skips force deployments — it only calls
 * initL2() on each contract. So the bytecode must already be at these addresses.
 *
 * Mock contracts replace ZK-VM system contracts that can't run on standard EVM.
 * Real contracts are deployed at their system addresses for the genesis initL2() to work.
 */
const PREDEPLOY_CONTRACTS: PredeployedContractSpec[] = [
  // Mock system contracts (replace ZK-VM bytecode that can't run on Anvil)
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
    address: L2_MESSAGE_VERIFICATION_ADDR,
    name: "MockL2MessageVerification",
    artifactPath: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  },
  // Infrastructure contracts needed before/during genesis upgrade execution
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
  // Real L2 system contracts — genesis initL2() runs on these
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
];

/**
 * Deployer that initializes L2 contracts by relaying the real genesis upgrade priority
 * transaction from L1.
 *
 * The flow:
 * 1. Pre-deploy all contracts via anvil_setCode (isZKsyncOS=true skips force deploys)
 * 2. Relay the genesis priority tx extracted from L1's NewPriorityRequest event
 *    → L2ComplexUpgrader.upgrade() → L2GenesisUpgrade.genesisUpgrade()
 *    → initializes all contracts via their initL2() methods
 * 3. Register interop chains on L2Bridgehub (test-only shortcut)
 */
export class L2GenesisUpgradeDeployer {
  private l2Provider: providers.JsonRpcProvider;

  constructor(l2RpcUrl: string) {
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
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

  /**
   * Relay the real genesis upgrade priority transaction from L1 to L2.
   *
   * This executes the same calldata that the L1 ChainTypeManager generated
   * during createNewChain(): L2ComplexUpgrader.upgrade(L2GenesisUpgrade, genesisUpgradeCalldata)
   */
  private async relayGenesisPriorityTx(genesisTx: PriorityRequestData): Promise<void> {
    console.log(`   Relaying genesis priority tx: from=${genesisTx.from} to=${genesisTx.to}`);

    const result = await relayTx(
      this.l2Provider,
      genesisTx.from,
      genesisTx.to,
      genesisTx.calldata,
      genesisTx.value
    );

    if (!result.success) {
      throw new Error(
        `Genesis upgrade priority tx failed on L2. ` +
          `Debug: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`
      );
    }
    console.log(`   ✅ Genesis upgrade relayed: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`);
  }

  private async registerInteropChains(currentChainId: number, interopChainIds?: number[]): Promise<void> {
    const l2BridgehubAbiData = l2BridgehubAbi();
    const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbiData, this.l2Provider);
    const ethAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

    const baseChainIds = interopChainIds ?? INTEROP_TEST_CHAIN_IDS;
    const chainIds = Array.from(new Set([...baseChainIds, currentChainId]));

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

  async deployAllSystemContracts(
    chainId: number,
    genesisPriorityTx: PriorityRequestData,
    interopChainIds?: number[]
  ): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId} via real genesis upgrade...`);

    // Step 1: Pre-deploy all contracts (isZKsyncOS=true skips force deploys in genesis upgrade)
    await this.ensurePredeployedContracts();

    // Step 2: Relay the real genesis upgrade priority tx from L1
    await this.relayGenesisPriorityTx(genesisPriorityTx);

    // Step 3: Register interop chains (test-only shortcut, not production flow)
    await this.registerInteropChains(chainId, interopChainIds);

    // Step 4: Verify deployment
    await this.assertPostDeploymentCode();

    console.log(`✅ Genesis upgrade deployment completed for chain ${chainId}`);
  }
}
