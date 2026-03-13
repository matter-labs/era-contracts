import { providers } from "ethers";
import {
  L2_BRIDGEHUB_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  INTEROP_CENTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  GW_ASSET_TRACKER_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
} from "../core/const";

/**
 * Pre-deploy Gateway CTM contracts on the GW chain via anvil_setCode.
 *
 * In a real deployment, these would be deployed through GatewayCTMDeployerHelper
 * as part of the governance flow. For Anvil testing, we set the bytecode directly.
 *
 * The key contracts needed on the GW chain beyond the standard L2 system contracts:
 * - All L2 system contracts (already deployed during L2 init)
 * - GWAssetTracker at the well-known address (already deployed during L2 genesis)
 *
 * Since all L2 chains get the same system contracts including GWAssetTracker
 * during the genesis upgrade, the GW chain already has what it needs.
 * This module verifies that and performs any additional setup.
 */
export class GatewayDeployer {
  private gwProvider: providers.JsonRpcProvider;
  private gwChainId: number;

  constructor(gwRpcUrl: string, gwChainId: number) {
    this.gwProvider = new providers.JsonRpcProvider(gwRpcUrl);
    this.gwChainId = gwChainId;
  }

  /**
   * Verify that all required system contracts are present on the GW chain.
   */
  async verifyGatewayContracts(): Promise<void> {
    console.log(`   Verifying gateway contracts on chain ${this.gwChainId}...`);

    const contracts = [
      { addr: L2_BRIDGEHUB_ADDR, name: "L2Bridgehub" },
      { addr: L2_ASSET_ROUTER_ADDR, name: "L2AssetRouter" },
      { addr: L2_NATIVE_TOKEN_VAULT_ADDR, name: "L2NativeTokenVault" },
      { addr: L2_MESSAGE_ROOT_ADDR, name: "L2MessageRoot" },
      { addr: L2_CHAIN_ASSET_HANDLER_ADDR, name: "L2ChainAssetHandler" },
      { addr: INTEROP_CENTER_ADDR, name: "InteropCenter" },
      { addr: L2_INTEROP_HANDLER_ADDR, name: "InteropHandler" },
      { addr: L2_ASSET_TRACKER_ADDR, name: "L2AssetTracker" },
      { addr: GW_ASSET_TRACKER_ADDR, name: "GWAssetTracker" },
      { addr: L2_MESSAGE_VERIFICATION_ADDR, name: "L2MessageVerification" },
    ];

    for (const c of contracts) {
      const code = await this.gwProvider.getCode(c.addr);
      if (code === "0x" || code === "0x0") {
        throw new Error(`Missing ${c.name} at ${c.addr} on GW chain ${this.gwChainId}`);
      }
    }

    console.log(`   All gateway contracts verified on chain ${this.gwChainId}`);
  }
}
