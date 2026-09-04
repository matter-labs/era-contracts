/**
 * Version-independent pipeline upgrade test runner.
 *
 * Successor of the deleted v31 runner: replays a REAL protocol upgrade — the production
 * protocol-ops toolchain driving the version's actual forge prepare scripts — against
 * pre-generated anvil chain states of the departing version:
 *
 *   1. Load the frozen chain states (`chain-states/<stateVersion>`) and select target chains.
 *   2. Normalize L1 ownership (fixtures leave contracts with the deployer; governance needs them).
 *   3. (Only when the scenario asks for it) install the pre-v34 cut-taking entrypoint
 *      (`LegacyTestAdminFacet`) on the target chains. A fixture frozen from a branch whose
 *      Admin facet already READS its cut from the CTM needs the shim; the current frozen
 *      fixture carries the real cut-taking facet, so the chains cross natively — exactly like
 *      production pre-v34 chains.
 *   4. `protocol-ops ecosystem upgrade-prepare-all` with the scenario's core/CTM script paths
 *      (deployer Safe bundles replayed onto the harness anvil), then
 *      `protocol-ops ecosystem upgrade-governance` (stage 0/1/2 bundles replayed) — for the v34
 *      edge, stage 1 IS the four-call bootstrap handover + `migrate()`.
 *   5. Per-chain legacy handed-cut crossing, recorded-L2-tx verification, and the L2 relay of
 *      the proposed upgrade transaction on each chain's anvil fork.
 *   6. Final protocol-version verification on every upgraded chain.
 *
 * Everything version-specific rides the scenario: the departing state, the prepare scripts, the
 * upgrade-input/permanent-values templates and the expected final version.
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  INITIAL_BASE_TOKEN_HOLDER_BALANCE,
  INTEROP_ATTRIBUTE_PARSER_ADDR,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BASE_TOKEN_HOLDER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_CONTRACT_DEPLOYER_ADDR,
  L2_ECOSYSTEM_REGISTRY_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_REMOVED_GW_ASSET_TRACKER_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
  NTV_WETH_TOKEN_SLOT,
  NTV_L1_CHAIN_ID_SLOT,
  NTV_L2_TOKEN_PROXY_BYTECODE_HASH_SLOT,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";
import type { ContractName } from "../core/contracts";
import { forceBatchExecutedEqualsCommitted, transferOwnable2Step } from "./harness-shims";
import { clearGenesisUpgradeTxHash, selectUpgradeChains, traceFailedTx } from "./upgrade-test-utils";
import { installLegacyFacet, crossBootstrapEdgeOnChains } from "./bootstrap-upgrade-stage";
import { createProvider, impersonateAndRun } from "../core/utils";
import { runtimeConfig } from "../core/runtime-config";
import type { ChainRole } from "../core/types";

// ── Constants ────────────────────────────────────────────────────────

// EIP-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
// EIP-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

// ContractUpgradeType enum values from IComplexUpgrader.sol
const UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT = 0;
const UPGRADE_TYPE_ZKOS_SYSTEM_PROXY = 1;
const UPGRADE_TYPE_ZKOS_UNSAFE_FORCE_DEPLOY = 2;

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");
const contractsRootDir = path.resolve(l1ContractsDir, "..");

// Function selectors for the ComplexUpgrader entry points.
const SELECTORS = {
  // forceDeployAndUpgrade((bytes32,address,bool,uint256,bytes)[],address,bytes) — Era
  eraForceDeployAndUpgrade: "0x480d1185",
  // forceDeployAndUpgradeUniversal((uint8,bytes,address)[],address,bytes) — ZKsyncOS
  zkosForceDeployAndUpgradeUniversal: "0xd8cfca80",
} as const;

// ── Public types ─────────────────────────────────────────────────────

export type PipelineUpgradeScenario = {
  label: string;
  /** chain-states/<stateVersion> to boot from — the FROZEN departing-version fixture. */
  stateVersion: string;
  permanentValuesTemplatePath: string;
  upgradeInputTemplatePath: string;
  isZKsyncOS: boolean;
  targetRoles: ChainRole[];
  /** Protocol version the chains must report once the upgrade has been applied. */
  expectedProtocolVersion: string;
  /** Forge script targets driven by protocol-ops (`--core-script-path` / `--ctm-script-path`). */
  coreScriptPath: string;
  ctmScriptPath: string;
  /**
   * Bytecode placed at the L2 upgrade transaction's decoded delegate target before the relay
   * (the anvil L2s cannot force-deploy, so the harness `anvil_setCode`s it).
   */
  l2DelegateBytecodeName: ContractName;
  clearGenesisUpgradeTxHash?: boolean;
  transferL1ChainAssetHandlerOwnership?: boolean;
  /**
   * Install `LegacyTestAdminFacet` before governance. Needed ONLY for fixtures whose Admin
   * facet is the cut-READING (v34+) variant; a fixture with the real pre-v34 cut-taking facet
   * crosses natively, and installing the shim there collides (`FacetExists`).
   */
  installLegacyCutTakingFacet?: boolean;
};

// ── Main entry point ─────────────────────────────────────────────────

export async function runPipelineUpgradeScenario(scenario: PipelineUpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  let cleanupUpgradeHarnessInputs: (() => void) | null = null;
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";

  try {
    // ── Load pre-generated chain states ──
    const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
    if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
      throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, stateDir);
    const upgradeChainAddresses = selectUpgradeChains(chainAddresses, chains.config, scenario.targetRoles);
    if (upgradeChainAddresses.length === 0) {
      throw new Error(`No chains matched upgrade roles ${scenario.targetRoles.join(", ")} for ${scenario.label}`);
    }
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }
    const l1Provider = createProvider(l1Chain.rpcUrl);
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
    const oldVersion: ethers.BigNumber = await ctm.protocolVersion();
    console.log(`\nDeparting protocol version: ${oldVersion.toHexString()}`);

    // ── Transfer L1 contract ownership to governance ──
    console.log("\n── Preparing L1 ownership for upgrade ──");
    await transferL1Ownership(l1Provider, defaultSigner, l1Addresses, ctmAddresses, scenario);

    // ── Deploy ChainAdmin for each upgrade target ──
    console.log("\n── Deploying temporary ChainAdminOwnable contracts ──");
    await deployChainAdmins(l1Provider, defaultSigner, upgradeChainAddresses);

    // ── Optionally install the legacy cut-taking entrypoint (see module docs, step 3) ──
    if (scenario.installLegacyCutTakingFacet) {
      console.log("\n── Installing the legacy cut-taking entrypoint on target chains ──");
      const legacyFacet = await deployFromCreationBytecode(defaultSigner, "LegacyTestAdminFacet");
      await installLegacyFacet(
        l1Provider,
        ctmAddresses.chainTypeManager,
        legacyFacet,
        upgradeChainAddresses,
        sendAndCheck
      );
    }

    // ── Run ecosystem upgrade forge scripts via protocol-ops ──
    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
      l1Addresses,
      ctmAddresses,
      chainAddresses: upgradeChainAddresses,
    });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    console.log("\n── Preparing ecosystem upgrade bundles via protocol-ops ──");
    await runEcosystemUpgradeScripts({
      rpcUrl: l1Chain.rpcUrl,
      scenario,
      upgradeHarnessInputs,
      executeBundles: true,
    });

    // `upgrade-prepare-all` writes a single merged `ecosystem.toml` at the canonical tracked
    // path, containing stage-0/1/2 calls from core + every CTM concatenated in source order.
    const mergedEcosystemToml = path.join(upgradeHarnessInputs.protocolOpsOutDir, "ecosystem.toml");
    if (!fs.existsSync(mergedEcosystemToml)) {
      throw new Error(`Merged ecosystem TOML not emitted by upgrade-prepare-all: ${mergedEcosystemToml}`);
    }

    // ── Execute governance calls (stages 0-2) via protocol-ops bundle ──
    console.log("\n── Replaying governance upgrade bundles ──");
    await runEcosystemGovernanceUpgrade({
      rpcUrl: l1Chain.rpcUrl,
      bridgehubAddress: upgradeHarnessInputs.bridgehubAddress,
      governanceTomlPaths: [mergedEcosystemToml],
      outDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "governance"),
      executeBundles: true,
    });

    // ── Prepare diamond state for chain upgrades ──
    if (scenario.clearGenesisUpgradeTxHash) {
      console.log("\n── Clearing legacy genesis upgrade tx hashes ──");
      await clearGenesisUpgradeTxHash(l1Provider, upgradeChainAddresses);
    }

    // ── Per-chain legacy crossing + L2 relay ──
    // The cut + proposed upgrade come from the per-CTM light output the *ForTests CTM script
    // writes (`chain_upgrade_diamond_cut`); the file name is protocol-ops' convention
    // (`upgrade_inner.rs`).
    const ctmTomlPath = path.join(
      l1ContractsDir,
      "script-out",
      `upgrade-ctm-${upgradeHarnessInputs.ctmProxyAddress.toLowerCase()}.toml`
    );
    const { cut, proposedUpgrade, l2TxParamType, settlementLayerUpgradeAddr } = readCommittedCut(ctmTomlPath);
    await runLegacyChainLegAndRelayL2({
      l1Provider,
      anvilManager,
      upgradeChainAddresses,
      oldVersion,
      cut,
      proposedUpgrade,
      l2TxParamType,
      settlementLayerUpgradeAddr,
      bridgehubAddr: l1Addresses.bridgehub,
      ctmAddr: ctmAddresses.chainTypeManager,
      isZKsyncOS: scenario.isZKsyncOS,
      l2DelegateBytecodeName: scenario.l2DelegateBytecodeName,
    });

    console.log("\n── Chain upgrades complete, verifying final state ──");
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses, scenario.expectedProtocolVersion);
    await verifyCtmEndState(l1Provider, ctmAddresses.chainTypeManager, l1Addresses.governance, {
      oldVersion,
      expectedProtocolVersion: scenario.expectedProtocolVersion,
    });
    console.log("✅ Pipeline upgrade scenario verified successfully!\n");
  } finally {
    if (cleanupUpgradeHarnessInputs) {
      cleanupUpgradeHarnessInputs();
    }
    if (!keepChains) {
      await anvilManager.stopAll();
    }
  }
}

// ── Shared tx helper ─────────────────────────────────────────────────

async function sendAndCheck(
  provider: ethers.providers.JsonRpcProvider,
  txPromise: Promise<ethers.providers.TransactionResponse>,
  label: string
): Promise<ethers.providers.TransactionReceipt> {
  const tx = await txPromise;
  const receipt = await tx.wait();
  if (receipt.status !== 1) {
    const trace = await traceFailedTx(provider, receipt.transactionHash);
    throw new Error(`${label} reverted:\n${trace}`);
  }
  return receipt;
}

async function deployFromCreationBytecode(signer: ethers.Wallet, name: ContractName): Promise<string> {
  const factory = new ethers.ContractFactory(getAbi(name), getCreationBytecode(name), signer);
  const contract = await factory.deploy();
  await contract.deployed();
  return contract.address;
}

// ── L1 ownership & admin setup ───────────────────────────────────────

async function transferL1Ownership(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  l1Addresses: {
    governance: string;
    bridgehub: string;
    l1SharedBridge: string;
    l1NativeTokenVault: string;
    l1NullifierProxy?: string;
  },
  ctmAddresses: { chainTypeManager: string },
  scenario: PipelineUpgradeScenario
): Promise<void> {
  const gov = l1Addresses.governance;
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.bridgehub);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1SharedBridge);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NativeTokenVault);
  await transferOwnership2Step(provider, defaultSigner, gov, ctmAddresses.chainTypeManager);
  // A production ecosystem hands the nullifier to governance at deploy time; the fixtures leave
  // it with the deployer.
  if (l1Addresses.l1NullifierProxy) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NullifierProxy);
  }
  // The fixture leaves the ChainAssetHandler owned by its deployer. Governance must own it to
  // run the stage-0 pauseMigration() governance call. Resolved live — frozen fixtures predate
  // the ChainAssetHandler appearing in addresses.json.
  if (scenario.transferL1ChainAssetHandlerOwnership) {
    const bridgehub = new ethers.Contract(l1Addresses.bridgehub, getAbi("IL1Bridgehub"), provider);
    const chainAssetHandler: string = await bridgehub.chainAssetHandler();
    console.log(`   Transferring ChainAssetHandler ${chainAssetHandler} ownership to governance`);
    await transferOwnership2Step(provider, defaultSigner, gov, chainAssetHandler);
  }
  await normalizeProxyAdminOwnerToEoa(provider, defaultSigner, ctmAddresses.chainTypeManager);
}

/**
 * Hand the CTM's ProxyAdmin to governance when a contract owns it.
 *
 * The fixture's CTM deployment leaves its ProxyAdmin owned by its own `Governance.sol`
 * instance; the v34 stage-1 handover (`ProxyAdmin.transferOwnership(migration)`) is emitted as
 * a plain governance call, so governance itself has to be the owner.
 */
async function normalizeProxyAdminOwnerToEoa(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  proxyAddress: string
): Promise<void> {
  const rawAdmin = await provider.getStorageAt(proxyAddress, EIP1967_ADMIN_SLOT);
  const proxyAdmin = ethers.utils.getAddress(ethers.utils.hexDataSlice(rawAdmin, 12));

  const proxyAdminContract = new ethers.Contract(proxyAdmin, getAbi("ProxyAdmin"), provider);
  const owner: string = await proxyAdminContract.owner();
  if ((await provider.getCode(owner)) === "0x") {
    return;
  }

  console.log(`   Normalizing ProxyAdmin ${proxyAdmin} owner ${owner} -> ${defaultSigner.address}`);
  await provider.send("anvil_impersonateAccount", [owner]);
  await provider.send("anvil_setBalance", [owner, "0x56BC75E2D63100000"]);
  const ownerSigner = provider.getSigner(owner);
  const tx = await ownerSigner.sendTransaction({
    to: proxyAdmin,
    data: proxyAdminContract.interface.encodeFunctionData("transferOwnership", [defaultSigner.address]),
    gasLimit: 5_000_000,
  });
  await tx.wait();
  await provider.send("anvil_stopImpersonatingAccount", [owner]);
}

async function deployChainAdmins(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  const chainAdminFactory = new ethers.ContractFactory(
    getAbi("ChainAdminOwnable"),
    getCreationBytecode("ChainAdminOwnable"),
    defaultSigner
  );
  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));

  for (const chain of chains) {
    const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
    const currentAdmin = await diamondProxy.getAdmin();

    const chainAdmin = await chainAdminFactory.deploy(ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_ACCOUNT_ADDR);
    await chainAdmin.deployed();

    // Transfer admin: old admin → setPendingAdmin → new admin accepts
    await impersonateAndRun(provider, currentAdmin, async (signer) => {
      const tx = await signer.sendTransaction({
        to: chain.diamondProxy,
        data: adminIface.encodeFunctionData("setPendingAdmin", [chainAdmin.address]),
        gasLimit: 1_000_000,
      });
      return tx.wait();
    });

    const chainAdminContract = new ethers.Contract(chainAdmin.address, getAbi("ChainAdminOwnable"), defaultSigner);
    const acceptTx = await chainAdminContract.multicall(
      [{ target: chain.diamondProxy, value: 0, data: adminIface.encodeFunctionData("acceptAdmin", []) }],
      true
    );
    await acceptTx.wait();
  }
}

// ── Protocol-ops bundle generation/replay ───────────────────────────

type UpgradeHarnessInputs = ReturnType<typeof prepareUpgradeHarnessInputs>;

function runProtocolOps(args: string[], extraEnv?: Record<string, string>): void {
  const result = spawnSync("./protocol-ops.sh", args, {
    cwd: contractsRootDir,
    stdio: "inherit",
    env: {
      ...process.env,
      ...extraEnv,
      PROTOCOL_CONTRACTS_ROOT: contractsRootDir,
    },
  });
  if (result.status !== 0) {
    throw new Error(`protocol-ops failed: ${args.join(" ")}`);
  }
}

function safeBundlesInDir(dir: string): Array<{ file: string; target: string }> {
  const manifestPath = path.join(dir, "manifest.json");
  if (fs.existsSync(manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
      bundles?: Array<{ index?: number; file?: string; target?: string }>;
    };
    return (manifest.bundles ?? [])
      .filter((bundle): bundle is { index: number; file: string; target: string } => {
        return typeof bundle.index === "number" && typeof bundle.file === "string" && typeof bundle.target === "string";
      })
      .sort((a, b) => a.index - b.index)
      .map((bundle) => ({ file: path.join(dir, bundle.file), target: bundle.target }));
  }

  return fs
    .readdirSync(dir)
    .filter((file) => file.endsWith(".safe.json"))
    .sort()
    .map((file) => ({ file: path.join(dir, file), target: ANVIL_DEFAULT_ACCOUNT_ADDR }));
}

async function executeSafeBundles(outDir: string, rpcUrl: string): Promise<void> {
  if (!fs.existsSync(outDir)) {
    throw new Error(`Protocol-ops output directory does not exist: ${outDir}`);
  }
  const safeBundles = safeBundlesInDir(outDir);
  if (safeBundles.length === 0) {
    throw new Error(`No protocol-ops Safe bundles found in ${outDir}`);
  }
  const provider = createProvider(rpcUrl);

  for (const bundle of safeBundles) {
    const safeFile = JSON.parse(fs.readFileSync(bundle.file, "utf8")) as {
      transactions?: Array<{ to: string; value: string; data: string }>;
    };
    const transactions = safeFile.transactions ?? [];
    if (transactions.length === 0) {
      throw new Error(`Safe bundle has no transactions: ${bundle.file}`);
    }

    await provider.send("anvil_impersonateAccount", [bundle.target]);
    await provider.send("anvil_setBalance", [bundle.target, "0x56BC75E2D63100000"]);
    const signer = provider.getSigner(bundle.target);
    try {
      for (let i = 0; i < transactions.length; i++) {
        const tx = await signer.sendTransaction({
          to: transactions[i].to,
          value: ethers.BigNumber.from(transactions[i].value),
          data: transactions[i].data,
          gasLimit: 30_000_000,
        });
        const receipt = await tx.wait();
        if (receipt.status !== 1) {
          const trace = await traceFailedTx(provider, receipt.transactionHash);
          throw new Error(
            `Safe bundle ${path.basename(bundle.file)} tx ${i + 1}/${transactions.length} reverted:\n${trace}`
          );
        }
      }
    } finally {
      await provider.send("anvil_stopImpersonatingAccount", [bundle.target]);
    }
  }
}

export async function runEcosystemUpgradeScripts(params: {
  rpcUrl: string;
  scenario: PipelineUpgradeScenario;
  upgradeHarnessInputs: UpgradeHarnessInputs;
  executeBundles?: boolean;
}): Promise<void> {
  const prepareOutDir = path.join(params.upgradeHarnessInputs.protocolOpsOutDir, "prepare");
  fs.rmSync(prepareOutDir, { recursive: true, force: true });

  // Addresses are passed explicitly rather than auto-resolved: the snapshot config is
  // authoritative for the loaded fixture.
  runProtocolOps(
    [
      "ecosystem",
      "upgrade-prepare-all",
      "--bridgehub",
      params.upgradeHarnessInputs.bridgehubAddress,
      "--l1-rpc-url",
      params.rpcUrl,
      "--out",
      prepareOutDir,
      "--deployer-address",
      ANVIL_DEFAULT_ACCOUNT_ADDR,
      "--ctm-proxy",
      params.upgradeHarnessInputs.ctmProxyAddress,
      "--bytecodes-supplier-address",
      params.upgradeHarnessInputs.bytecodesSupplierAddress,
      "--rollup-da-manager-address",
      params.upgradeHarnessInputs.rollupDaManagerAddress,
      "--is-zk-sync-os",
      String(params.upgradeHarnessInputs.isZKsyncOS),
      "--create2-factory-salt",
      params.upgradeHarnessInputs.create2FactorySalt,
      "--upgrade-input-path",
      params.upgradeHarnessInputs.upgradeInputArg,
      "--core-script-path",
      params.scenario.coreScriptPath,
      "--ctm-script-path",
      params.scenario.ctmScriptPath,
      "--additional-args=--memory-limit=536870912",
    ],
    params.upgradeHarnessInputs.envVars
  );

  if (params.executeBundles) {
    await executeSafeBundles(prepareOutDir, params.rpcUrl);
  }
}

export async function runEcosystemGovernanceUpgrade(params: {
  rpcUrl: string;
  bridgehubAddress: string;
  governanceTomlPaths: string[];
  outDir: string;
  executeBundles?: boolean;
}): Promise<void> {
  if (params.governanceTomlPaths.length === 0) {
    throw new Error("runEcosystemGovernanceUpgrade requires at least one governance TOML");
  }
  fs.rmSync(params.outDir, { recursive: true, force: true });

  const args: string[] = [
    "ecosystem",
    "upgrade-governance",
    "--bridgehub",
    params.bridgehubAddress,
    "--l1-rpc-url",
    params.rpcUrl,
    "--out",
    params.outDir,
  ];
  for (const toml of params.governanceTomlPaths) {
    args.push("--governance-toml", toml);
  }
  runProtocolOps(args);

  if (params.executeBundles) {
    await executeSafeBundles(params.outDir, params.rpcUrl);
  }
}

// ── Committed cut + proposed upgrade ─────────────────────────────────

const DIAMOND_CUT_TYPE =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";

/**
 * Read the committed upgrade cut from the per-CTM light output and decode the ProposedUpgrade
 * out of its init calldata (the engine's `upgrade(ProposedUpgrade)` delegatecall payload).
 */
function readCommittedCut(ctmTomlPath: string): {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  cut: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  proposedUpgrade: any;
  l2TxParamType: ethers.utils.ParamType;
  settlementLayerUpgradeAddr: string;
} {
  if (!fs.existsSync(ctmTomlPath)) {
    throw new Error(`Missing per-CTM prepare output ${ctmTomlPath}. Did upgrade-prepare-all run?`);
  }
  const ctmOutput = parseToml(fs.readFileSync(ctmTomlPath, "utf8")) as {
    chain_upgrade_diamond_cut?: string;
    state_transition?: { default_upgrade_addr?: string };
  };
  const cutBytes = ctmOutput.chain_upgrade_diamond_cut;
  if (typeof cutBytes !== "string" || cutBytes.length < 4) {
    throw new Error(`No chain_upgrade_diamond_cut in ${ctmTomlPath}`);
  }
  const settlementLayerUpgradeAddr = ctmOutput.state_transition?.default_upgrade_addr;
  if (!settlementLayerUpgradeAddr || ethers.BigNumber.from(settlementLayerUpgradeAddr).isZero()) {
    throw new Error(`No state_transition.default_upgrade_addr in ${ctmTomlPath}`);
  }
  const [cut] = ethers.utils.defaultAbiCoder.decode([DIAMOND_CUT_TYPE], cutBytes);

  const engineIface = new ethers.utils.Interface(getAbi("DefaultUpgrade"));
  const [proposedUpgrade] = engineIface.decodeFunctionData("upgrade", cut.initCalldata);
  const l2TxParamType = engineIface
    .getFunction("upgrade")
    .inputs[0].components?.find((c) => c.name === "l2ProtocolUpgradeTx");
  if (!l2TxParamType) {
    throw new Error("ProposedUpgrade ABI has no l2ProtocolUpgradeTx component");
  }
  return { cut, proposedUpgrade, l2TxParamType, settlementLayerUpgradeAddr };
}

// ── Per-chain legacy crossing + L2 relay ─────────────────────────────

async function runLegacyChainLegAndRelayL2(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  anvilManager: AnvilManager;
  upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  oldVersion: ethers.BigNumber;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  cut: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  proposedUpgrade: any;
  l2TxParamType: ethers.utils.ParamType;
  settlementLayerUpgradeAddr: string;
  bridgehubAddr: string;
  ctmAddr: string;
  isZKsyncOS: boolean;
  l2DelegateBytecodeName: ContractName;
}): Promise<void> {
  const l2Tx = params.proposedUpgrade.l2ProtocolUpgradeTx;
  const hasL2Leg = !ethers.BigNumber.from(l2Tx.txType).isZero();

  // ZKsync OS relays write the registry FIRST: every chain's L2EcosystemRegistry must end up
  // pinning exactly the fixedForceDeploymentsData bytes the run's deployed release pins on L1
  // (the L1 legs already ran, so the CTM's currentRelease IS that release).
  let expectedEcosystemDataHash: string | undefined;
  if (params.isZKsyncOS && hasL2Leg) {
    const ctm = new ethers.Contract(params.ctmAddr, getAbi("IChainTypeManager"), params.l1Provider);
    const release = new ethers.Contract(await ctm.currentRelease(), getAbi("CTMRelease"), params.l1Provider);
    expectedEcosystemDataHash = ethers.utils.keccak256(await release.fixedForceDeploymentsData());
  }
  // The committed L2 tx carries per-chain placeholders (chainId, chain-specific force-deployment
  // data); the per-chain upgrade contract rewrites them at upgrade time, and this leg reproduces
  // the same rewrite through its public view.
  const settlementLayerUpgrade = new ethers.Contract(
    params.settlementLayerUpgradeAddr,
    getAbi("DefaultUpgradeZKsyncOS"),
    params.l1Provider
  );

  for (const chain of params.upgradeChainAddresses) {
    console.log(`\n── Chain ${chain.chainId}: legacy handed-cut crossing ──`);

    // The per-chain upgrade requires `totalBatchesCommitted == totalBatchesExecuted`. On a
    // forked chain with uncommitted-but-pending batches at fork time, model the "all batches
    // executed" prerequisite without running the executor.
    await forceBatchExecutedEqualsCommitted(params.l1Provider, chain.diamondProxy);

    await crossBootstrapEdgeOnChains(params.l1Provider, [chain], params.oldVersion, params.cut, sendAndCheck);

    if (!hasL2Leg) {
      console.log(`  chain ${chain.chainId}: no L2 leg in the proposed upgrade (txType 0)`);
      continue;
    }

    // Reproduce the per-chain rewrite the upgrade contract performed during the crossing.
    const rewrittenData: string = await settlementLayerUpgrade.getL2UpgradeTxData(
      params.bridgehubAddr,
      chain.chainId,
      params.isZKsyncOS,
      l2Tx.data
    );
    if (rewrittenData.toLowerCase() === (l2Tx.data as string).toLowerCase()) {
      throw new Error(
        `Chain ${chain.chainId}: the rewritten L2 upgrade tx is identical to the committed placeholder — ` +
          "the per-chain rewrite did nothing, so the recorded-hash check below would prove nothing."
      );
    }

    // The chain must have recorded exactly the transaction being relayed — `BaseZkSyncUpgrade`
    // stores keccak256(abi.encode(l2ProtocolUpgradeTx)) AFTER the per-chain rewrite. Reproducing
    // the rewrite here (rather than reading it back — the diamond only stores the hash) proves
    // the upgrade contract performed the same rewrite during the crossing.
    const relayedTx = { ...l2Tx, data: rewrittenData };
    const expectedHash = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode([params.l2TxParamType], [relayedTx])
    );
    const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), params.l1Provider);
    const recordedHash: string = await getters.getL2SystemContractsUpgradeTxHash();
    if (recordedHash.toLowerCase() !== expectedHash.toLowerCase()) {
      throw new Error(
        `Chain ${chain.chainId}: the diamond recorded L2 upgrade tx ${recordedHash}, but the transaction ` +
          `being relayed hashes to ${expectedHash}.`
      );
    }
    console.log(`   Recorded L2 upgrade tx hash matches the relayed transaction (${expectedHash})`);

    const l2Chain = params.anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }
    const l2Provider = createProvider(l2Chain.rpcUrl);

    const l2TxHash = await prepareAndRelayL2Upgrade(
      l2Provider,
      rewrittenData,
      params.isZKsyncOS,
      params.l2DelegateBytecodeName
    );
    console.log(`  ✅ L2 upgrade relay tx: ${l2TxHash}`);

    await verifyL2UpgradeResult(l2Provider, chain.chainId);

    if (expectedEcosystemDataHash) {
      const registry = new ethers.Contract(L2_ECOSYSTEM_REGISTRY_ADDR, getAbi("L2EcosystemRegistry"), l2Provider);
      const liveHash: string = await registry.dataHash();
      if (liveHash.toLowerCase() !== expectedEcosystemDataHash.toLowerCase()) {
        throw new Error(
          `Chain ${chain.chainId}: L2EcosystemRegistry.dataHash ${liveHash} does not match the keccak of the ` +
            `release's pinned fixedForceDeploymentsData (${expectedEcosystemDataHash})`
        );
      }
      console.log(`   L2EcosystemRegistry pins the release's fixedForceDeploymentsData (${liveHash})`);
    }
  }
}

/**
 * Deploy all L2 system contracts, then relay the upgrade tx.
 *
 * On Anvil EVM, neither the Era ContractDeployer nor ZKsyncOS bytecode deployer infrastructure
 * works. Instead we pre-deploy all known contracts via anvil_setCode and place a
 * MockContractDeployer at 0x8006.
 */
async function prepareAndRelayL2Upgrade(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string,
  isZKsyncOS: boolean,
  l2DelegateBytecodeName: ContractName
): Promise<string> {
  const { forceDeployEntries, delegateTo } = decodeUpgradeTxData(upgradeTxData);

  await deployL2Contracts(l2Provider, forceDeployEntries, delegateTo, isZKsyncOS, l2DelegateBytecodeName);

  const txHash = await impersonateAndRun(l2Provider, L2_FORCE_DEPLOYER_ADDR, async (signer) => {
    const tx = await signer.sendTransaction({
      to: L2_COMPLEX_UPGRADER_ADDR,
      data: upgradeTxData,
      gasLimit: 100_000_000,
    });
    return tx.hash;
  });
  const receipt = await l2Provider.waitForTransaction(txHash);

  if (receipt.status !== 1) {
    const trace = await traceFailedTx(l2Provider, receipt.transactionHash);
    throw new Error(`L2 upgrade relay reverted:\n${trace}`);
  }
  return receipt.transactionHash;
}

// ── L2 contract deployment ───────────────────────────────────────────

async function deployL2Contracts(
  l2Provider: ethers.providers.JsonRpcProvider,
  forceDeployEntries: ForceDeployEntry[],
  delegateTo: string,
  isZKsyncOS: boolean,
  l2DelegateBytecodeName: ContractName
): Promise<void> {
  // MockContractDeployer: no-op fallback at ContractDeployer address so that forceDeployEra()
  // and conductContractUpgrade() calls succeed silently.
  await l2Provider.send("anvil_setCode", [L2_CONTRACT_DEPLOYER_ADDR, getBytecode("MockContractDeployer")]);

  await l2Provider.send("anvil_setCode", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    getBytecode("SystemContractProxyAdmin"),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    ethers.utils.hexZeroPad("0x0", 32), // slot 0: Ownable._owner
    ethers.utils.hexZeroPad(L2_COMPLEX_UPGRADER_ADDR, 32),
  ]);

  const contractMap = buildAddressToContract(isZKsyncOS);
  for (const entry of forceDeployEntries) {
    if (entry.upgradeType === UPGRADE_TYPE_ZKOS_UNSAFE_FORCE_DEPLOY) {
      continue;
    }

    const contractName = contractMap.get(entry.address.toLowerCase());
    if (!contractName) {
      if (entry.upgradeType === UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT) {
        continue;
      }
      throw new Error(`No contract mapping for ZKsyncOS force deploy address ${entry.address}`);
    }

    if (isZKsyncOS && entry.upgradeType === UPGRADE_TYPE_ZKOS_SYSTEM_PROXY) {
      if (!entry.deployedBytecodeInfo) {
        throw new Error(`ZKsyncOSSystemProxyUpgrade entry ${entry.address} missing deployedBytecodeInfo`);
      }
      await deployBehindSystemProxy(l2Provider, entry.address, getBytecode(contractName), entry.deployedBytecodeInfo);
    } else {
      await l2Provider.send("anvil_setCode", [entry.address, getBytecode(contractName)]);
    }
  }

  // Deploy the delegate target of the ComplexUpgrader call.
  await l2Provider.send("anvil_setCode", [delegateTo, getBytecode(l2DelegateBytecodeName)]);

  // L2BaseToken.initL2 mints an initial balance into the BaseTokenHolder and then transfers
  // ETH to it, so the token needs a non-zero balance on the anvil chain.
  await l2Provider.send("anvil_setBalance", [L2_BASE_TOKEN_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE]);

  // Seed critical storage values on L2 contracts deployed via anvil_setCode but never
  // initialized (performForceDeployedContractsInit reads these before calling updateL2).
  const toSlot = (n: number) => ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 32);
  const toAddr = (a: string) => ethers.utils.hexZeroPad(a, 32);

  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_WETH_TOKEN_SLOT),
    toAddr(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_L1_CHAIN_ID_SLOT),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(runtimeConfig.l1ChainId), 32),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_L2_TOKEN_PROXY_BYTECODE_HASH_SLOT),
    ethers.utils.hexZeroPad("0x01", 32),
  ]);
}

/**
 * Deploy a contract behind a SystemContractProxy on Anvil, matching ZKsyncOS production layout.
 */
async function deployBehindSystemProxy(
  provider: ethers.providers.JsonRpcProvider,
  systemAddress: string,
  implBytecode: string,
  deployedBytecodeInfo: string
): Promise<void> {
  // Derive the implementation address the same way L2GenesisForceDeploymentsHelper does
  // on-chain: keccak256(bytes32(0) ++ bytecodeInfo).
  const [bytecodeInfo] = ethers.utils.defaultAbiCoder.decode(["bytes", "bytes"], deployedBytecodeInfo);
  const implAddressHash = ethers.utils.keccak256(ethers.utils.concat([ethers.constants.HashZero, bytecodeInfo]));
  const implAddress = ethers.utils.getAddress("0x" + implAddressHash.slice(26));

  await provider.send("anvil_setCode", [implAddress, implBytecode]);
  await provider.send("anvil_setCode", [systemAddress, getBytecode("SystemContractProxy")]);
  await provider.send("anvil_setStorageAt", [
    systemAddress,
    EIP1967_ADMIN_SLOT,
    ethers.utils.hexZeroPad(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, 32),
  ]);
  await provider.send("anvil_setStorageAt", [
    systemAddress,
    EIP1967_IMPL_SLOT,
    ethers.utils.hexZeroPad(implAddress, 32),
  ]);
}

// ── Calldata decoding ────────────────────────────────────────────────

/** Decoded force deployment entry with upgrade type metadata. */
interface ForceDeployEntry {
  address: string;
  upgradeType: number; // ContractUpgradeType enum value
  deployedBytecodeInfo?: string;
}

/** Decode the ComplexUpgrader calldata (any variant) into its components. */
function decodeUpgradeTxData(upgradeTxData: string): {
  forceDeployEntries: ForceDeployEntry[];
  delegateTo: string;
  innerCalldata: string;
} {
  const selector = upgradeTxData.slice(0, 10);
  const payload = "0x" + upgradeTxData.slice(10);
  const abiCoder = ethers.utils.defaultAbiCoder;

  if (selector === SELECTORS.eraForceDeployAndUpgrade) {
    const [deployments, delegateTo, innerCalldata] = abiCoder.decode(
      ["tuple(bytes32,address,bool,uint256,bytes)[]", "address", "bytes"],
      payload
    );
    const entries: ForceDeployEntry[] = deployments.map((fd: { 1: string }) => ({
      address: fd[1],
      upgradeType: UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT,
    }));
    return { forceDeployEntries: entries, delegateTo, innerCalldata };
  }

  if (selector === SELECTORS.zkosForceDeployAndUpgradeUniversal) {
    const [deployments, delegateTo, innerCalldata] = abiCoder.decode(
      ["tuple(uint8,bytes,address)[]", "address", "bytes"],
      payload
    );
    const entries: ForceDeployEntry[] = deployments.map((fd: { 0: number; 1: string; 2: string }) => ({
      address: fd[2],
      upgradeType: fd[0],
      deployedBytecodeInfo: fd[1],
    }));
    return { forceDeployEntries: entries, delegateTo, innerCalldata };
  }

  throw new Error(`Unknown ComplexUpgrader selector: ${selector}`);
}

/** Build the address→contract map for the given VM type. */
function buildAddressToContract(isZKsyncOS: boolean): ReadonlyMap<string, ContractName> {
  const entries: Array<[string, ContractName]> = [
    [L2_MESSAGE_ROOT_ADDR.toLowerCase(), "L2MessageRoot"],
    [L2_BRIDGEHUB_ADDR.toLowerCase(), "L2Bridgehub"],
    [L2_ASSET_ROUTER_ADDR.toLowerCase(), "L2AssetRouter"],
    [L2_NATIVE_TOKEN_VAULT_ADDR.toLowerCase(), isZKsyncOS ? "L2NativeTokenVaultZKOS" : "L2NativeTokenVault"],
    [L2_CHAIN_ASSET_HANDLER_ADDR.toLowerCase(), "L2ChainAssetHandler"],
    [L2_ASSET_TRACKER_ADDR.toLowerCase(), "L2AssetTracker"],
    [INTEROP_CENTER_ADDR.toLowerCase(), "InteropCenter"],
    [INTEROP_ATTRIBUTE_PARSER_ADDR.toLowerCase(), "InteropAttributeParser"],
    [L2_INTEROP_HANDLER_ADDR.toLowerCase(), "L2InteropHandler"],
    [L2_BASE_TOKEN_HOLDER_ADDR.toLowerCase(), "BaseTokenHolder"],
    [L2_WRAPPED_BASE_TOKEN_IMPL_ADDR.toLowerCase(), "L2WrappedBaseToken"],
    [L2_MESSAGE_VERIFICATION_ADDR.toLowerCase(), "L2MessageVerification"],
    [L2_INTEROP_ROOT_STORAGE_ADDR.toLowerCase(), "L2InteropRootStorage"],
  ];
  if (isZKsyncOS) {
    // Keep this block in sync with SystemContractsProcessing's getZKsyncOSOnlyContracts /
    // getZKsyncOSExtraSystemContracts: every appended L2EcosystemContract member with a
    // fixed address rides the derived force-deployment list and needs a row here.
    entries.push(
      [L2_INTEROP_COMMITMENT_TREE_ADDR.toLowerCase(), "L2InteropCommitmentTree"],
      [L2_ATOMIC_FLOW_MANAGER_ADDR.toLowerCase(), "AtomicFlowManager"],
      [L2_ECOSYSTEM_REGISTRY_ADDR.toLowerCase(), "L2EcosystemRegistry"],
      [L2_BASE_TOKEN_ADDR.toLowerCase(), "L2BaseTokenZKOS"],
      [L2_TO_L1_MESSENGER_ADDR.toLowerCase(), "L1MessengerZKOS"],
      [SYSTEM_CONTEXT_ADDR.toLowerCase(), "SystemContext"],
      [L2_CONTRACT_DEPLOYER_ADDR.toLowerCase(), "ZKOSContractDeployer"],
      // The removed v31 GWAssetTracker: upgrades swap its proxy's implementation for EmptyContract.
      [L2_REMOVED_GW_ASSET_TRACKER_ADDR.toLowerCase(), "EmptyContract"]
    );
  }
  return new Map(entries);
}

// ── Verification ─────────────────────────────────────────────────────

async function verifyL2UpgradeResult(l2Provider: ethers.providers.JsonRpcProvider, chainId: number): Promise<void> {
  const assetTracker = new ethers.Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Provider);

  const l1ChainId = await assetTracker.L1_CHAIN_ID();
  if (!l1ChainId.eq(runtimeConfig.l1ChainId)) {
    throw new Error(`Chain ${chainId}: L2AssetTracker.L1_CHAIN_ID = ${l1ChainId}, expected ${runtimeConfig.l1ChainId}`);
  }

  const baseTokenAssetId = await assetTracker.BASE_TOKEN_ASSET_ID();
  if (!(await assetTracker.isAssetRegistered(baseTokenAssetId))) {
    throw new Error(`Chain ${chainId}: base token bookkeeping not initialized after L2 upgrade`);
  }
}

export async function verifyProtocolVersions(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  expectedProtocolVersion: string
): Promise<void> {
  const expectedVersion = ethers.BigNumber.from(expectedProtocolVersion);
  for (const chain of chains) {
    const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
    const version = await diamond.getProtocolVersion();
    if (!version.eq(expectedVersion)) {
      throw new Error(
        `Chain ${chain.chainId}: protocol version ${version.toHexString()}, expected ${expectedVersion.toHexString()}`
      );
    }
  }
}

/**
 * Post-upgrade CTM-side assertions for the bootstrap edge: the version bumped, the whole CTM
 * domain (CTM + its ProxyAdmin) landed under ONE new authority that is not governance (the
 * bound `CTMUpgradeExecutor`), the genesis release is pinned with its anchor, and the commit
 * has the legacy cut-taking shape (hash written, no transition registered).
 */
async function verifyCtmEndState(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  governance: string,
  params: { oldVersion: ethers.BigNumber; expectedProtocolVersion: string }
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), provider);
  const ownable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), provider);

  const version: ethers.BigNumber = await ctm.protocolVersion();
  if (!version.eq(ethers.BigNumber.from(params.expectedProtocolVersion))) {
    throw new Error(`CTM protocol version ${version.toHexString()}, expected ${params.expectedProtocolVersion}`);
  }

  const ctmOwner: string = await ownable.owner();
  const rawAdmin = await provider.getStorageAt(ctmAddr, EIP1967_ADMIN_SLOT);
  const proxyAdminAddr = ethers.utils.getAddress(ethers.utils.hexDataSlice(rawAdmin, 12));
  const proxyAdmin = new ethers.Contract(proxyAdminAddr, getAbi("ProxyAdmin"), provider);
  const proxyAdminOwner: string = await proxyAdmin.owner();
  if (ctmOwner.toLowerCase() === governance.toLowerCase()) {
    throw new Error("CTM ownership did not leave governance — the bootstrap handover did not complete");
  }
  if (ctmOwner.toLowerCase() !== proxyAdminOwner.toLowerCase()) {
    throw new Error(
      `CTM domain authority is split: CTM owner ${ctmOwner}, ProxyAdmin owner ${proxyAdminOwner} — ` +
        "both must be the bound CTMUpgradeExecutor"
    );
  }

  const release: string = await ctm.currentRelease();
  if (release === ethers.constants.AddressZero) {
    throw new Error("currentRelease not pinned after the bootstrap edge");
  }
  const anchor: string = await ctm.releaseCodehash();
  const releaseCodehash = ethers.utils.keccak256(await provider.getCode(release));
  if (anchor.toLowerCase() !== releaseCodehash.toLowerCase()) {
    throw new Error(`releaseCodehash anchor ${anchor} does not cover the pinned release (${releaseCodehash})`);
  }

  const cutHash: string = await ctm.upgradeCutHash(params.oldVersion);
  if (cutHash === ethers.constants.HashZero) {
    throw new Error("the bootstrap edge must commit the legacy cut hash for the departing version");
  }
  const committedTransition: string = await ctm.upgradeTransition(params.oldVersion);
  if (committedTransition !== ethers.constants.AddressZero) {
    throw new Error("the bootstrap edge must not register a transition");
  }
  console.log(`  ✓ CTM at ${params.expectedProtocolVersion}, domain under executor ${ctmOwner}, release ${release}`);
}

// ── Ownership helpers ────────────────────────────────────────────────

async function transferOwnership2Step(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  governanceAddr: string,
  contractAddr: string
): Promise<void> {
  const contract = new ethers.Contract(contractAddr, getAbi("Ownable2Step"), provider);
  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) return;
  if (currentOwner.toLowerCase() !== defaultSigner.address.toLowerCase()) {
    throw new Error(`Expected deployer to own ${contractAddr}, found ${currentOwner}`);
  }
  await transferOwnable2Step(provider, contractAddr, getAbi("Ownable2Step"), currentOwner, governanceAddr);
}

// ── TOML config helpers ──────────────────────────────────────────────

function replaceTomlStringValue(contents: string, key: string, value: string): string {
  // eslint-disable-next-line no-useless-escape
  const pattern = new RegExp(`^(${key}\\s*=\\s*\").*(\")$`, "m");
  return pattern.test(contents) ? contents.replace(pattern, `$1${value}$2`) : contents;
}

function replaceTomlBareValue(contents: string, key: string, value: string): string {
  const pattern = new RegExp(`^(${key}\\s*=\\s*).*$`, "m");
  return pattern.test(contents) ? contents.replace(pattern, `$1${value}`) : `${key} = ${value}\n${contents}`;
}

export function prepareUpgradeHarnessInputs(
  scenario: PipelineUpgradeScenario,
  state: {
    l1Addresses: { bridgehub: string; governance: string };
    ctmAddresses: { chainTypeManager: string };
    chainAddresses: Array<{ chainId: number }>;
  }
): {
  envVars: Record<string, string>;
  ecosystemOutputPath: string;
  bridgehubAddress: string;
  protocolOpsOutDir: string;
  upgradeInputArg: string;
  bytecodesSupplierAddress: string;
  rollupDaManagerAddress: string;
  create2FactorySalt: string;
  isZKsyncOS: boolean;
  ctmProxyAddress: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${scenario.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${scenario.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${scenario.label}-upgrade-input.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${scenario.label}-upgrade-ecosystem.toml`);
  const protocolOpsOutDir = path.join(tempDir, "protocol-ops");

  const primaryChainId = state.chainAddresses[0]?.chainId;
  if (!primaryChainId) throw new Error(`No chains loaded for ${scenario.label}`);

  let permanentValues = fs.readFileSync(path.join(l1ContractsDir, scenario.permanentValuesTemplatePath), "utf8");
  permanentValues = replaceTomlBareValue(permanentValues, "era_chain_id", String(primaryChainId));
  permanentValues = replaceTomlStringValue(permanentValues, "bridgehub_proxy_addr", state.l1Addresses.bridgehub);
  permanentValues = replaceTomlStringValue(permanentValues, "ctm_proxy_addr", state.ctmAddresses.chainTypeManager);
  permanentValues = replaceTomlBareValue(permanentValues, "is_zk_sync_os", scenario.isZKsyncOS ? "true" : "false");
  fs.writeFileSync(permanentValuesPath, permanentValues);

  let upgradeInput = fs.readFileSync(path.join(l1ContractsDir, scenario.upgradeInputTemplatePath), "utf8");
  upgradeInput = replaceTomlBareValue(upgradeInput, "era_chain_id", String(primaryChainId));
  upgradeInput = replaceTomlStringValue(upgradeInput, "bridgehub_proxy_address", state.l1Addresses.bridgehub);
  upgradeInput = replaceTomlStringValue(upgradeInput, "owner_address", state.l1Addresses.governance);
  upgradeInput = replaceTomlBareValue(upgradeInput, "sample_chain_id", String(primaryChainId));
  fs.writeFileSync(upgradeInputPath, upgradeInput);

  const permanentValuesToml = parseToml(permanentValues) as {
    ctm_contracts?: {
      l1_bytecodes_supplier_addr?: string;
      rollup_da_manager?: string;
    };
    permanent_contracts?: {
      create2_factory_salt?: string;
    };
  };

  return {
    envVars: {
      PERMANENT_VALUES_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, permanentValuesPath)}`,
      UPGRADE_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
      UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
    },
    ecosystemOutputPath,
    bridgehubAddress: state.l1Addresses.bridgehub,
    protocolOpsOutDir,
    upgradeInputArg: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
    bytecodesSupplierAddress:
      permanentValuesToml.ctm_contracts?.l1_bytecodes_supplier_addr ?? ethers.constants.AddressZero,
    rollupDaManagerAddress: permanentValuesToml.ctm_contracts?.rollup_da_manager ?? ethers.constants.AddressZero,
    create2FactorySalt: permanentValuesToml.permanent_contracts?.create2_factory_salt ?? ethers.constants.HashZero,
    isZKsyncOS: scenario.isZKsyncOS,
    ctmProxyAddress: state.ctmAddresses.chainTypeManager,
    cleanup: () => fs.rmSync(tempDir, { recursive: true, force: true }),
  };
}
