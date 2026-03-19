import { ethers, providers } from "ethers";
import { impersonateAndRun, relayTx } from "../core/utils";
import { encodeNtvAssetId } from "../core/data-encoding";
import type { SystemContractPredeploy } from "../core/contracts";
import { getAbi, getBytecode, PREDEPLOY_SYSTEM_CONTRACTS } from "../core/contracts";
import {
  ETH_TOKEN_ADDRESS,
  INITIAL_BASE_TOKEN_HOLDER_BALANCE,
  L1_CHAIN_ID,
  L2_BASE_TOKEN_ADDR,
  L2_BRIDGEHUB_ADDR,
  SERVICE_TX_SENDER_ADDR,
} from "../core/const";
import type { PriorityRequestData } from "../core/types";

const INTEROP_TEST_CHAIN_IDS = [10, 11, 12, 13];

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

  private async ensureSystemContract(contractSpec: SystemContractPredeploy): Promise<void> {
    const existingCode = await this.l2Provider.getCode(contractSpec.address);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ ${contractSpec.contractName} already deployed at ${contractSpec.address}`);
      return;
    }

    const bytecode = getBytecode(contractSpec.contractName);
    if (!bytecode || bytecode === "0x") {
      throw new Error(`No bytecode found for ${contractSpec.contractName}`);
    }

    console.log(`   Deploying ${contractSpec.contractName} at ${contractSpec.address}...`);
    await this.l2Provider.send("anvil_setCode", [contractSpec.address, bytecode]);
    console.log(`   ✅ ${contractSpec.contractName} deployed`);
  }

  private async ensurePredeployedContracts(): Promise<void> {
    await Promise.all(PREDEPLOY_SYSTEM_CONTRACTS.map((contractSpec) => this.ensureSystemContract(contractSpec)));
  }

  /**
   * Relay the real genesis upgrade priority transaction from L1 to L2.
   *
   * This executes the same calldata that the L1 ChainTypeManager generated
   * during createNewChain(): L2ComplexUpgrader.upgrade(L2GenesisUpgrade, genesisUpgradeCalldata)
   */
  private async relayGenesisPriorityTx(genesisTx: PriorityRequestData): Promise<void> {
    console.log(`   Relaying genesis priority tx: from=${genesisTx.from} to=${genesisTx.to}`);

    const result = await relayTx(this.l2Provider, genesisTx.from, genesisTx.to, genesisTx.calldata, genesisTx.value);

    if (!result.success) {
      throw new Error(
        `Genesis upgrade priority tx failed on L2. Debug: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`
      );
    }
    console.log(`   ✅ Genesis upgrade relayed: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`);
  }

  private async registerInteropChains(currentChainId: number, interopChainIds?: number[]): Promise<void> {
    const l2BridgehubAbiData = getAbi("L2Bridgehub");
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
    await Promise.all(
      PREDEPLOY_SYSTEM_CONTRACTS.map((contractSpec) =>
        this.assertCodePresent(contractSpec.address, contractSpec.contractName)
      )
    );
  }

  async deployAllSystemContracts(
    chainId: number,
    genesisPriorityTx: PriorityRequestData,
    interopChainIds?: number[]
  ): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId} via real genesis upgrade...`);

    // Step 1: Pre-deploy all contracts (isZKsyncOS=true skips force deploys in genesis upgrade)
    await this.ensurePredeployedContracts();

    // Step 2: Pre-fund L2BaseToken with INITIAL_BASE_TOKEN_HOLDER_BALANCE.
    // The real initL2() calls MINT_BASE_TOKEN_HOOK to mint ETH, then transfers it to BaseTokenHolder.
    // Our mock hook returns success but doesn't mint, so we pre-fund via anvil_setBalance.
    console.log("   Pre-funding L2BaseToken for initL2() → BaseTokenHolder transfer...");
    await this.l2Provider.send("anvil_setBalance", [L2_BASE_TOKEN_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE]);

    // Step 3: Relay the real genesis upgrade priority tx from L1
    await this.relayGenesisPriorityTx(genesisPriorityTx);

    // Step 3: Register interop chains (test-only shortcut, not production flow)
    await this.registerInteropChains(chainId, interopChainIds);

    // Step 4: Verify deployment
    await this.assertPostDeploymentCode();

    console.log(`✅ Genesis upgrade deployment completed for chain ${chainId}`);
  }
}
