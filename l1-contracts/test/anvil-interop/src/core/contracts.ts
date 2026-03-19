/**
 * Centralized contract artifact loading.
 *
 * All ABI / bytecode access goes through this module so artifact paths are
 * defined in one place and typos are caught at compile time.
 */

/* eslint-disable @typescript-eslint/no-explicit-any -- ABIs are untyped JSON arrays */

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
import { loadAbiFromOut, loadBytecodeFromOut, loadCreationBytecodeFromOut } from "./artifacts";

// ── Artifact path registry ──────────────────────────────────────
//
// Each entry maps a logical contract name to its forge artifact path.
// Adding a new contract is a one-liner here; getAbi/getBytecode/getCreationBytecode
// derive everything from the path.

const ARTIFACTS = {
  AdminFacet: "Admin.sol/AdminFacet.json",
  BaseTokenHolder: "BaseTokenHolder.sol/BaseTokenHolder.json",
  ChainAdminOwnable: "ChainAdminOwnable.sol/ChainAdminOwnable.json",
  GettersFacet: "Getters.sol/GettersFacet.json",
  GWAssetTracker: "GWAssetTracker.sol/GWAssetTracker.json",
  IBaseToken: "IBaseToken.sol/IBaseToken.json",
  IL1Bridgehub: "IL1Bridgehub.sol/IL1Bridgehub.json",
  IL1GenesisUpgrade: "IL1GenesisUpgrade.sol/IL1GenesisUpgrade.json",
  IL2AssetRouter: "IL2AssetRouter.sol/IL2AssetRouter.json",
  InteropCenter: "InteropCenter.sol/InteropCenter.json",
  InteropHandler: "InteropHandler.sol/InteropHandler.json",
  L1AssetRouter: "L1AssetRouter.sol/L1AssetRouter.json",
  L1MessengerZKOS: "L1MessengerZKOS.sol/L1MessengerZKOS.json",
  L1AssetTracker: "L1AssetTracker.sol/L1AssetTracker.json",
  L1Bridgehub: "L1Bridgehub.sol/L1Bridgehub.json",
  L1NativeTokenVault: "L1NativeTokenVault.sol/L1NativeTokenVault.json",
  L1Nullifier: "L1Nullifier.sol/L1Nullifier.json",
  L2AssetRouter: "L2AssetRouter.sol/L2AssetRouter.json",
  L2AssetTracker: "L2AssetTracker.sol/L2AssetTracker.json",
  L2BaseTokenZKOS: "L2BaseTokenZKOS.sol/L2BaseTokenZKOS.json",
  L2Bridgehub: "L2Bridgehub.sol/L2Bridgehub.json",
  L2ChainAssetHandler: "L2ChainAssetHandler.sol/L2ChainAssetHandler.json",
  L2ComplexUpgrader: "L2ComplexUpgrader.sol/L2ComplexUpgrader.json",
  L2GenesisUpgrade: "L2GenesisUpgrade.sol/L2GenesisUpgrade.json",
  L2MessageRoot: "L2MessageRoot.sol/L2MessageRoot.json",
  L2NativeTokenVault: "L2NativeTokenVault.sol/L2NativeTokenVault.json",
  L2NativeTokenVaultDev: "L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json",
  L2NativeTokenVaultZKOS: "L2NativeTokenVaultZKOS.sol/L2NativeTokenVaultZKOS.json",
  L2WrappedBaseToken: "L2WrappedBaseToken.sol/L2WrappedBaseToken.json",
  MailboxFacet: "Mailbox.sol/MailboxFacet.json",
  MigratorFacet: "Migrator.sol/MigratorFacet.json",
  MockL1MessengerHook: "MockL1MessengerHook.sol/MockL1MessengerHook.json",
  MockL2MessageVerification: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  MockMintBaseTokenHook: "MockMintBaseTokenHook.sol/MockMintBaseTokenHook.json",
  MockSystemContext: "MockSystemContext.sol/MockSystemContext.json",
  Ownable2Step: "Ownable2Step.sol/Ownable2Step.json",
  SystemContractProxyAdmin: "SystemContractProxyAdmin.sol/SystemContractProxyAdmin.json",
  SystemContext: "SystemContext.sol/SystemContext.json",
  TestnetERC20Token: "TestnetERC20Token.sol/TestnetERC20Token.json",
  UpgradeableBeaconDeployer: "UpgradeableBeaconDeployer.sol/UpgradeableBeaconDeployer.json",
} as const;

export type ContractName = keyof typeof ARTIFACTS;

export interface SystemContractPredeploy {
  address: string;
  contractName: ContractName;
  category: "mock" | "infrastructure" | "real";
}

// Source of truth for the Anvil interop harness predeploy layout.
export const PREDEPLOY_SYSTEM_CONTRACTS: readonly SystemContractPredeploy[] = [
  { address: SYSTEM_CONTEXT_ADDR, contractName: "MockSystemContext", category: "mock" },
  { address: L2_TO_L1_MESSENGER_ADDR, contractName: "L1MessengerZKOS", category: "mock" },
  { address: L2_BASE_TOKEN_ADDR, contractName: "L2BaseTokenZKOS", category: "mock" },
  { address: L2_MESSAGE_VERIFICATION_ADDR, contractName: "MockL2MessageVerification", category: "mock" },
  { address: L1_MESSENGER_HOOK_ADDR, contractName: "MockL1MessengerHook", category: "mock" },
  { address: MINT_BASE_TOKEN_HOOK_ADDR, contractName: "MockMintBaseTokenHook", category: "mock" },
  { address: L2_COMPLEX_UPGRADER_ADDR, contractName: "L2ComplexUpgrader", category: "infrastructure" },
  { address: L2_GENESIS_UPGRADE_ADDR, contractName: "L2GenesisUpgrade", category: "infrastructure" },
  {
    address: L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    contractName: "SystemContractProxyAdmin",
    category: "infrastructure",
  },
  { address: L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, contractName: "L2WrappedBaseToken", category: "infrastructure" },
  {
    address: L2_NTV_BEACON_DEPLOYER_ADDR,
    contractName: "UpgradeableBeaconDeployer",
    category: "infrastructure",
  },
  { address: L2_MESSAGE_ROOT_ADDR, contractName: "L2MessageRoot", category: "real" },
  { address: L2_BRIDGEHUB_ADDR, contractName: "L2Bridgehub", category: "real" },
  { address: L2_ASSET_ROUTER_ADDR, contractName: "L2AssetRouter", category: "real" },
  { address: L2_NATIVE_TOKEN_VAULT_ADDR, contractName: "L2NativeTokenVaultZKOS", category: "real" },
  { address: L2_CHAIN_ASSET_HANDLER_ADDR, contractName: "L2ChainAssetHandler", category: "real" },
  { address: L2_ASSET_TRACKER_ADDR, contractName: "L2AssetTracker", category: "real" },
  { address: GW_ASSET_TRACKER_ADDR, contractName: "GWAssetTracker", category: "real" },
  { address: L2_BASE_TOKEN_HOLDER_ADDR, contractName: "BaseTokenHolder", category: "real" },
  { address: INTEROP_CENTER_ADDR, contractName: "InteropCenter", category: "real" },
  { address: L2_INTEROP_HANDLER_ADDR, contractName: "InteropHandler", category: "real" },
] as const;

// ── Generic loaders ─────────────────────────────────────────────

export function getAbi(name: ContractName): any[] {
  return loadAbiFromOut(ARTIFACTS[name]);
}

export function getBytecode(name: ContractName): string {
  return loadBytecodeFromOut(ARTIFACTS[name]);
}

export function getCreationBytecode(name: ContractName): string {
  return loadCreationBytecodeFromOut(ARTIFACTS[name]);
}
