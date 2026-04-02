/**
 * Centralized contract artifact loading.
 *
 * All ABI / bytecode access goes through this module so artifact paths are
 * defined in one place and typos are caught at compile time.
 */

import type { JsonFragment } from "@ethersproject/abi";
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
  ChainRegistrationSender: "ChainRegistrationSender.sol/ChainRegistrationSender.json",
  GettersFacet: "Getters.sol/GettersFacet.json",
  GWAssetTracker: "GWAssetTracker.sol/GWAssetTracker.json",
  IBaseToken: "IBaseToken.sol/IBaseToken.json",
  IL1Bridgehub: "IL1Bridgehub.sol/IL1Bridgehub.json",
  IL1GenesisUpgrade: "IL1GenesisUpgrade.sol/IL1GenesisUpgrade.json",
  IL2AssetRouter: "IL2AssetRouter.sol/IL2AssetRouter.json",
  InteropCenter: "InteropCenter.sol/InteropCenter.json",
  InteropHandler: "InteropHandler.sol/InteropHandler.json",
  IComplexUpgraderZKsyncOSV29: "IComplexUpgraderZKsyncOSV29.sol/IComplexUpgraderZKsyncOSV29.json",
  L1AssetRouter: "L1AssetRouter.sol/L1AssetRouter.json",
  L1MessengerZKOS: "L1MessengerZKOS.sol/L1MessengerZKOS.json",
  L1AssetTracker: "L1AssetTracker.sol/L1AssetTracker.json",
  L1Bridgehub: "L1Bridgehub.sol/L1Bridgehub.json",
  L1NativeTokenVault: "L1NativeTokenVault.sol/L1NativeTokenVault.json",
  L1Nullifier: "L1Nullifier.sol/L1Nullifier.json",
  L2AssetRouter: "L2AssetRouter.sol/L2AssetRouter.json",
  L2AssetTracker: "L2AssetTracker.sol/L2AssetTracker.json",
  L2BaseTokenEra: "L2BaseTokenEra.sol/L2BaseTokenEra.json",
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
  MockContractDeployer: "MockContractDeployer.sol/MockContractDeployer.json",
  MockSystemContractProxyAdmin: "MockSystemContractProxyAdmin.sol/MockSystemContractProxyAdmin.json",
  MockL1MessengerHook: "MockL1MessengerHook.sol/MockL1MessengerHook.json",
  MockL2MessageVerification: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  MockMintBaseTokenHook: "MockMintBaseTokenHook.sol/MockMintBaseTokenHook.json",
  Ownable2Step: "Ownable2Step.sol/Ownable2Step.json",
  EraSettlementLayerV31Upgrade: "EraSettlementLayerV31Upgrade.sol/EraSettlementLayerV31Upgrade.json",
  ZKsyncOSSettlementLayerV31Upgrade: "ZKsyncOSSettlementLayerV31Upgrade.sol/ZKsyncOSSettlementLayerV31Upgrade.json",
  SystemContractProxyAdmin: "SystemContractProxyAdmin.sol/SystemContractProxyAdmin.json",
  SystemContext: "SystemContext.sol/SystemContext.json",
  TestnetERC20Token: "TestnetERC20Token.sol/TestnetERC20Token.json",
  L2V31Upgrade: "L2V31Upgrade.sol/L2V31Upgrade.json",
  UpgradeableBeaconDeployer: "UpgradeableBeaconDeployer.sol/UpgradeableBeaconDeployer.json",
} as const;

export type ContractName = keyof typeof ARTIFACTS;

// ── Generic loaders ─────────────────────────────────────────────

export function getAbi(name: ContractName): JsonFragment[] {
  return loadAbiFromOut(ARTIFACTS[name]);
}

export function getBytecode(name: ContractName): string {
  return loadBytecodeFromOut(ARTIFACTS[name]);
}

export function getCreationBytecode(name: ContractName): string {
  return loadCreationBytecodeFromOut(ARTIFACTS[name]);
}
