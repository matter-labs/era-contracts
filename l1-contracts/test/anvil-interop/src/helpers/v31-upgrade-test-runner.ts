import { execSync, spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import { runForgeScript } from "../core/forge";
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
import { getAbi, getBytecode, getCreationBytecode, LEGACY_ADMIN_ABI } from "../core/contracts";
import type { ContractName } from "../core/contracts";
import { forceBatchExecutedEqualsCommitted, modelV31BackfillPrerequisite, transferOwnable2Step } from "./harness-shims";
import { expectRevert } from "./balance-helpers";
import { impersonateAndRun, createProvider } from "../core/utils";
import { runtimeConfig } from "../core/runtime-config";
import type { ChainRole } from "../core/types";

// ── Constants ────────────────────────────────────────────────────────

// Protocol version this release upgrades chains to. The upgrade inputs under `config/` carry it as a
// literal too, since TOML cannot import it.
export const TARGET_PROTOCOL_VERSION = "0x2000000000";

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
// Memory-trimmed test variants of CoreUpgrade_v31 / CTMUpgrade_v31 used as
// `--core-script-path` / `--ctm-script-path` overrides for `upgrade-prepare-all`.
// Stage 3 still runs as a direct `forge script` invocation (no protocol-ops command),
// against the same Core test variant which provides a no-arg `stage3()` wrapper.
const CORE_UPGRADE_TEST_SCRIPT = "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:CoreUpgradeV31ForTests";
const CTM_UPGRADE_TEST_SCRIPT = "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:CTMUpgradeV31ForTests";

// Function selectors for the ComplexUpgrader entry points.
// Used to decode the final L2 upgrade tx data (output of getL2UpgradeTxData).
const SELECTORS = {
  // forceDeployAndUpgrade((bytes32,address,bool,uint256,bytes)[],address,bytes) — Era
  eraForceDeployAndUpgrade: "0x480d1185",
  // forceDeployAndUpgradeUniversal((uint8,bytes,address)[],address,bytes) — ZKsyncOS
  zkosForceDeployAndUpgradeUniversal: "0xd8cfca80",
} as const;

// ── Public types ─────────────────────────────────────────────────────

export type V31UpgradeScenario = {
  label: string;
  stateVersion: string;
  permanentValuesTemplatePath: string;
  upgradeInputTemplatePath: string;
  targetRoles: ChainRole[];
  // Protocol version the chains must report once the upgrade has been applied.
  expectedProtocolVersion: string;
  clearGenesisUpgradeTxHash?: boolean;
  transferL1ChainAssetHandlerOwnership?: boolean;
};

// ── Main entry point ─────────────────────────────────────────────────

export async function runV31UpgradeScenario(scenario: V31UpgradeScenario): Promise<void> {
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

    // ── Transfer L1 contract ownership to governance ──
    console.log("\n── Preparing L1 ownership for upgrade ──");
    await transferL1Ownership(l1Provider, defaultSigner, l1Addresses, ctmAddresses, scenario);

    // ── Deploy ChainAdmin for each upgrade target ──
    console.log("\n── Deploying temporary ChainAdminOwnable contracts ──");
    await deployChainAdmins(l1Provider, defaultSigner, upgradeChainAddresses);

    // ── Run ecosystem upgrade forge scripts (L1 deployments) ──
    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
      l1Addresses,
      ctmAddresses,
      chainAddresses: upgradeChainAddresses,
    });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    console.log("\n── Preparing ecosystem upgrade bundles via protocol-ops ──");
    await runEcosystemUpgradeScripts({
      rpcUrl: l1Chain.rpcUrl,
      upgradeHarnessInputs,
      executeBundles: true,
    });

    // `upgrade-prepare-all` writes a single merged `ecosystem.toml` at the
    // canonical tracked path (`<env-out>/ecosystem.toml`, one level above
    // `prepare/`). It already contains stage-0/1/2 calls from core + every
    // CTM concatenated in source-order — no per-script split anymore.
    const prepareDir = path.join(upgradeHarnessInputs.protocolOpsOutDir, "prepare");
    const mergedEcosystemToml = path.join(upgradeHarnessInputs.protocolOpsOutDir, "ecosystem.toml");
    if (!fs.existsSync(mergedEcosystemToml)) {
      throw new Error(`Merged ecosystem TOML not emitted by upgrade-prepare-all: ${mergedEcosystemToml}`);
    }
    const governanceTomlPaths = [mergedEcosystemToml];
    // Optional gov-upgrade TOML (PUH/Guardians redeploy). Picked up alongside
    // the ecosystem one when present.
    const govUpgradeToml = path.join(prepareDir, "gov-upgrade.toml");
    if (fs.existsSync(govUpgradeToml)) {
      governanceTomlPaths.push(govUpgradeToml);
    }

    // ── Execute governance calls (stages 0-2) via protocol-ops bundle ──
    console.log("\n── Replaying governance upgrade bundles ──");
    await runEcosystemGovernanceUpgrade({
      rpcUrl: l1Chain.rpcUrl,
      bridgehubAddress: upgradeHarnessInputs.bridgehubAddress,
      governanceTomlPaths,
      outDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "governance"),
      executeBundles: true,
    });

    // ── Prepare diamond state for chain upgrades ──
    if (scenario.clearGenesisUpgradeTxHash) {
      console.log("\n── Clearing legacy genesis upgrade tx hashes ──");
      await clearGenesisUpgradeTxHash(l1Provider, upgradeChainAddresses);
    }
    // ── Stage 3: post-governance migration ──
    // Runs BEFORE the per-chain upgrades, matching production sequencing (see
    // protocol-ops ecosystem stage3): every withdrawable L1-native asset must be registered and
    // populated by the time a chain's diamond upgrade lands.
    console.log("\n── Running stage3 post-governance migration ──");
    await runForgeScript({
      scriptPath: CORE_UPGRADE_TEST_SCRIPT,
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    // ── Run per-chain upgrades (L1) and relay to L2 ──
    // `default_upgrade_addr` lives in the per-CTM output TOML written by
    // `CTMUpgradeV31ForTests.saveOutput` directly to `script-out/` (forge
    // writes it there; protocol-ops no longer copies it into `prepare/`).
    const ctmTomlPath = path.join(
      l1ContractsDir,
      "script-out",
      `v31-upgrade-ctm-${upgradeHarnessInputs.ctmProxyAddress.toLowerCase()}.toml`
    );
    const ctmOutputToml = readEcosystemOutput(ctmTomlPath);
    const settlementLayerUpgradeAddr = readNestedString(
      ctmOutputToml,
      ["state_transition", "default_upgrade_addr"],
      "per-chain upgrade contract address"
    );
    await runChainUpgradesAndRelayL2({
      l1Provider,
      anvilManager,
      bridgehubAddr: l1Addresses.bridgehub,
      settlementLayerUpgradeAddr,
      ctmAddr: ctmAddresses.chainTypeManager,
      upgradeChainAddresses,
      protocolOpsOutDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "chains"),
    });
    console.log("\n── Chain upgrades complete, verifying final protocol versions ──");
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses, scenario.expectedProtocolVersion);
    console.log("✅ All protocol versions verified successfully!\n");
  } finally {
    if (cleanupUpgradeHarnessInputs) {
      cleanupUpgradeHarnessInputs();
    }
    if (!keepChains) {
      await anvilManager.stopAll();
    }
  }
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
    l1ChainAssetHandler?: string;
  },
  ctmAddresses: { chainTypeManager: string },
  scenario: V31UpgradeScenario
): Promise<void> {
  const gov = l1Addresses.governance;
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.bridgehub);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1SharedBridge);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NativeTokenVault);
  await transferOwnership2Step(provider, defaultSigner, gov, ctmAddresses.chainTypeManager);
  // A production ecosystem hands the nullifier to governance at deploy time; the fixtures leave it with
  // the deployer. Governance needs it to wire the interop handler in stage 1.
  if (l1Addresses.l1NullifierProxy) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NullifierProxy);
  }
  // The fixture leaves the ChainAssetHandler owned by its deployer, and this upgrade reuses that proxy
  // in place. Governance must own it to run the stage-0 pauseMigration() governance call.
  if (scenario.transferL1ChainAssetHandlerOwnership && l1Addresses.l1ChainAssetHandler) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1ChainAssetHandler);
  }
  await normalizeProxyAdminOwnerToEoa(provider, defaultSigner, ctmAddresses.chainTypeManager);
}

/**
 * Hand the CTM's ProxyAdmin to the deployer EOA when a contract owns it.
 *
 * For the upgrade scripts to issue calls from a contract owner, that owner has to be listed in
 * `ownable_proxies`, which reaches them only through protocol-ops' `--env` config — not available to this
 * harness, which passes addresses explicitly. So every owner has to be an EOA instead. In the v31 fixture
 * the CTM deployment leaves its ProxyAdmin owned by its own `Governance.sol` instance.
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

/**
 * Env-preset variant of `runEcosystemUpgradeScripts` for fork-mode upgrades
 * against a real env (stage / mainnet / testnet). Skips the synthetic
 * permanent-values templating the state-dump scenarios do — the env preset
 * already has the canonical bridgehub, ctm list, ownable_proxies, deployer,
 * etc. We override only the ones that change per fork run: `--out` (temp dir)
 * and `--l1-rpc-url` (the forked anvil instance).
 *
 * Uses the production CoreUpgrade_v31 / CTMUpgrade_v31 forge scripts via
 * protocol-ops defaults. Returns the dir the prepare phase wrote to.
 */
export async function runEcosystemUpgradeScriptsForEnv(params: {
  envName: string;
  rpcUrl: string;
  bridgehubAddress: string;
  outBaseDir: string;
  executeBundles?: boolean;
}): Promise<{ prepareOutDir: string }> {
  const prepareOutDir = path.join(params.outBaseDir, "prepare");
  fs.rmSync(prepareOutDir, { recursive: true, force: true });

  runProtocolOps([
    "ecosystem",
    "upgrade-prepare-all",
    "--env",
    params.envName,
    "--bridgehub",
    params.bridgehubAddress,
    "--l1-rpc-url",
    params.rpcUrl,
    "--out",
    prepareOutDir,
    "--additional-args=--memory-limit=536870912",
  ]);

  // protocol-ops runs forge against its own *nested* anvil that forks
  // `params.rpcUrl` and dies on process exit — none of the state writes it
  // made (including the GW-prep ZK funding) survive on the test harness's
  // anvil. The deployer's Safe bundle contains GatewayVotePreparation's
  // L1→L2 priority txs, each of which charges the GW base token (ZK) from
  // the bundle's impersonated sender. So before bundle replay, give that
  // sender enough ZK on *this* anvil via the same real-flow path —
  // impersonate the canonical NTV (the only `bridgeMint` caller) and mint.
  if (params.executeBundles) {
    await fundDeployerZkForBundleReplay({
      rpcUrl: params.rpcUrl,
      envName: params.envName,
      bridgehubAddress: params.bridgehubAddress,
      prepareOutDir,
    });
    await executeSafeBundles(prepareOutDir, params.rpcUrl);
  }
  return { prepareOutDir };
}

/// 1e30 wei (1B tokens for 18-decimal ZK) — matches the Rust side
/// `ZK_FUNDING_WEI_HEX` in `new_gateway_prepare.rs`. Comfortably covers
/// the ~580 ZK each GatewayVotePreparation priority tx charges.
const ZK_FUNDING_WEI = ethers.BigNumber.from("0xc9f2c9cd04674edea40000000");

/// Read `permanent-values/<env>.toml` and pull (a) whether a `[new_gateway]`
/// block is present and (b) the top-level `zk_token_asset_id` hex.
function readPermanentValuesForGwFunding(envName: string): {
  hasNewGateway: boolean;
  zkTokenAssetId: string | null;
} {
  const permPath = path.join(l1ContractsDir, "upgrade-envs", "permanent-values", `${envName}.toml`);
  if (!fs.existsSync(permPath)) {
    return { hasNewGateway: false, zkTokenAssetId: null };
  }
  const raw = fs.readFileSync(permPath, "utf8");
  let parsed: { new_gateway?: unknown; zk_token_asset_id?: unknown };
  try {
    parsed = parseToml(raw) as typeof parsed;
  } catch {
    return { hasNewGateway: false, zkTokenAssetId: null };
  }
  const zk = typeof parsed.zk_token_asset_id === "string" ? parsed.zk_token_asset_id : null;
  return { hasNewGateway: parsed.new_gateway != null, zkTokenAssetId: zk };
}

/// Read all bundle targets from `<prepareOutDir>/manifest.json` in bundle
/// order. `executeSafeBundles` impersonates each one in turn, so any of them
/// could be the `msg.sender` for a GW priority tx — we fund all to avoid
/// special-casing which bundle holds the GatewayVotePreparation deploys.
function bundleTargetsFromManifest(prepareOutDir: string): string[] {
  const manifestPath = path.join(prepareOutDir, "manifest.json");
  if (!fs.existsSync(manifestPath)) {
    return [];
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
    bundles?: Array<{ index?: number; target?: string }>;
  };
  const seen = new Set<string>();
  return (manifest.bundles ?? [])
    .filter((b): b is { index: number; target: string } => typeof b.index === "number" && typeof b.target === "string")
    .sort((a, b) => a.index - b.index)
    .map((b) => b.target.toLowerCase())
    .filter((t) => {
      if (seen.has(t)) return false;
      seen.add(t);
      return true;
    });
}

/// Mint ZK to every bundle target on the harness anvil via real-contract-call —
/// impersonate the NTV (only `onlyNTV` caller for `bridgeMint`) and call
/// `BridgedStandardERC20.bridgeMint(target, ZK_FUNDING_WEI)` per target.
/// No-ops silently when the env has no `[new_gateway]` (no GW priority txs
/// to fund) or no `zk_token_asset_id` (older envs).
async function fundDeployerZkForBundleReplay(params: {
  rpcUrl: string;
  envName: string;
  bridgehubAddress: string;
  prepareOutDir: string;
}): Promise<void> {
  const { hasNewGateway, zkTokenAssetId } = readPermanentValuesForGwFunding(params.envName);
  if (!hasNewGateway || !zkTokenAssetId) {
    return;
  }
  const targets = bundleTargetsFromManifest(params.prepareOutDir);
  if (targets.length === 0) {
    throw new Error(`Cannot fund bundle senders ZK: no usable bundle targets in ${params.prepareOutDir}/manifest.json`);
  }

  const provider = createProvider(params.rpcUrl);
  const bridgehub = new ethers.Contract(params.bridgehubAddress, getAbi("L1Bridgehub"), provider);
  const assetRouterAddr: string = await bridgehub.assetRouter();
  const assetRouter = new ethers.Contract(assetRouterAddr, getAbi("L1AssetRouter"), provider);
  const ntvAddr: string = await assetRouter.nativeTokenVault();
  const ntv = new ethers.Contract(ntvAddr, getAbi("L1NativeTokenVault"), provider);
  const zkTokenAddr: string = await ntv.tokenAddress(zkTokenAssetId);
  if (!zkTokenAddr || zkTokenAddr === ethers.constants.AddressZero) {
    throw new Error(`NTV.tokenAddress(${zkTokenAssetId}) returned zero on ${params.rpcUrl}`);
  }

  await provider.send("anvil_impersonateAccount", [ntvAddr]);
  await provider.send("anvil_setBalance", [ntvAddr, "0x21e19e0c9bab2400000"]); // 10k ETH for gas
  try {
    const ntvSigner = provider.getSigner(ntvAddr);
    const zkToken = new ethers.Contract(zkTokenAddr, getAbi("BridgedStandardERC20"), ntvSigner);
    for (const target of targets) {
      console.log(
        `  Funding bundle sender ${target} with ${ZK_FUNDING_WEI.toString()} wei ZK ` +
          `at ${zkTokenAddr} via NTV ${ntvAddr}.bridgeMint`
      );
      const tx = await zkToken.bridgeMint(target, ZK_FUNDING_WEI, { gasLimit: 1_000_000 });
      const receipt = await tx.wait();
      if (receipt.status !== 1) {
        throw new Error(`bridgeMint(${target}) reverted (tx ${receipt.transactionHash})`);
      }
    }
  } finally {
    await provider.send("anvil_stopImpersonatingAccount", [ntvAddr]);
  }
}

export async function runEcosystemUpgradeScripts(params: {
  rpcUrl: string;
  upgradeHarnessInputs: UpgradeHarnessInputs;
  executeBundles?: boolean;
}): Promise<void> {
  const prepareOutDir = path.join(params.upgradeHarnessInputs.protocolOpsOutDir, "prepare");
  fs.rmSync(prepareOutDir, { recursive: true, force: true });

  // Passed explicitly rather than auto-resolved from the CTM: a fork run may target an ecosystem whose
  // getters predate v31, and the snapshot config is authoritative for it.
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
      "--create2-factory-salt",
      params.upgradeHarnessInputs.create2FactorySalt,
      "--upgrade-input-path",
      params.upgradeHarnessInputs.upgradeInputArg,
      "--core-script-path",
      CORE_UPGRADE_TEST_SCRIPT,
      "--ctm-script-path",
      CTM_UPGRADE_TEST_SCRIPT,
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
  /// One or more governance TOMLs (one for the core prepare + one per CTM prepare).
  /// `upgrade-governance` orders calls by stage across all TOMLs and emits one bundle.
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

// ── Per-chain upgrade + L2 relay ─────────────────────────────────────

/** Render a checker error selector with its name for logs, e.g. "0x5c25a57b (LowerBoundNotRecorded)". */
function describeCheckerSelector(selector: string): string {
  try {
    const errorFragment = new ethers.utils.Interface(getAbi("V33UpgradePreconditionChecker")).getError(selector);
    return `${selector} (${errorFragment.name})`;
  } catch {
    return selector;
  }
}

/**
 * Assert the scheduling-time enforcement of the v32 upgrade prerequisite: the CTM-admin call set
 * (replayed with the prepare bundles) registered the release's precondition checker on the
 * ServerNotifier, so `setUpgradeTimestamp` must revert while the chain's backfill prerequisite is
 * missing. The expected failure is read from the on-chain preview rather than re-derived, so this
 * cannot drift from the checker's own ordering. Returns the handles for the post-shim positive
 * scheduling, or `null` when there is nothing to schedule against (chain outside the registration's
 * version, or facets too old for the preview). See {protocol-docs/upgrade-scheduling.md}.
 */
async function assertSchedulingBlockedOnMissingPrerequisite(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  ctmAddr: string;
  chainId: number;
  scheduleTimestamp: number;
  /** Env-preset rehearsals may target CTMs prepared by older tooling with no checker registered. */
  allowMissingChecker: boolean;
}): Promise<{ serverNotifier: ethers.Contract; chainAdmin: string; oldProtocolVersion: ethers.BigNumber } | null> {
  const { l1Provider, ctmAddr, chainId, scheduleTimestamp, allowMissingChecker } = params;

  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const serverNotifier = new ethers.Contract(await ctm.serverNotifierAddress(), getAbi("IServerNotifier"), l1Provider);
  const oldProtocolVersion: ethers.BigNumber = await ctm.getProtocolVersion(chainId);
  const checkerAddr: string = await serverNotifier.upgradePreconditionChecker(oldProtocolVersion);
  if (checkerAddr === ethers.constants.AddressZero) {
    // The release registers the checker under the CTM's prepare-time version, which is exactly
    // the version the target chains still report here (the CTM's own `protocolVersion()` has
    // already been bumped by governance stage 1, so it cannot serve as the comparison anchor).
    // A missing registration for a selected chain therefore means the CTM-admin call set failed —
    // and this test is the sole coverage of that registration through the production executor
    // path, so it must fail loudly. Only explicitly-allowed rehearsal shapes (env presets or
    // forks that may carry chains on other versions) tolerate it.
    if (!allowMissingChecker) {
      throw new Error(
        `chain ${chainId}: no precondition checker registered for its version ` +
          `${oldProtocolVersion.toString()} — the CTM-admin call set should have registered it ` +
          "(pass allowMissingChecker only for rehearsal shapes where this is expected)"
      );
    }
    console.log(
      `  ⚠️ chain ${chainId}: no precondition checker registered for its version ` +
        `${oldProtocolVersion.toString()}; skipping the scheduling assertions`
    );
    return null;
  }
  const chainAdmin: string = await ctm.getChainAdmin(chainId);

  // Ask the on-chain preview what scheduling would say right now. On a fork whose facets predate
  // the checker's getters the preview reverts (same guard as `modelV31BackfillPrerequisite`); such
  // a chain cannot be made schedulable by the shim either, so assert the block and skip scheduling.
  let failed: string[] | null = null;
  try {
    failed = await serverNotifier.previewUpgradePreconditions(chainId);
  } catch {
    failed = null;
  }

  if (failed === null) {
    await expectRevert(
      () => serverNotifier.callStatic.setUpgradeTimestamp(chainId, scheduleTimestamp, { from: chainAdmin }),
      `chain ${chainId}: scheduling on pre-checker facets`,
      undefined,
      l1Provider
    );
    console.log(
      `  ✅ chain ${chainId}: scheduling blocked (facets predate the checker's getters); ` +
        "skipping the positive scheduling"
    );
    return null;
  }

  if (failed.length === 0) {
    // Fork rehearsals can target a chain whose prerequisite is already satisfied (the bound was
    // recorded in an earlier run against the same CREATE2 registry) — nothing to block on.
    console.log(`  chain ${chainId}: prerequisite already satisfied; skipping the blocked-scheduling assertion`);
    return { serverNotifier, chainAdmin, oldProtocolVersion };
  }

  await expectRevert(
    () => serverNotifier.callStatic.setUpgradeTimestamp(chainId, scheduleTimestamp, { from: chainAdmin }),
    `chain ${chainId}: scheduling before the backfill prerequisite`,
    failed[0],
    l1Provider
  );
  console.log(
    `  ✅ chain ${chainId}: scheduling blocked with ${describeCheckerSelector(failed[0])} before the prerequisite`
  );

  return { serverNotifier, chainAdmin, oldProtocolVersion };
}

export async function runChainUpgradesAndRelayL2(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  anvilManager: AnvilManager;
  bridgehubAddr: string;
  settlementLayerUpgradeAddr: string;
  ctmAddr: string;
  upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  protocolOpsOutDir: string;
  /** Tolerate a CTM with no registered checker (env-preset rehearsals prepared by older tooling). */
  allowMissingChecker?: boolean;
}): Promise<void> {
  const {
    l1Provider,
    anvilManager,
    bridgehubAddr,
    settlementLayerUpgradeAddr,
    upgradeChainAddresses,
    protocolOpsOutDir,
  } = params;

  const settlementLayerUpgrade = new ethers.Contract(
    settlementLayerUpgradeAddr,
    getAbi("V32UpgradeZKsyncOS"),
    l1Provider
  );
  const l1Chain = anvilManager.getL1Chain()!;

  for (const chain of upgradeChainAddresses) {
    console.log(`\n── Chain ${chain.chainId}: running L1 upgrade + L2 relay ──`);
    const chainOutDir = path.join(protocolOpsOutDir, `chain-${chain.chainId}`);
    fs.rmSync(chainOutDir, { recursive: true, force: true });

    // The v31 per-chain upgrade required `totalBatchesCommitted ==
    // totalBatchesExecuted`. On a forked chain that has uncommitted-but-pending
    // batches at fork time, copy committed onto executed to model the
    // "all batches executed" prerequisite without running the executor.
    await forceBatchExecutedEqualsCommitted(l1Provider, chain.diamondProxy);

    // Scheduling-time enforcement of the same prerequisite the upgrade checks at execution time:
    // before the backfill history is modeled, the chain admin cannot even schedule the upgrade.
    const scheduleTimestamp = (await l1Provider.getBlock("latest")).timestamp + 3600;
    const scheduling = await assertSchedulingBlockedOnMissingPrerequisite({
      l1Provider,
      ctmAddr: params.ctmAddr,
      chainId: chain.chainId,
      scheduleTimestamp,
      allowMissingChecker: params.allowMissingChecker ?? false,
    });

    // ZKsync OS chains must additionally have the v31 base-token backfill behind them
    // (flag + executed-priority-op lower bound); model the missing history on the fork.
    await modelV31BackfillPrerequisite({
      l1Provider,
      diamondProxyAddr: chain.diamondProxy,
      settlementLayerUpgradeAddr,
    });

    if (scheduling) {
      // With the prerequisite in place, the preview clears and scheduling records the timestamp —
      // the real pre-upgrade operator step (production: protocol-ops `chain set-upgrade-timestamp`).
      const { serverNotifier, chainAdmin, oldProtocolVersion } = scheduling;
      const stillFailing: string[] = await serverNotifier.previewUpgradePreconditions(chain.chainId);
      if (stillFailing.length !== 0) {
        throw new Error(
          `chain ${chain.chainId}: preview still reports failed preconditions after the shim: ${stillFailing.join(", ")}`
        );
      }
      await impersonateAndRun(l1Provider, chainAdmin, async (signer) => {
        const tx = await serverNotifier
          .connect(signer)
          .setUpgradeTimestamp(chain.chainId, scheduleTimestamp, { gasLimit: 500_000 });
        await tx.wait();
      });
      const storedTimestamp: ethers.BigNumber = await serverNotifier.protocolVersionToUpgradeTimestamp(
        chain.chainId,
        oldProtocolVersion
      );
      if (!storedTimestamp.eq(scheduleTimestamp)) {
        throw new Error(
          `chain ${chain.chainId}: scheduling after the prerequisite stored ${storedTimestamp.toString()}, ` +
            `expected ${scheduleTimestamp}`
        );
      }
      console.log(`  ✅ chain ${chain.chainId}: upgrade scheduled once the prerequisite holds`);
    }

    runProtocolOps([
      "chain",
      "upgrade",
      "--bridgehub",
      bridgehubAddr,
      "--chain-id",
      String(chain.chainId),
      "--l1-rpc-url",
      l1Chain.rpcUrl,
      "--out",
      chainOutDir,
    ]);

    const safeBundles = safeBundlesInDir(chainOutDir);
    if (safeBundles.length !== 1) {
      throw new Error(`Expected one chain-upgrade Safe bundle for chain ${chain.chainId}, found ${safeBundles.length}`);
    }

    await executeSafeBundles(chainOutDir, l1Chain.rpcUrl);

    // Decode the L2 upgrade tx from the protocol-ops Safe bundle.
    const { tx: originalUpgradeTx, paramType: upgradeTxParamType } = decodeLatestL2UpgradeTx(safeBundles[0].file);
    const originalUpgradeTxData = originalUpgradeTx.data as string;

    // Rewrite the L2 upgrade tx with per-chain data, the same way the per-chain upgrade contract does.
    const rewrittenUpgradeTxData = await settlementLayerUpgrade.getL2UpgradeTxData(
      bridgehubAddr,
      chain.chainId,
      // `DefaultUpgradeZKsyncOS.getL2UpgradeTxData(..., bool isZKsyncOS, ...)` is audited; this
      // release only upgrades ZKsync OS chains.
      true,
      originalUpgradeTxData
    );

    // The chain must have recorded exactly this transaction. Without this check the relay below would
    // succeed even if the upgrade contract never rewrote the placeholder, since the rewrite is reproduced
    // here rather than read back from the diamond (the diamond only stores the hash).
    await assertRecordedUpgradeTxMatches({
      provider: l1Provider,
      diamondProxy: chain.diamondProxy,
      chainId: chain.chainId,
      upgradeTx: { ...originalUpgradeTx, data: rewrittenUpgradeTxData },
      placeholderUpgradeTx: originalUpgradeTx,
      upgradeTxParamType,
    });

    // Relay the upgrade to the L2 chain
    const l2Chain = anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }
    const l2Provider = createProvider(l2Chain.rpcUrl);

    const l2TxHash = await prepareAndRelayL2Upgrade(l2Provider, rewrittenUpgradeTxData);
    console.log(`  ✅ L2 upgrade relay tx: ${l2TxHash}`);
    printCastRunTrace(l2TxHash, l2Chain.rpcUrl);

    // Verify the L2 upgrade succeeded
    await verifyL2UpgradeResult(l2Provider, chain.chainId);
  }
}

/**
 * Multi-CTM aware variant of `runChainUpgradesAndRelayL2`. Used by env-preset
 * fork tests (e.g. stage) where the bridgehub has both an Era CTM and an
 * Atlas (zkOS) CTM, each with its own per-chain upgrade contract address. This release only produces one
 * for the ZKsync OS CTM (`CTMUpgrade_v31.deployUsedUpgradeContract` refuses Era), so the Era half of the
 * grouping stays empty here and is exercised only by fork runs against older ecosystems.
 *
 * Groups chains by their on-chain CTM, looks up the per-CTM
 * `script-out/v31-upgrade-ctm-<ctm>.toml` (written by
 * `CTMUpgrade_v31.noGovernancePrepare`) to get the settlement-layer-upgrade
 * address, then delegates to `runChainUpgradesAndRelayL2`
 * per group.
 *
 * Pass `skipL2Relay: true` to exercise the L1 chain-upgrade Safe bundle
 * without spinning up L2 forks (useful for L1-only smoke tests).
 */
export async function runChainUpgradesPerCtm(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  anvilManager: AnvilManager;
  bridgehubAddr: string;
  upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  protocolOpsOutDir: string;
  /// L1-only mode: run the per-chain L1 upgrade Safe bundle but skip the
  /// L2 relay (which requires an L2 fork). Default `false`.
  skipL2Relay?: boolean;
}): Promise<void> {
  const { l1Provider, anvilManager, bridgehubAddr, upgradeChainAddresses, protocolOpsOutDir, skipL2Relay } = params;

  const bridgehub = new ethers.Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Provider);

  // Group chains by their CTM. On stage / mainnet there are 2 (Era + Atlas).
  const groups = new Map<string, Array<{ chainId: number; diamondProxy: string }>>();
  for (const chain of upgradeChainAddresses) {
    const ctm: string = await bridgehub.chainTypeManager(chain.chainId);
    if (!ctm || ctm === ethers.constants.AddressZero) {
      throw new Error(`Chain ${chain.chainId}: no CTM registered on bridgehub`);
    }
    const key = ctm.toLowerCase();
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(chain);
  }

  for (const [ctmAddr, chains] of groups) {
    console.log(`\n── CTM ${ctmAddr}: running chain-upgrades for ${chains.length} chain(s) ──`);

    if (skipL2Relay) {
      // L1-only path: just emit + execute the per-chain Safe bundle. No
      // settlement-layer-upgrade lookup, no L2 relay.
      const l1Chain = anvilManager.getL1Chain()!;
      for (const chain of chains) {
        const chainOutDir = path.join(protocolOpsOutDir, `chain-${chain.chainId}`);
        fs.rmSync(chainOutDir, { recursive: true, force: true });
        await forceBatchExecutedEqualsCommitted(l1Provider, chain.diamondProxy);
        runProtocolOps([
          "chain",
          "upgrade",
          "--bridgehub",
          bridgehubAddr,
          "--chain-id",
          String(chain.chainId),
          "--l1-rpc-url",
          l1Chain.rpcUrl,
          "--out",
          chainOutDir,
        ]);
        await executeSafeBundles(chainOutDir, l1Chain.rpcUrl);
        console.log(`  ✅ chain ${chain.chainId} L1 upgrade applied`);
      }
      continue;
    }

    // Full path: read the settlement-layer-upgrade addr out of the per-CTM toml, then delegate to
    // the existing single-CTM helper.
    const ctmTomlPath = path.join(contractsRootDir, "l1-contracts", "script-out", `v31-upgrade-ctm-${ctmAddr}.toml`);
    if (!fs.existsSync(ctmTomlPath)) {
      throw new Error(`Missing per-CTM prepare output ${ctmTomlPath}. Did upgrade-prepare-all run for this CTM?`);
    }
    const ctmOutputToml = readEcosystemOutput(ctmTomlPath);
    const settlementLayerUpgradeAddr = readNestedString(
      ctmOutputToml,
      ["state_transition", "default_upgrade_addr"],
      "per-chain upgrade contract address"
    );

    await runChainUpgradesAndRelayL2({
      l1Provider,
      anvilManager,
      bridgehubAddr,
      settlementLayerUpgradeAddr,
      ctmAddr,
      upgradeChainAddresses: chains,
      protocolOpsOutDir,
      allowMissingChecker: true,
    });
  }
}

/**
 * Deploy all L2 system contracts, then relay the upgrade tx.
 *
 * On Anvil EVM, neither the Era ContractDeployer nor ZKsyncOS bytecode deployer
 * infrastructure works. Instead we:
 *   1. Pre-deploy all known contracts via anvil_setCode
 *   2. Place a MockContractDeployer at 0x8006
 */
async function prepareAndRelayL2Upgrade(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string
): Promise<string> {
  // Decode to extract addresses for pre-deployment, then send the ORIGINAL calldata.
  // MockContractDeployer (no-op) handles the force deployment calls from both the outer
  // ComplexUpgrader iteration and the inner performForceDeployedContractsInit calls.
  const { forceDeployEntries, delegateTo } = decodeUpgradeTxData(upgradeTxData);

  // Pre-deploy all L2 contracts via anvil_setCode
  await deployL2Contracts(l2Provider, forceDeployEntries, delegateTo);

  // Send the original upgrade calldata to ComplexUpgrader.
  // The outer force deployments no-op (MockContractDeployer), then upgrade() delegatecalls
  // to L2V32Upgrade which runs performForceDeployedContractsInit (inner deploys also no-op).
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

/**
 * Deploy all L2 system contracts needed for the upgrade via anvil_setCode.
 *
 * The force deployment list from the calldata tells us which addresses the
 * production upgrade deploys to. We place EVM bytecodes at those addresses
 * (and a few extra addresses called during the upgrade but not in the force
 * deployment list). A MockContractDeployer at 0x8006 no-ops the actual
 * force-deploy calls from both ComplexUpgrader and performForceDeployedContractsInit.
 *
 * For ZKsyncOS chains, contracts with ZKsyncOSSystemProxyUpgrade type are deployed
 * behind SystemContractProxy (matching production genesis layout):
 *   1. SystemContractProxy bytecode at the system address
 *   2. Implementation bytecode at a derived address (generateRandomAddress pattern)
 *   3. Proxy admin set to SystemContractProxyAdmin
 *   4. Implementation slot set to the derived address
 */
async function deployL2Contracts(
  l2Provider: ethers.providers.JsonRpcProvider,
  forceDeployEntries: ForceDeployEntry[],
  delegateTo: string
): Promise<void> {
  // MockContractDeployer: typed no-op `setBytecodeDetailsEVM` at the ContractDeployer address so
  // conductContractUpgrade() calls succeed. It implements the production IZKOSContractDeployer
  // interface and has no fallback, so any call with a stale or unexpected selector reverts loudly.
  await l2Provider.send("anvil_setCode", [L2_CONTRACT_DEPLOYER_ADDR, getBytecode("MockContractDeployer")]);

  // SystemContractProxyAdmin: _setupProxyAdmin() calls owner() and forceSetOwner().
  // For ZKsyncOS: use real SystemContractProxyAdmin — proper proxy setup means upgrade() works.
  // For Era: use real SystemContractProxyAdmin (upgrade() is not called by outer loop).
  await l2Provider.send("anvil_setCode", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    getBytecode("SystemContractProxyAdmin"),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    ethers.utils.hexZeroPad("0x0", 32), // slot 0: Ownable._owner
    ethers.utils.hexZeroPad(L2_COMPLEX_UPGRADER_ADDR, 32),
  ]);

  // Deploy EVM bytecodes at all addresses from the force deployment calldata.
  // For ZKsyncOS SystemProxyUpgrade entries, deploy behind a real SystemContractProxy.
  const contractMap = buildAddressToContract();
  for (const entry of forceDeployEntries) {
    // ZKsyncOSUnsafeForceDeployment entries are direct deployments (e.g. the SystemContractProxyAdmin
    // at L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, and L2V32Upgrade at a random delegate address).
    // Both are already set up above (anvil_setCode for the proxy admin, and the delegateTo code
    // is set separately below), so we skip them here.
    if (entry.upgradeType === UPGRADE_TYPE_ZKOS_UNSAFE_FORCE_DEPLOY) {
      continue;
    }

    const contractName = contractMap.get(entry.address.toLowerCase());
    if (!contractName) {
      // Era force deployments include the EmptyContract placeholder (0x0000), the EraVM
      // precompiles (0x0001..0x0008), and the system contracts at 0x800x (AccountCodeStorage,
      // NonceHolder, etc.). These are either not exercised by the anvil harness (precompiles)
      // or are already present in the loaded chain state, so we do not need to deploy
      // their bytecode via anvil_setCode. Skip silently for entries we do not know about.
      if (entry.upgradeType === UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT) {
        continue;
      }
      throw new Error(`No contract mapping for ZKsyncOS force deploy address ${entry.address}`);
    }

    if (entry.upgradeType === UPGRADE_TYPE_ZKOS_SYSTEM_PROXY) {
      if (!entry.deployedBytecodeInfo) {
        throw new Error(`ZKsyncOSSystemProxyUpgrade entry ${entry.address} missing deployedBytecodeInfo`);
      }
      await deployBehindSystemProxy(l2Provider, entry.address, getBytecode(contractName), entry.deployedBytecodeInfo);
    } else {
      await l2Provider.send("anvil_setCode", [entry.address, getBytecode(contractName)]);
    }
  }

  // Deploy the delegateTo target (L2V32Upgrade).
  await l2Provider.send("anvil_setCode", [delegateTo, getBytecode("L2V32Upgrade")]);

  // L2BaseToken is in the force deployment list as ZKsyncOSSystemProxyUpgrade, handled above.

  // L2BaseToken.initL2 (called on the genesis path of performForceDeployedContractsInit) mints an initial balance into the
  // BaseTokenHolder. For ZKsyncOS it mints via the MINT_BASE_TOKEN_HOOK system hook, which is a
  // no-op mock in the anvil harness. L2BaseToken then transfers ETH to the holder, so it needs a
  // non-zero balance on the anvil chain or the transfer reverts with "Address: insufficient balance".
  await l2Provider.send("anvil_setBalance", [L2_BASE_TOKEN_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE]);

  // Seed critical storage values on L2 contracts that were deployed via anvil_setCode
  // but never initialized. performForceDeployedContractsInit reads these before calling
  // updateL2, which reverts if WETH_TOKEN is zero.
  // Storage slots found via forge: NTV.WETH_TOKEN=251, NTV.L2_TOKEN_PROXY_BYTECODE_HASH=255,
  // NTV.L2_LEGACY_SHARED_BRIDGE=254, NTV.L1_CHAIN_ID=253, AR.L2_LEGACY_SHARED_BRIDGE=255.
  //
  // For ZKsyncOS, these contracts live behind SystemContractProxy, so storage writes go to the
  // proxy address (which delegates to the implementation). The storage layout is the same because
  // TransparentUpgradeableProxy uses EIP-1967 slots that don't collide with implementation storage.
  const toSlot = (n: number) => ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 32);
  const toAddr = (a: string) => ethers.utils.hexZeroPad(a, 32);

  // NTV: set WETH_TOKEN to the wrapped base token impl address (non-zero placeholder)
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_WETH_TOKEN_SLOT),
    toAddr(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR),
  ]);
  // NTV: set L1_CHAIN_ID
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_L1_CHAIN_ID_SLOT),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(runtimeConfig.l1ChainId), 32),
  ]);
  // NTV: set L2_TOKEN_PROXY_BYTECODE_HASH to a non-zero placeholder
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_L2_TOKEN_PROXY_BYTECODE_HASH_SLOT),
    ethers.utils.hexZeroPad("0x01", 32),
  ]);
  // AR: L2_LEGACY_SHARED_BRIDGE is zero (no legacy bridge) — no need to set
}

/**
 * Deploy a contract behind a SystemContractProxy on Anvil, matching ZKsyncOS production layout.
 *
 * 1. Compute derived implementation address: address(uint160(uint256(keccak256(bytes32(0) ++ implBytecode))))
 * 2. Deploy implementation bytecode at the derived address
 * 3. Deploy SystemContractProxy bytecode at the system address
 * 4. Set the proxy admin (EIP-1967 admin slot) to SystemContractProxyAdmin
 * 5. Set the implementation (EIP-1967 implementation slot) to the derived address
 *
 * TODO: This proxy setup should ideally be done during the chain state generation
 * (setup-and-dump-state.ts) so that the pre-generated states already have proper
 * SystemContractProxy layout at 0x800x addresses, matching production ZKsyncOS genesis.
 */
async function deployBehindSystemProxy(
  provider: ethers.providers.JsonRpcProvider,
  systemAddress: string,
  implBytecode: string,
  deployedBytecodeInfo: string
): Promise<void> {
  // Derive implementation address the same way L2GenesisForceDeploymentsHelper does on-chain:
  //   bytecodeInfo = abi.decode(deployedBytecodeInfo, (bytes, bytes))[0]
  //   implAddress = address(uint160(uint256(keccak256(bytes32(0) ++ bytecodeInfo))))
  // We need this exact address because the SystemContractProxy's `upgradeTo(implAddress)` will
  // revert with "ERC1967: new implementation is not a contract" if no code is deployed there.
  const [bytecodeInfo] = ethers.utils.defaultAbiCoder.decode(["bytes", "bytes"], deployedBytecodeInfo);
  const implAddressHash = ethers.utils.keccak256(ethers.utils.concat([ethers.constants.HashZero, bytecodeInfo]));
  const implAddress = ethers.utils.getAddress("0x" + implAddressHash.slice(26));

  // 1. Deploy implementation at derived address
  await provider.send("anvil_setCode", [implAddress, implBytecode]);

  // 2. Deploy SystemContractProxy at the system address
  await provider.send("anvil_setCode", [systemAddress, getBytecode("SystemContractProxy")]);

  // 3. Set admin to SystemContractProxyAdmin via EIP-1967 admin slot
  await provider.send("anvil_setStorageAt", [
    systemAddress,
    EIP1967_ADMIN_SLOT,
    ethers.utils.hexZeroPad(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, 32),
  ]);

  // 4. Set implementation via EIP-1967 implementation slot
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
  /// @dev For ZKsyncOS entries, the raw `deployedBytecodeInfo` bytes from the force deployment
  /// struct. For ZKsyncOSSystemProxyUpgrade it is `abi.encode(bytecodeInfo, bytecodeInfoSystemProxy)`;
  /// the on-chain `L2GenesisForceDeploymentsHelper` derives the implementation address via
  /// `keccak256(bytes32(0) ++ bytecodeInfo)`. We need the same derivation in the harness so that
  /// the SystemContractProxy's `upgradeTo(implAddress)` finds deployed EVM bytecode.
  deployedBytecodeInfo?: string;
}

/**
 * Decode the ComplexUpgrader calldata (any variant) into its three components:
 * force deployment entries (with upgrade type), delegateTo, and inner upgrade calldata.
 */
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
    return {
      forceDeployEntries: entries,
      delegateTo,
      innerCalldata,
    };
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
    return {
      forceDeployEntries: entries,
      delegateTo,
      innerCalldata,
    };
  }

  throw new Error(`Unknown ComplexUpgrader selector: ${selector}`);
}

/**
 * Extract the L2 upgrade tx data from a ChainUpgrade_v31 broadcast file.
 *
 * Walks transactions in reverse looking for a ChainAdminOwnable.multicall
 * containing a single upgradeChainFromVersion call, then extracts the
 * l2ProtocolUpgradeTx.data from the per-chain upgrade calldata.
 */
function decodeLatestL2UpgradeTx(broadcastPath: string): {
  tx: Record<string, unknown>;
  paramType: ethers.utils.ParamType;
} {
  const broadcast = JSON.parse(fs.readFileSync(broadcastPath, "utf8")) as {
    transactions?: Array<Record<string, unknown>>;
  };
  const transactions = broadcast.transactions || [];
  if (transactions.length === 0) {
    throw new Error(`No transactions found in broadcast file ${broadcastPath}`);
  }

  const chainAdminIface = new ethers.utils.Interface(getAbi("ChainAdminOwnable"));
  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
  // Legacy ABI: v29/v30 states have upgradeChainFromVersion(uint256, DiamondCutData) (2 params).
  // Current ABI has upgradeChainFromVersion(address, uint256, DiamondCutData) (3 params).
  const legacyAdminIface = new ethers.utils.Interface(LEGACY_ADMIN_ABI);
  const settlementLayerIface = new ethers.utils.Interface(getAbi("V32UpgradeZKsyncOS"));

  const errors: string[] = [];

  for (const transaction of [...transactions].reverse()) {
    const input = extractTxInput(transaction);
    if (typeof input !== "string" || input.length <= 10) {
      errors.push("tx skipped: input too short");
      continue;
    }

    try {
      const [calls] = chainAdminIface.decodeFunctionData("multicall", input);
      if (calls.length !== 1) {
        errors.push(`tx skipped: multicall has ${calls.length} calls, expected 1`);
        continue;
      }

      // Try current ABI (3-param) then legacy (2-param).
      // The DiamondCutData tuple is (facetCuts[], initAddress, initCalldata) — initCalldata is at index 2.
      let initCalldata: string;
      try {
        const diamondCut = adminIface.decodeFunctionData("upgradeChainFromVersion", calls[0].data)[2];
        initCalldata = diamondCut.initCalldata ?? diamondCut[2];
      } catch {
        const diamondCut = legacyAdminIface.decodeFunctionData("upgradeChainFromVersion", calls[0].data)[1];
        initCalldata = diamondCut.initCalldata ?? diamondCut[2];
      }

      const [proposedUpgrade] = settlementLayerIface.decodeFunctionData("upgrade", initCalldata);
      const proposedUpgradeType = settlementLayerIface.getFunction("upgrade").inputs[0];
      const txParamType = proposedUpgradeType.components.find((c) => c.name === "l2ProtocolUpgradeTx");
      if (!txParamType) {
        throw new Error("ProposedUpgrade ABI has no l2ProtocolUpgradeTx component");
      }
      return { tx: proposedUpgrade.l2ProtocolUpgradeTx, paramType: txParamType };
    } catch (e) {
      errors.push(`tx decode failed: ${e instanceof Error ? e.message.slice(0, 120) : String(e)}`);
      continue;
    }
  }

  throw new Error(
    `Missing upgradeChainFromVersion in ${broadcastPath}\n` +
      `  Transactions: ${transactions.length}\n` +
      errors.map((e) => `  - ${e}`).join("\n")
  );
}

/**
 * Assert the chain recorded the L2 upgrade transaction we are about to relay.
 *
 * `BaseZkSyncUpgrade` stores `keccak256(abi.encode(l2ProtocolUpgradeTx))`, so hashing the transaction with
 * the rewritten calldata and comparing proves the per-chain upgrade contract performed the same rewrite.
 */
async function assertRecordedUpgradeTxMatches(params: {
  provider: ethers.providers.JsonRpcProvider;
  diamondProxy: string;
  chainId: number;
  upgradeTx: Record<string, unknown>;
  placeholderUpgradeTx: Record<string, unknown>;
  upgradeTxParamType: ethers.utils.ParamType;
}): Promise<void> {
  const hashOf = (tx: Record<string, unknown>): string =>
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([params.upgradeTxParamType], [tx]));

  const expectedHash = hashOf(params.upgradeTx);
  const placeholderHash = hashOf(params.placeholderUpgradeTx);
  if (expectedHash === placeholderHash) {
    throw new Error(
      `Chain ${params.chainId}: the rewritten L2 upgrade tx is identical to the placeholder, so this check ` +
        "cannot tell whether the upgrade contract rewrote anything."
    );
  }

  const getters = new ethers.Contract(params.diamondProxy, getAbi("GettersFacet"), params.provider);
  const recordedHash: string = await getters.getL2SystemContractsUpgradeTxHash();

  if (recordedHash.toLowerCase() !== expectedHash.toLowerCase()) {
    throw new Error(
      `Chain ${params.chainId}: the diamond recorded L2 upgrade tx ${recordedHash}, but the transaction ` +
        `being relayed hashes to ${expectedHash}. The per-chain upgrade contract did not record the ` +
        "rewritten transaction."
    );
  }
  console.log(`   Recorded L2 upgrade tx hash matches the relayed transaction (${expectedHash})`);
}

/**
 * Run `cast run` to print the full transaction trace to stdout.
 * Non-fatal: logs a warning if cast is not available.
 */
function printCastRunTrace(txHash: string, rpcUrl: string): void {
  const cmd = `cast run ${txHash} -r ${rpcUrl}`;
  console.log(`\n  $ ${cmd}\n`);
  try {
    execSync(cmd, { stdio: "inherit", timeout: 30_000 });
  } catch {
    console.warn(`  ⚠ cast run failed or not available — run manually: ${cmd}`);
  }
}

/**
 * Trace a failed transaction via debug_traceTransaction and return a human-readable summary.
 */
async function traceFailedTx(provider: ethers.providers.JsonRpcProvider, txHash: string): Promise<string> {
  try {
    const tx = await provider.getTransaction(txHash);
    const receipt = await provider.getTransactionReceipt(txHash);
    const selector = tx.data?.slice(0, 10) ?? "unknown";
    const lines = [
      `  tx: ${txHash}`,
      `  from: ${tx.from}`,
      `  to: ${tx.to}`,
      `  selector: ${selector}`,
      `  gasUsed: ${receipt?.gasUsed?.toString() ?? "?"}`,
      `  block: ${receipt?.blockNumber ?? "?"}`,
    ];

    // Try to get revert reason via eth_call replay
    try {
      await provider.call(
        { from: tx.from, to: tx.to!, data: tx.data, value: tx.value, gasLimit: tx.gasLimit },
        receipt?.blockNumber ? receipt.blockNumber - 1 : "latest"
      );
    } catch (callErr: unknown) {
      const reason =
        callErr instanceof Error
          ? ((callErr as { reason?: string }).reason ?? callErr.message.slice(0, 200))
          : String(callErr).slice(0, 200);
      lines.push(`  revert reason: ${reason}`);
    }

    lines.push(`  Debug: cast run ${txHash} --rpc-url ${provider.connection.url}`);
    return lines.join("\n");
  } catch {
    return `  tx: ${txHash}\n  (could not fetch trace details)`;
  }
}

function extractTxInput(transaction: Record<string, unknown>): string | undefined {
  const inner = transaction.transaction as Record<string, unknown> | undefined;
  const candidate = inner?.input ?? inner?.data ?? transaction.input ?? transaction.data;
  return typeof candidate === "string" ? candidate : undefined;
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

// ── Governance calls ─────────────────────────────────────────────────

export function decodeGovernanceCalls(
  hexBytes: string
): Array<{ target: string; value: ethers.BigNumber; data: string }> {
  const [calls] = ethers.utils.defaultAbiCoder.decode(["tuple(address,uint256,bytes)[]"], hexBytes);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return calls.map((call: any) => ({ target: call[0], value: call[1], data: call[2] }));
}

export async function executeGovernanceCalls(
  provider: ethers.providers.JsonRpcProvider,
  governanceAddr: string,
  calls: Array<{ target: string; value: ethers.BigNumber; data: string }>,
  stageName: string
): Promise<void> {
  if (calls.length === 0) return;

  await provider.send("anvil_impersonateAccount", [governanceAddr]);
  await provider.send("anvil_setBalance", [governanceAddr, "0x56BC75E2D63100000"]);
  const signer = provider.getSigner(governanceAddr);

  for (let i = 0; i < calls.length; i++) {
    const tx = await signer.sendTransaction({
      to: calls[i].target,
      value: calls[i].value,
      data: calls[i].data,
      gasLimit: 30_000_000,
    });
    const receipt = await tx.wait();
    if (receipt.status !== 1) {
      const trace = await traceFailedTx(provider, receipt.transactionHash);
      throw new Error(`${stageName} call ${i + 1}/${calls.length} reverted:\n${trace}`);
    }
  }

  await provider.send("anvil_stopImpersonatingAccount", [governanceAddr]);
}

// ── Diamond state helpers ────────────────────────────────────────────

async function clearGenesisUpgradeTxHash(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  for (const chain of chains) {
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, "0x22", ethers.constants.HashZero]);
  }
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
  scenario: V31UpgradeScenario,
  state: {
    l1Addresses: { bridgehub: string; governance: string };
    ctmAddresses: { chainTypeManager: string };
    chainAddresses: Array<{ chainId: number }>;
  }
): {
  envVars: Record<string, string>;
  ecosystemOutputPath: string;
  governanceTomlPath: string;
  bridgehubAddress: string;
  protocolOpsOutDir: string;
  upgradeInputArg: string;
  ecosystemOutputArg: string;
  bytecodesSupplierAddress: string;
  rollupDaManagerAddress: string;
  create2FactorySalt: string;
  ctmProxyAddress: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${scenario.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${scenario.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${scenario.label}-upgrade-input.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${scenario.label}-upgrade-ecosystem.toml`);
  const governanceTomlPath = path.join(tempDir, `${scenario.label}-governance.toml`);
  const protocolOpsOutDir = path.join(tempDir, "protocol-ops");

  const primaryChainId = state.chainAddresses[0]?.chainId;
  if (!primaryChainId) throw new Error(`No chains loaded for ${scenario.label}`);

  let permanentValues = fs.readFileSync(path.join(l1ContractsDir, scenario.permanentValuesTemplatePath), "utf8");
  permanentValues = replaceTomlStringValue(permanentValues, "bridgehub_proxy_addr", state.l1Addresses.bridgehub);
  permanentValues = replaceTomlStringValue(permanentValues, "ctm_proxy_addr", state.ctmAddresses.chainTypeManager);
  fs.writeFileSync(permanentValuesPath, permanentValues);

  let upgradeInput = fs.readFileSync(path.join(l1ContractsDir, scenario.upgradeInputTemplatePath), "utf8");
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

  // stage3 reads a bridged-tokens config for legacy token migration.
  // In test environments there are no legacy bridged tokens, so provide an empty list.
  const bridgedTokensPath = path.join(tempDir, "v31-bridged-tokens.toml");
  fs.writeFileSync(bridgedTokensPath, "[tokens]\n");

  return {
    envVars: {
      PERMANENT_VALUES_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, permanentValuesPath)}`,
      UPGRADE_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
      UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
      UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, bridgedTokensPath)}`,
    },
    ecosystemOutputPath,
    governanceTomlPath,
    bridgehubAddress: state.l1Addresses.bridgehub,
    protocolOpsOutDir,
    upgradeInputArg: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
    ecosystemOutputArg: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
    bytecodesSupplierAddress:
      permanentValuesToml.ctm_contracts?.l1_bytecodes_supplier_addr ?? ethers.constants.AddressZero,
    rollupDaManagerAddress: permanentValuesToml.ctm_contracts?.rollup_da_manager ?? ethers.constants.AddressZero,
    create2FactorySalt: permanentValuesToml.permanent_contracts?.create2_factory_salt ?? ethers.constants.HashZero,
    ctmProxyAddress: state.ctmAddresses.chainTypeManager,
    cleanup: () => fs.rmSync(tempDir, { recursive: true, force: true }),
  };
}

// ── Misc helpers ─────────────────────────────────────────────────────

/** Build the address→contract map for the given VM type. */
function buildAddressToContract(): ReadonlyMap<string, ContractName> {
  const entries: Array<[string, ContractName]> = [
    [L2_MESSAGE_ROOT_ADDR.toLowerCase(), "L2MessageRoot"],
    [L2_BRIDGEHUB_ADDR.toLowerCase(), "L2Bridgehub"],
    [L2_ASSET_ROUTER_ADDR.toLowerCase(), "L2AssetRouter"],
    [L2_NATIVE_TOKEN_VAULT_ADDR.toLowerCase(), "L2NativeTokenVaultZKOS"],
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
  entries.push(
    // Atomic-interop built-ins: force-deployed by this release's upgrade on ZKsync OS chains.
    [L2_INTEROP_COMMITMENT_TREE_ADDR.toLowerCase(), "L2InteropCommitmentTree"],
    [L2_ATOMIC_FLOW_MANAGER_ADDR.toLowerCase(), "AtomicFlowManager"],
    [L2_BASE_TOKEN_ADDR.toLowerCase(), "L2BaseTokenZKOS"],
    [L2_TO_L1_MESSENGER_ADDR.toLowerCase(), "L1MessengerZKOS"],
    [SYSTEM_CONTEXT_ADDR.toLowerCase(), "SystemContext"],
    [L2_CONTRACT_DEPLOYER_ADDR.toLowerCase(), "ZKOSContractDeployer"],
    // The removed v31 GWAssetTracker: the upgrade swaps its proxy's implementation for EmptyContract.
    [L2_REMOVED_GW_ASSET_TRACKER_ADDR.toLowerCase(), "EmptyContract"]
  );
  return new Map(entries);
}

function selectUpgradeChains(
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>,
  chainConfigs: Array<{ chainId: number; role: ChainRole }>,
  targetRoles: ChainRole[]
): Array<{ chainId: number; diamondProxy: string }> {
  const roles = new Map(chainConfigs.map((c) => [c.chainId, c.role]));
  return chainAddresses.filter((chain) => {
    const role = roles.get(chain.chainId);
    if (!role) throw new Error(`Missing chain role for chain ${chain.chainId}`);
    return targetRoles.includes(role);
  });
}

export function readNestedString(obj: Record<string, unknown>, path: string[], label: string): string {
  let current: unknown = obj;
  for (const key of path) {
    if (!current || typeof current !== "object" || !(key in current)) {
      throw new Error(`Missing ${label} at ${path.join(".")}`);
    }
    current = (current as Record<string, unknown>)[key];
  }
  if (typeof current !== "string" || current.length === 0) {
    throw new Error(`Invalid ${label} at ${path.join(".")}`);
  }
  return current;
}

export function readEcosystemOutput(outputPath: string): Record<string, unknown> {
  if (!fs.existsSync(outputPath)) {
    throw new Error(`Ecosystem output not found at ${outputPath}`);
  }
  return parseToml(fs.readFileSync(outputPath, "utf-8")) as Record<string, unknown>;
}
