import {
  GW_ASSET_TRACKER_ADDR,
  INTEROP_CENTER_ADDR,
  L1_MESSENGER_HOOK_ADDR,
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
  MINT_BASE_TOKEN_HOOK_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "./const";
import type { ContractName } from "./contracts";

export interface SystemContractPredeploy {
  address: string;
  contractName: ContractName;
}

// Source of truth for the Anvil interop harness predeploy layout.
export const PREDEPLOY_SYSTEM_CONTRACTS: readonly SystemContractPredeploy[] = [
  { address: SYSTEM_CONTEXT_ADDR, contractName: "MockSystemContext" },
  { address: L2_TO_L1_MESSENGER_ADDR, contractName: "L1MessengerZKOS" },
  { address: L2_BASE_TOKEN_ADDR, contractName: "L2BaseTokenZKOS" },
  { address: L2_MESSAGE_VERIFICATION_ADDR, contractName: "MockL2MessageVerification" },
  { address: L1_MESSENGER_HOOK_ADDR, contractName: "MockL1MessengerHook" },
  { address: MINT_BASE_TOKEN_HOOK_ADDR, contractName: "MockMintBaseTokenHook" },
  { address: L2_COMPLEX_UPGRADER_ADDR, contractName: "L2ComplexUpgrader" },
  { address: L2_GENESIS_UPGRADE_ADDR, contractName: "L2GenesisUpgrade" },
  { address: L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, contractName: "SystemContractProxyAdmin" },
  { address: L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, contractName: "L2WrappedBaseToken" },
  { address: L2_NTV_BEACON_DEPLOYER_ADDR, contractName: "UpgradeableBeaconDeployer" },
  { address: L2_MESSAGE_ROOT_ADDR, contractName: "L2MessageRoot" },
  { address: L2_BRIDGEHUB_ADDR, contractName: "L2Bridgehub" },
  { address: L2_ASSET_ROUTER_ADDR, contractName: "L2AssetRouter" },
  { address: L2_NATIVE_TOKEN_VAULT_ADDR, contractName: "L2NativeTokenVaultZKOS" },
  { address: L2_CHAIN_ASSET_HANDLER_ADDR, contractName: "L2ChainAssetHandler" },
  { address: L2_ASSET_TRACKER_ADDR, contractName: "L2AssetTracker" },
  { address: GW_ASSET_TRACKER_ADDR, contractName: "GWAssetTracker" },
  { address: L2_BASE_TOKEN_HOLDER_ADDR, contractName: "BaseTokenHolder" },
  { address: INTEROP_CENTER_ADDR, contractName: "InteropCenter" },
  { address: L2_INTEROP_HANDLER_ADDR, contractName: "InteropHandler" },
] as const;
