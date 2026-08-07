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
  BridgedStandardERC20: "BridgedStandardERC20.sol/BridgedStandardERC20.json",
  ChainAdminOwnable: "ChainAdminOwnable.sol/ChainAdminOwnable.json",
  ChainRegistrationSender: "ChainRegistrationSender.sol/ChainRegistrationSender.json",
  DummyInteropRecipient: "DummyInteropRecipient.sol/DummyInteropRecipient.json",
  EmptyContract: "EmptyContract.sol/EmptyContract.json",
  GettersFacet: "Getters.sol/GettersFacet.json",
  IBaseToken: "IBaseToken.sol/IBaseToken.json",
  IERC7786Attributes: "IERC7786Attributes.sol/IERC7786Attributes.json",
  IL1Bridgehub: "IL1Bridgehub.sol/IL1Bridgehub.json",
  IL1GenesisUpgrade: "IL1GenesisUpgrade.sol/IL1GenesisUpgrade.json",
  IL2AssetRouter: "IL2AssetRouter.sol/IL2AssetRouter.json",
  IZKChain: "IZKChain.sol/IZKChain.json",
  InteropCenter: "InteropCenter.sol/InteropCenter.json",
  InteropAttributeParser: "InteropAttributeParser.sol/InteropAttributeParser.json",
  L2InteropHandler: "L2InteropHandler.sol/L2InteropHandler.json",
  ITransparentUpgradeableProxy: "TransparentUpgradeableProxy.sol/ITransparentUpgradeableProxy.json",
  L1AssetRouter: "L1AssetRouter.sol/L1AssetRouter.json",
  L1MessengerZKOS: "L1MessengerZKOS.sol/L1MessengerZKOS.json",
  L1Bridgehub: "L1Bridgehub.sol/L1Bridgehub.json",
  L1NativeTokenVault: "L1NativeTokenVault.sol/L1NativeTokenVault.json",
  L1Nullifier: "L1Nullifier.sol/L1Nullifier.json",
  L1InteropHandler: "L1InteropHandler.sol/L1InteropHandler.json",
  L2AssetRouter: "L2AssetRouter.sol/L2AssetRouter.json",
  L2AssetTracker: "L2AssetTracker.sol/L2AssetTracker.json",
  L2BaseTokenEra: "L2BaseTokenEra.sol/L2BaseTokenEra.json",
  L2BaseTokenZKOS: "L2BaseTokenZKOS.sol/L2BaseTokenZKOS.json",
  ZKOSContractDeployer: "ZKOSContractDeployer.sol/ZKOSContractDeployer.json",
  L2Bridgehub: "L2Bridgehub.sol/L2Bridgehub.json",
  L1ChainAssetHandler: "L1ChainAssetHandler.sol/L1ChainAssetHandler.json",
  L1ChainAssetHandlerDev: "L1ChainAssetHandlerDev.sol/L1ChainAssetHandlerDev.json",
  L2ChainAssetHandler: "L2ChainAssetHandler.sol/L2ChainAssetHandler.json",
  L2ChainAssetHandlerDev: "L2ChainAssetHandlerDev.sol/L2ChainAssetHandlerDev.json",
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
  MockL1MessengerHook: "MockL1MessengerHook.sol/MockL1MessengerHook.json",
  MockL2MessageVerification: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  MockMintBaseTokenHook: "MockMintBaseTokenHook.sol/MockMintBaseTokenHook.json",
  Ownable2Step: "Ownable2Step.sol/Ownable2Step.json",
  PriorityOpLowerBound: "PriorityOpLowerBound.sol/PriorityOpLowerBound.json",
  ProxyAdmin: "ProxyAdmin.sol/ProxyAdmin.json",
  DefaultUpgradeZKsyncOS: "DefaultUpgradeZKsyncOS.sol/DefaultUpgradeZKsyncOS.json",
  V32UpgradeZKsyncOS: "V32UpgradeZKsyncOS.sol/V32UpgradeZKsyncOS.json",
  SystemContractProxy: "SystemContractProxy.sol/SystemContractProxy.json",
  SystemContractProxyAdmin: "SystemContractProxyAdmin.sol/SystemContractProxyAdmin.json",
  SystemContext: "SystemContext.sol/SystemContext.json",
  TestnetERC20Token: "TestnetERC20Token.sol/TestnetERC20Token.json",
  // Atomic interop (bundle model) — see {protocol-docs/atomicity/README.md#contracts}.
  L2InteropCommitmentTree: "L2InteropCommitmentTree.sol/L2InteropCommitmentTree.json",
  AtomicFlowManager: "AtomicFlowManager.sol/AtomicFlowManager.json",
  IAtomicFlowManager: "IAtomicFlowManager.sol/IAtomicFlowManager.json",
  L2MessageVerification: "L2MessageVerification.sol/L2MessageVerification.json",
  L2InteropRootStorage: "L2InteropRootStorage.sol/L2InteropRootStorage.json",
  L2V32Upgrade: "L2V32Upgrade.sol/L2V32Upgrade.json",
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

// ── Legacy ABIs ─────────────────────────────────────────────────
// ABIs for older contract versions that no longer exist as artifacts.
// Kept here (not inline) so every consumer imports from a single source of truth.

/**
 * Legacy AdminFacet ABI: upgradeChainFromVersion(uint256, DiamondCutData) with 2 params. The current
 * AdminFacet has upgradeChainFromVersion(address, uint256, DiamondCutData) with 3 params. Only reachable
 * from fork runs against an ecosystem that predates the third parameter; the state-dump scenarios all
 * start at v31, which already has it.
 */
export const LEGACY_ADMIN_ABI: string[] = [
  "function upgradeChainFromVersion(uint256, tuple(tuple(address,uint8,bool,bytes4[])[],address,bytes))",
];

/**
 * v31 Admin facet entry point removed in v32 (the backfill service-transaction request). The
 * harness calls it on forked v31 chains whose fixture never ran the backfill, so the current
 * AdminFacet artifact no longer carries the selector.
 */
export const LEGACY_V31_ADMIN_BACKFILL_ABI: string[] = [
  "function setZKsyncOSPreV31TotalSupply(uint256 _totalSupply) returns (bytes32)",
];
