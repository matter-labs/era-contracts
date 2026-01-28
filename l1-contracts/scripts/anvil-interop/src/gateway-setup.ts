import { JsonRpcProvider, Contract, Wallet } from "ethers";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "./types";

export class GatewaySetup {
  private l1Provider: JsonRpcProvider;
  private wallet: Wallet;
  private l1Addresses: CoreDeployedAddresses;
  private ctmAddresses: CTMDeployedAddresses;

  constructor(
    l1RpcUrl: string,
    privateKey: string,
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ) {
    this.l1Provider = new JsonRpcProvider(l1RpcUrl);
    this.wallet = new Wallet(privateKey, this.l1Provider);
    this.l1Addresses = l1Addresses;
    this.ctmAddresses = ctmAddresses;
  }

  async designateAsGateway(_chainId: number): Promise<string> {
    console.log(`🌐 Gateway setup for Anvil test environment...`);

    // For the Anvil test environment, we skip gateway setup
    // Real gateway setup requires zkstack CLI commands:
    // - zkstack chain gateway create-tx-filterer --chain gateway
    // - zkstack chain gateway convert-to-gateway --chain gateway
    //
    // These commands:
    // 1. Deploy and configure GatewayTransactionFilterer contract
    // 2. Upgrade the chain diamond proxy with gateway facets
    // 3. Configure gateway-specific storage and settings
    //
    // In the simplified Anvil environment:
    // - We don't have zkstack CLI available
    // - Gateway functionality is not required for basic interop testing
    // - All chains use the shared CTM for communication

    const gatewayCTMAddr = this.ctmAddresses.chainTypeManager;

    console.log(`   Using existing CTM: ${gatewayCTMAddr}`);
    console.log(`   ⚠️  Gateway conversion skipped (requires zkstack CLI)`);
    console.log(`   ℹ️  For full gateway setup, use: zkstack chain gateway convert-to-gateway`);
    console.log(`✅ Gateway setup complete (simplified for Anvil testing)`);

    return gatewayCTMAddr;
  }
}
