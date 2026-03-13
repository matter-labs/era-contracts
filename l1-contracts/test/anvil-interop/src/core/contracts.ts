/**
 * Centralized contract artifact loading.
 *
 * All ABI / bytecode access goes through this module so artifact paths are
 * defined in one place and typos are caught at compile time.
 */

/* eslint-disable @typescript-eslint/no-explicit-any -- ABIs are untyped JSON arrays */

import { loadAbiFromOut, loadBytecodeFromOut, loadCreationBytecodeFromOut } from "./artifacts";

// ── Artifact path registry ──────────────────────────────────────
//
// Each entry maps a logical contract name to its forge artifact path.
// Adding a new contract is a one-liner here; getAbi/getBytecode/getCreationBytecode
// derive everything from the path.

const ARTIFACTS = {
  AdminFacet: "Admin.sol/AdminFacet.json",
  ChainAdminOwnable: "ChainAdminOwnable.sol/ChainAdminOwnable.json",
  GettersFacet: "Getters.sol/GettersFacet.json",
  GWAssetTracker: "GWAssetTracker.sol/GWAssetTracker.json",
  IBaseToken: "IBaseToken.sol/IBaseToken.json",
  IL1Bridgehub: "IL1Bridgehub.sol/IL1Bridgehub.json",
  IL2AssetRouter: "IL2AssetRouter.sol/IL2AssetRouter.json",
  InteropCenter: "InteropCenter.sol/InteropCenter.json",
  InteropHandler: "InteropHandler.sol/InteropHandler.json",
  L1AssetRouter: "L1AssetRouter.sol/L1AssetRouter.json",
  L1AssetTracker: "L1AssetTracker.sol/L1AssetTracker.json",
  L1Bridgehub: "L1Bridgehub.sol/L1Bridgehub.json",
  L1NativeTokenVault: "L1NativeTokenVault.sol/L1NativeTokenVault.json",
  L1Nullifier: "L1Nullifier.sol/L1Nullifier.json",
  L2AssetRouter: "L2AssetRouter.sol/L2AssetRouter.json",
  L2AssetTracker: "L2AssetTracker.sol/L2AssetTracker.json",
  L2Bridgehub: "L2Bridgehub.sol/L2Bridgehub.json",
  L2ComplexUpgrader: "L2ComplexUpgrader.sol/L2ComplexUpgrader.json",
  L2GenesisUpgrade: "L2GenesisUpgrade.sol/L2GenesisUpgrade.json",
  L2MessageRoot: "L2MessageRoot.sol/L2MessageRoot.json",
  L2NativeTokenVault: "L2NativeTokenVault.sol/L2NativeTokenVault.json",
  L2NativeTokenVaultDev: "L2NativeTokenVaultDev.sol/L2NativeTokenVaultDev.json",
  MailboxFacet: "Mailbox.sol/MailboxFacet.json",
  MigratorFacet: "Migrator.sol/MigratorFacet.json",
  Ownable2Step: "Ownable2Step.sol/Ownable2Step.json",
  PrivateInteropCenter: "PrivateInteropCenter.sol/PrivateInteropCenter.json",
  PrivateInteropHandler: "PrivateInteropHandler.sol/PrivateInteropHandler.json",
  PrivateL2AssetRouter: "PrivateL2AssetRouter.sol/PrivateL2AssetRouter.json",
  PrivateL2AssetTracker: "PrivateL2AssetTracker.sol/PrivateL2AssetTracker.json",
  PrivateL2NativeTokenVault: "PrivateL2NativeTokenVault.sol/PrivateL2NativeTokenVault.json",
  SystemContext: "SystemContext.sol/SystemContext.json",
  TestnetERC20Token: "TestnetERC20Token.sol/TestnetERC20Token.json",
} as const;

type ContractName = keyof typeof ARTIFACTS;

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

// ── Legacy named exports (thin wrappers for existing call sites) ─

export const adminFacetAbi = (): any[] => getAbi("AdminFacet");
export const chainAdminOwnableAbi = (): any[] => getAbi("ChainAdminOwnable");
export const gettersFacetAbi = (): any[] => getAbi("GettersFacet");
export const gwAssetTrackerAbi = (): any[] => getAbi("GWAssetTracker");
export const iBaseTokenAbi = (): any[] => getAbi("IBaseToken");
export const il1BridgehubAbi = (): any[] => getAbi("IL1Bridgehub");
export const il2AssetRouterAbi = (): any[] => getAbi("IL2AssetRouter");
export const interopCenterAbi = (): any[] => getAbi("InteropCenter");
export const interopHandlerAbi = (): any[] => getAbi("InteropHandler");
export const l1AssetRouterAbi = (): any[] => getAbi("L1AssetRouter");
export const l1AssetTrackerAbi = (): any[] => getAbi("L1AssetTracker");
export const l1BridgehubAbi = (): any[] => getAbi("L1Bridgehub");
export const l1NativeTokenVaultAbi = (): any[] => getAbi("L1NativeTokenVault");
export const l1NullifierAbi = (): any[] => getAbi("L1Nullifier");
export const l2AssetRouterAbi = (): any[] => getAbi("L2AssetRouter");
export const l2AssetTrackerAbi = (): any[] => getAbi("L2AssetTracker");
export const l2BridgehubAbi = (): any[] => getAbi("L2Bridgehub");
export const l2ComplexUpgraderAbi = (): any[] => getAbi("L2ComplexUpgrader");
export const l2GenesisUpgradeAbi = (): any[] => getAbi("L2GenesisUpgrade");
export const l2MessageRootAbi = (): any[] => getAbi("L2MessageRoot");
export const l2NativeTokenVaultAbi = (): any[] => getAbi("L2NativeTokenVault");
export const l2NativeTokenVaultDevAbi = (): any[] => getAbi("L2NativeTokenVaultDev");
export const mailboxFacetAbi = (): any[] => getAbi("MailboxFacet");
export const migratorFacetAbi = (): any[] => getAbi("MigratorFacet");
export const ownable2StepAbi = (): any[] => getAbi("Ownable2Step");
export const systemContextAbi = (): any[] => getAbi("SystemContext");
export const testnetERC20TokenAbi = (): any[] => getAbi("TestnetERC20Token");

export const privateInteropCenterAbi = (): any[] => getAbi("PrivateInteropCenter");
export const privateInteropHandlerAbi = (): any[] => getAbi("PrivateInteropHandler");
export const privateL2AssetRouterAbi = (): any[] => getAbi("PrivateL2AssetRouter");
export const privateL2AssetTrackerAbi = (): any[] => getAbi("PrivateL2AssetTracker");
export const privateL2NativeTokenVaultAbi = (): any[] => getAbi("PrivateL2NativeTokenVault");

export const chainAdminOwnableBytecode = (): string => getCreationBytecode("ChainAdminOwnable");
export const l2NativeTokenVaultDevBytecode = (): string => getBytecode("L2NativeTokenVaultDev");

export const privateInteropCenterBytecode = (): string => getCreationBytecode("PrivateInteropCenter");
export const privateInteropHandlerBytecode = (): string => getCreationBytecode("PrivateInteropHandler");
export const privateL2AssetRouterBytecode = (): string => getCreationBytecode("PrivateL2AssetRouter");
export const privateL2AssetTrackerBytecode = (): string => getCreationBytecode("PrivateL2AssetTracker");
export const privateL2NativeTokenVaultBytecode = (): string => getCreationBytecode("PrivateL2NativeTokenVault");
