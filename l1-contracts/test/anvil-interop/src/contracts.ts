/**
 * Centralized contract artifact loading.
 *
 * All loadAbiFromOut / loadBytecodeFromOut calls should go through this module
 * so artifact paths are defined in one place and typos are caught at compile time.
 */
import { loadAbiFromOut, loadBytecodeFromOut } from "./utils";

// ── ABIs ────────────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function gwAssetTrackerAbi(): any[] {
  // V31-only: GWAssetTracker doesn't exist in v29.
  return [];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l2BridgehubAbi(): any[] {
  return loadAbiFromOut("Bridgehub.sol/Bridgehub.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function interopCenterAbi(): any[] {
  // V31-only: InteropCenter doesn't exist in v29. Return empty ABI.
  return [];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1AssetTrackerAbi(): any[] {
  // V31-only: L1AssetTracker doesn't exist in v29. Return empty ABI.
  return [];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1BridgehubAbi(): any[] {
  return loadAbiFromOut("Bridgehub.sol/Bridgehub.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function il1BridgehubAbi(): any[] {
  return loadAbiFromOut("IBridgehub.sol/IBridgehub.json");
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
  // V31-only: L2AssetTracker doesn't exist in v29. Return empty ABI.
  return [];
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
  // V31-only: InteropHandler doesn't exist in v29. Return empty ABI.
  return [];
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
  return loadAbiFromOut("MessageRoot.sol/MessageRoot.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function mailboxFacetAbi(): any[] {
  return loadAbiFromOut("Mailbox.sol/MailboxFacet.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function systemContextAbi(): any[] {
  return loadAbiFromOut("MockSystemContext.sol/MockSystemContext.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function ownable2StepAbi(): any[] {
  return loadAbiFromOut("Ownable2Step.sol/Ownable2Step.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function dummyL1MessageRootAbi(): any[] {
  return loadAbiFromOut("MessageRoot.sol/MessageRoot.json");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function migratorFacetAbi(): any[] {
  // V31-only: Migrator doesn't exist in v29. Return empty ABI.
  return [];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function l1NullifierAbi(): any[] {
  return loadAbiFromOut("L1Nullifier.sol/L1Nullifier.json");
}

// ── Bytecodes ───────────────────────────────────────────────────

export function l2NativeTokenVaultDevBytecode(): string {
  return loadBytecodeFromOut("L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json");
}
