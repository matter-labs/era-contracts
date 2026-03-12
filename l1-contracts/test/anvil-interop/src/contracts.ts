/**
 * Centralized contract artifact loading.
 *
 * All loadAbiFromOut / loadBytecodeFromOut calls should go through this module
 * so artifact paths are defined in one place and typos are caught at compile time.
 *
 * TODO: Replace individual functions with a generic approach based on contract name strings,
 * e.g. getAbi("ChainAdminOwnable"), getBytecode("ChainAdminOwnable"), getInterface("ChainAdminOwnable").
 * Store the valid contract names as constants and derive artifact paths from them.
 *
 * TODO: Replace individual functions with a generic approach based on contract name strings,
 * e.g. getAbi("ChainAdminOwnable"), getBytecode("ChainAdminOwnable"), getInterface("ChainAdminOwnable").
 * Store the valid contract names as constants and derive artifact paths from them.
 */
import { loadAbiFromOut, loadBytecodeFromOut, loadCreationBytecodeFromOut } from "./utils";

// ── ABIs ────────────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function gwAssetTrackerAbi(): any[] {
  return loadAbiFromOut("GWAssetTracker.sol/GWAssetTracker.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2BridgehubAbi(): any[] {
  return loadAbiFromOut("L2Bridgehub.sol/L2Bridgehub.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function interopCenterAbi(): any[] {
  return loadAbiFromOut("InteropCenter.sol/InteropCenter.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1AssetTrackerAbi(): any[] {
  return loadAbiFromOut("L1AssetTracker.sol/L1AssetTracker.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1BridgehubAbi(): any[] {
  return loadAbiFromOut("L1Bridgehub.sol/L1Bridgehub.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function il1BridgehubAbi(): any[] {
  return loadAbiFromOut("IL1Bridgehub.sol/IL1Bridgehub.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2AssetRouterAbi(): any[] {
  return loadAbiFromOut("L2AssetRouter.sol/L2AssetRouter.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2NativeTokenVaultAbi(): any[] {
  return loadAbiFromOut("L2NativeTokenVault.sol/L2NativeTokenVault.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2NativeTokenVaultDevAbi(): any[] {
  return loadAbiFromOut("L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2AssetTrackerAbi(): any[] {
  return loadAbiFromOut("L2AssetTracker.sol/L2AssetTracker.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function executorFacetAbi(): any[] {
  return loadAbiFromOut("Executor.sol/ExecutorFacet.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1NativeTokenVaultAbi(): any[] {
  return loadAbiFromOut("L1NativeTokenVault.sol/L1NativeTokenVault.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function testnetERC20TokenAbi(): any[] {
  return loadAbiFromOut("TestnetERC20Token.sol/TestnetERC20Token.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1AssetRouterAbi(): any[] {
  return loadAbiFromOut("L1AssetRouter.sol/L1AssetRouter.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function interopHandlerAbi(): any[] {
  return loadAbiFromOut("InteropHandler.sol/InteropHandler.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2ComplexUpgraderAbi(): any[] {
  return loadAbiFromOut("L2ComplexUpgrader.sol/L2ComplexUpgrader.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2GenesisUpgradeAbi(): any[] {
  return loadAbiFromOut("L2GenesisUpgrade.sol/L2GenesisUpgrade.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2MessageRootAbi(): any[] {
  return loadAbiFromOut("L2MessageRoot.sol/L2MessageRoot.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function mailboxFacetAbi(): any[] {
  return loadAbiFromOut("Mailbox.sol/MailboxFacet.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function systemContextAbi(): any[] {
  return loadAbiFromOut("SystemContext.sol/SystemContext.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function ownable2StepAbi(): any[] {
  return loadAbiFromOut("Ownable2Step.sol/Ownable2Step.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function migratorFacetAbi(): any[] {
  return loadAbiFromOut("Migrator.sol/MigratorFacet.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1NullifierAbi(): any[] {
  return loadAbiFromOut("L1Nullifier.sol/L1Nullifier.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function chainAdminOwnableAbi(): any[] {
  return loadAbiFromOut("ChainAdminOwnable.sol/ChainAdminOwnable.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function iBaseTokenAbi(): any[] {
  return loadAbiFromOut("IBaseToken.sol/IBaseToken.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function gettersFacetAbi(): any[] {
  return loadAbiFromOut("Getters.sol/GettersFacet.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function adminFacetAbi(): any[] {
  return loadAbiFromOut("Admin.sol/AdminFacet.json");
}

// ── Bytecodes ───────────────────────────────────────────────────

export function chainAdminOwnableBytecode(): string {
  return loadCreationBytecodeFromOut("ChainAdminOwnable.sol/ChainAdminOwnable.json");
}

export function l2NativeTokenVaultDevBytecode(): string {
  return loadBytecodeFromOut("L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json");
}
