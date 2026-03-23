import { Contract, providers } from "ethers";
import { relayTx } from "../core/utils";
import { getAbi, getBytecode } from "../core/contracts";
import { PREDEPLOY_SYSTEM_CONTRACTS } from "../core/predeploys";
import type { SystemContractPredeploy } from "../core/predeploys";
import { INITIAL_BASE_TOKEN_HOLDER_BALANCE, L1_CHAIN_ID, L2_BASE_TOKEN_ADDR, SYSTEM_CONTEXT_ADDR } from "../core/const";
import type { PriorityRequestData } from "../core/types";
import { setSettlementLayerViaBootloader } from "../helpers/harness-shims";

const systemContextAbi = getAbi("SystemContext");

/**
 * Deployer that initializes L2 contracts by relaying the real genesis upgrade
 * transaction emitted on L1 during chain registration.
 *
 * The flow:
 * 1. Bootstrap synthetic prestate via Anvil RPC (production has this in genesis)
 * 2. Relay the real genesis upgrade transaction from the L1 GenesisUpgrade event
 * 3. Verify the deployed code is non-empty
 */
export class L2GenesisUpgradeDeployer {
  private l2Provider: providers.JsonRpcProvider;

  constructor(l2RpcUrl: string) {
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  }

  private async bootstrapSystemContractPrestate(contractSpec: SystemContractPredeploy): Promise<void> {
    const existingCode = await this.l2Provider.getCode(contractSpec.address);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      // Note: only checks code is non-empty; does not verify it matches the expected bytecode.
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

  private async bootstrapPrestateContracts(): Promise<void> {
    await Promise.all(
      PREDEPLOY_SYSTEM_CONTRACTS.map((contractSpec) => this.bootstrapSystemContractPrestate(contractSpec))
    );
  }

  private async relayGenesisPriorityTx(genesisTx: PriorityRequestData): Promise<void> {
    console.log(`   Relaying genesis tx: from=${genesisTx.from} to=${genesisTx.to}`);

    const result = await relayTx(this.l2Provider, genesisTx.from, genesisTx.to, genesisTx.calldata, genesisTx.value);
    if (!result.success) {
      throw new Error(
        `Genesis upgrade tx failed on L2. Debug: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`
      );
    }

    console.log(`   ✅ Genesis upgrade relayed: cast run ${result.txHash} -r ${this.l2Provider.connection.url}`);
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

  private async initializeSettlementLayerViaBootloader(chainId: number): Promise<void> {
    const systemContext = new Contract(SYSTEM_CONTEXT_ADDR, systemContextAbi, this.l2Provider);
    const currentSettlementLayerChainId = await systemContext.currentSettlementLayerChainId();
    if (currentSettlementLayerChainId.eq(L1_CHAIN_ID)) {
      console.log(`   Settlement layer already initialized to L1 for chain ${chainId}`);
      return;
    }

    await setSettlementLayerViaBootloader({
      provider: this.l2Provider,
      settlementLayerChainId: L1_CHAIN_ID,
    });
    console.log(`   Initialized settlement layer to L1 for chain ${chainId}`);
  }

  async deployAllSystemContracts(chainId: number, genesisPriorityTx: PriorityRequestData): Promise<void> {
    console.log(`\n🔧 Deploying system contracts for chain ${chainId} via real genesis upgrade...`);
    await this.bootstrapPrestateContracts();

    console.log("   Bootstrapping L2BaseToken balance for initL2() → BaseTokenHolder transfer...");
    await this.l2Provider.send("anvil_setBalance", [L2_BASE_TOKEN_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE]);

    await this.relayGenesisPriorityTx(genesisPriorityTx);
    await this.initializeSettlementLayerViaBootloader(chainId);

    console.log("   Verifying deployment...");
    await this.assertPostDeploymentCode();
    console.log(`✅ Genesis upgrade deployment completed for chain ${chainId}`);
  }
}
