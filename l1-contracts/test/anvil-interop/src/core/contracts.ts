/**
 * Centralized contract artifact loading.
 *
 * All ABI / bytecode access goes through this module so artifact paths are
 * defined in one place and typos are caught at compile time.
 */

import type { JsonFragment } from "@ethersproject/abi";
import * as path from "path";
import {
  loadAbiFromOut,
  loadBytecodeFromOut,
  loadCreationBytecodeFromOut,
  loadDeterministicBytecodeFromOut,
  loadDeterministicCreationBytecodeFromOut,
} from "./artifacts";

// ── Artifact path registry ──────────────────────────────────────
//
// Each entry maps a logical contract name to its forge artifact path.
// Adding a new contract is a one-liner here; getAbi/getBytecode/getCreationBytecode
// derive everything from the path.

const ARTIFACTS = {
  AdminFacet: "Admin.sol/AdminFacet.json",
  BaseTokenHolder: "BaseTokenHolder.sol/BaseTokenHolder.json",
  // ── Registry-driven upgrade machinery (see registry-upgrade-test-runner.ts) ──
  BytecodesSupplier: "BytecodesSupplier.sol/BytecodesSupplier.json",
  CTMUpgradeExecutor: "CTMUpgradeExecutor.sol/CTMUpgradeExecutor.json",
  CoreUpgradeExecutor: "CoreUpgradeExecutor.sol/CoreUpgradeExecutor.json",
  // The ecosystem's legacy timelock (`scheduleTransparent` + `execute`): the registry runner sends
  // its one upgrade bundle through it.
  Governance: "Governance.sol/Governance.json",
  ISelfDescribingFacet: "ISelfDescribingFacet.sol/ISelfDescribingFacet.json",
  ICTMRelease: "ICTMRelease.sol/ICTMRelease.json",
  ICTMTransition: "ICTMTransition.sol/ICTMTransition.json",
  IProxyUpgradeTransition: "IProxyUpgradeTransition.sol/IProxyUpgradeTransition.json",
  DefaultUpgrade: "DefaultUpgrade.sol/DefaultUpgrade.json",
  BootstrapUpgrade: "BootstrapUpgrade.sol/BootstrapUpgrade.json",
  DiamondInit: "DiamondInit.sol/DiamondInit.json",
  ZKsyncOSTestnetVerifier: "ZKsyncOSTestnetVerifier.sol/ZKsyncOSTestnetVerifier.json",
  ZKsyncOSVerifierPlonk: "ZKsyncOSVerifierPlonk.sol/ZKsyncOSVerifierPlonk.json",
  ProxyAdmin: "ProxyAdmin.sol/ProxyAdmin.json",
  L1MessageRoot: "L1MessageRoot.sol/L1MessageRoot.json",
  // Write-once release/CTM-transition/proxy-upgrade-transition objects (contracts/upgrades/registry). Each
  // takes its manifest as a CONSTRUCTOR argument, so a plain deployment is the whole creation
  // step. The committed manifest they are built from regenerates via
  // `yarn regen:registry-manifest` (emit mode of the registry upgrade runner).
  CTMRelease: "CTMRelease.sol/CTMRelease.json",
  CTMTransition: "CTMTransition.sol/CTMTransition.json",
  ProxyUpgradeTransition: "ProxyUpgradeTransition.sol/ProxyUpgradeTransition.json",
  ServerNotifier: "ServerNotifier.sol/ServerNotifier.json",
  // Bootstrap edge (see bootstrap-upgrade-stage.ts): the one-time entry into the registry-driven
  // model, plus the legacy cut-taking entrypoint a fixture may need installed.
  RegistryBootstrapMigration: "RegistryBootstrapMigration.sol/RegistryBootstrapMigration.json",
  LegacyTestAdminFacet: "LegacyTestAdminFacet.sol/LegacyTestAdminFacet.json",
  BridgedStandardERC20: "BridgedStandardERC20.sol/BridgedStandardERC20.json",
  ChainAdminOwnable: "ChainAdminOwnable.sol/ChainAdminOwnable.json",
  ChainRegistrationSender: "ChainRegistrationSender.sol/ChainRegistrationSender.json",
  DummyInteropRecipient: "DummyInteropRecipient.sol/DummyInteropRecipient.json",
  ExecutorFacet: "Executor.sol/ExecutorFacet.json",
  EmptyContract: "EmptyContract.sol/EmptyContract.json",
  GettersFacet: "Getters.sol/GettersFacet.json",
  IChainTypeManager: "IChainTypeManager.sol/IChainTypeManager.json",
  IERC7786Attributes: "IERC7786Attributes.sol/IERC7786Attributes.json",
  IL1Bridgehub: "IL1Bridgehub.sol/IL1Bridgehub.json",
  IL1GenesisUpgrade: "IL1GenesisUpgrade.sol/IL1GenesisUpgrade.json",
  IL2AssetRouter: "IL2AssetRouter.sol/IL2AssetRouter.json",
  IValidatorTimelock: "IValidatorTimelock.sol/IValidatorTimelock.json",
  IZKChain: "IZKChain.sol/IZKChain.json",
  InteropCenter: "InteropCenter.sol/InteropCenter.json",
  InteropAttributeParser: "InteropAttributeParser.sol/InteropAttributeParser.json",
  L2InteropHandler: "L2InteropHandler.sol/L2InteropHandler.json",
  ITransparentUpgradeableProxy: "TransparentUpgradeableProxy.sol/ITransparentUpgradeableProxy.json",
  L1AssetRouter: "L1AssetRouter.sol/L1AssetRouter.json",
  L1Messenger: "L1Messenger.sol/L1Messenger.json",
  L1Bridgehub: "L1Bridgehub.sol/L1Bridgehub.json",
  L1NativeTokenVault: "L1NativeTokenVault.sol/L1NativeTokenVault.json",
  L1Nullifier: "L1Nullifier.sol/L1Nullifier.json",
  L1InteropHandler: "L1InteropHandler.sol/L1InteropHandler.json",
  L1InteropFeeManager: "L1InteropFeeManager.sol/L1InteropFeeManager.json",
  L2AssetRouter: "L2AssetRouter.sol/L2AssetRouter.json",
  L2AssetTracker: "L2AssetTracker.sol/L2AssetTracker.json",
  L2BaseToken: "L2BaseToken.sol/L2BaseToken.json",
  ContractDeployer: "ContractDeployer.sol/ContractDeployer.json",
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
  L2WrappedBaseToken: "L2WrappedBaseToken.sol/L2WrappedBaseToken.json",
  MailboxFacet: "Mailbox.sol/MailboxFacet.json",
  CommitterFacet: "Committer.sol/CommitterFacet.json",
  MigratorFacet: "Migrator.sol/MigratorFacet.json",
  MockContractDeployer: "MockContractDeployer.sol/MockContractDeployer.json",
  FixedDelegateCalldataComposer: "FixedDelegateCalldataComposer.sol/FixedDelegateCalldataComposer.json",
  MockL1MessengerHook: "MockL1MessengerHook.sol/MockL1MessengerHook.json",
  MockL2MessageVerification: "MockL2MessageVerification.sol/MockL2MessageVerification.json",
  MockMintBaseTokenHook: "MockMintBaseTokenHook.sol/MockMintBaseTokenHook.json",
  Ownable2Step: "Ownable2Step.sol/Ownable2Step.json",
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
  L2DefaultUpgrade: "L2DefaultUpgrade.sol/L2DefaultUpgrade.json",
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

/**
 * Deployed (runtime) bytecode from the deterministic (CBOR-metadata-free) build — see
 * `[profile.registry-deterministic]` in l1-contracts/foundry.toml. Used for every contract an
 * bytecode-DERIVED value the committed registry manifest pins, and for the addresses it names.
 */
export function getDeterministicBytecode(name: ContractName): string {
  return loadDeterministicBytecodeFromOut(ARTIFACTS[name]);
}

/** Creation (init) bytecode from the deterministic (CBOR-metadata-free) build. */
export function getDeterministicCreationBytecode(name: ContractName): string {
  return loadDeterministicCreationBytecodeFromOut(ARTIFACTS[name]);
}

/** Solidity contract name behind `name`, which can differ from the harness name. */
export function getSolidityContractName(name: ContractName): string {
  return path.basename(ARTIFACTS[name], ".json");
}

/** Name of the Solidity source file that defines `name`, e.g. `SystemContext.sol`. */
export function getSoliditySourceFileName(name: ContractName): string {
  return path.dirname(ARTIFACTS[name]);
}
