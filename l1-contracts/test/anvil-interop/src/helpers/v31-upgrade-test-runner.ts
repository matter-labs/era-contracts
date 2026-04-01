import { execSync } from "child_process";
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
  GW_ASSET_TRACKER_ADDR,
  INTEROP_CENTER_ADDR,
  L1_CHAIN_ID,
  L2_ASSET_ROUTER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BASE_TOKEN_HOLDER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_CONTRACT_DEPLOYER_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";
import type { ContractName } from "../core/contracts";
import { transferOwnable2Step } from "./harness-shims";
import { impersonateAndRun } from "../core/utils";
import type { ChainRole } from "../core/types";

// ── Constants ────────────────────────────────────────────────────────

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");
const ECOSYSTEM_UPGRADE_TEST_SCRIPT =
  "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:EcosystemUpgradeV31ForTests";

// Function selectors for the various ComplexUpgrader entry points.
// All three variants share the same (forceDeployments[], address delegateTo, bytes calldata) shape;
// only the ForceDeployment tuple layout differs.
const SELECTORS = {
  // forceDeployAndUpgrade((bytes32,address,bool,uint256,bytes)[],address,bytes) — Era
  eraForceDeployAndUpgrade: "0x480d1185",
  // forceDeployAndUpgradeUniversal((bool,bytes,address)[],address,bytes) — ZKsyncOS v29
  universalV29: "0x05a33414",
  // forceDeployAndUpgradeUniversal((uint8,bytes,address)[],address,bytes) — ZKsyncOS v31
  universalV31: "0xd8cfca80",
} as const;

// ── Public types ─────────────────────────────────────────────────────

export type V31UpgradeScenario = {
  label: string;
  stateVersion: string;
  permanentValuesTemplatePath: string;
  upgradeInputTemplatePath: string;
  isZKsyncOS: boolean;
  targetRoles: ChainRole[];
  clearGenesisUpgradeTxHash?: boolean;
  seedBatchCounters?: boolean;
  transferL1AssetTrackerOwnership?: boolean;
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
    const l1Provider = new ethers.providers.JsonRpcProvider(l1Chain.rpcUrl);
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

    // ── Transfer L1 contract ownership to governance ──
    await transferL1Ownership(l1Provider, defaultSigner, l1Addresses, ctmAddresses, scenario);

    // ── Deploy ChainAdmin for each upgrade target ──
    await deployChainAdmins(l1Provider, defaultSigner, upgradeChainAddresses);

    // ── Run ecosystem upgrade forge scripts (L1 deployments) ──
    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
      l1Addresses,
      ctmAddresses,
      chainAddresses: upgradeChainAddresses,
    });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    await runEcosystemUpgradeScripts(l1Chain.rpcUrl, upgradeHarnessInputs.envVars);

    // ── Execute governance calls (stages 0-2) ──
    const outputToml = readEcosystemOutput(upgradeHarnessInputs.ecosystemOutputPath);
    const govCalls = outputToml.governance_calls as Record<string, string> | undefined;
    if (!govCalls) {
      throw new Error("No governance_calls section in ecosystem output");
    }
    await executeGovernanceCalls(
      l1Provider,
      l1Addresses.governance,
      decodeGovernanceCalls(govCalls.stage0_calls),
      "Stage 0"
    );
    await executeGovernanceCalls(
      l1Provider,
      l1Addresses.governance,
      decodeGovernanceCalls(govCalls.stage1_calls),
      "Stage 1"
    );
    await executeGovernanceCalls(
      l1Provider,
      l1Addresses.governance,
      decodeGovernanceCalls(govCalls.stage2_calls),
      "Stage 2"
    );

    // ── Prepare diamond state for chain upgrades ──
    if (scenario.clearGenesisUpgradeTxHash) {
      await clearGenesisUpgradeTxHash(l1Provider, upgradeChainAddresses);
    }
    if (scenario.seedBatchCounters) {
      await seedBatchCounters(l1Provider, upgradeChainAddresses);
    }

    // ── Run per-chain upgrades (L1) and relay to L2 ──
    const settlementLayerUpgradeAddr = readNestedString(
      outputToml,
      ["state_transition", "default_upgrade_addr"],
      "SettlementLayerV31Upgrade address"
    );
    await runChainUpgradesAndRelayL2({
      l1Provider,
      anvilManager,
      bridgehubAddr: l1Addresses.bridgehub,
      settlementLayerUpgradeAddr,
      ctmAddr: ctmAddresses.chainTypeManager,
      upgradeChainAddresses,
      isZKsyncOS: scenario.isZKsyncOS,
    });

    // ── Stage 3: post-governance migration ──
    await runForgeScript({
      scriptPath: ECOSYSTEM_UPGRADE_TEST_SCRIPT,
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });
    console.log("\n── Stage 3 complete, verifying final protocol versions ──");
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses);
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
    l1AssetTracker: string;
  },
  ctmAddresses: { chainTypeManager: string },
  scenario: V31UpgradeScenario
): Promise<void> {
  const gov = l1Addresses.governance;
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.bridgehub);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1SharedBridge);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NativeTokenVault);
  await transferOwnership2Step(provider, defaultSigner, gov, ctmAddresses.chainTypeManager);
  // The l1AssetTracker address points to the old L1ChainAssetHandler in pre-v31 states.
  // Governance needs ownership for pauseMigration() in stage 0.
  if (scenario.transferL1AssetTrackerOwnership) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1AssetTracker);
  }
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

// ── Ecosystem upgrade (L1 forge scripts) ─────────────────────────────

async function runEcosystemUpgradeScripts(rpcUrl: string, envVars: Record<string, string>): Promise<void> {
  const baseParams = {
    scriptPath: ECOSYSTEM_UPGRADE_TEST_SCRIPT,
    envVars,
    rpcUrl,
    senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
    projectRoot: l1ContractsDir,
  };
  // Split into two calls to avoid forge broadcast deadlock with anvil --block-time 1.
  // Step 1 deploys core L1 contracts (~12 txns), step 2 deploys CTM + governance (~25 txns).
  // Create2 deploys are idempotent, so step 2 re-initializing is safe.
  await runForgeScript({ ...baseParams, sig: "step1()" });
  await runForgeScript({ ...baseParams, sig: "step2()" });
}

// ── Per-chain upgrade + L2 relay ─────────────────────────────────────

async function runChainUpgradesAndRelayL2(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  anvilManager: AnvilManager;
  bridgehubAddr: string;
  settlementLayerUpgradeAddr: string;
  ctmAddr: string;
  upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  isZKsyncOS: boolean;
}): Promise<void> {
  const {
    l1Provider,
    anvilManager,
    bridgehubAddr,
    settlementLayerUpgradeAddr,
    ctmAddr,
    upgradeChainAddresses,
    isZKsyncOS,
  } = params;

  const settlementLayerUpgrade = new ethers.Contract(
    settlementLayerUpgradeAddr,
    getAbi("SettlementLayerV31Upgrade"),
    l1Provider
  );
  const l1Chain = anvilManager.getL1Chain()!;
  const broadcastPath = path.join(l1ContractsDir, "broadcast/ChainUpgrade_v31.s.sol/31337/run-latest.json");

  for (const chain of upgradeChainAddresses) {
    console.log(`\n── Chain ${chain.chainId}: running L1 upgrade + L2 relay ──`);
    // Run the L1 chain upgrade forge script
    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol:ChainUpgrade_v31",
      envVars: {},
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "run(address,uint256)",
      args: `${ctmAddr} ${chain.chainId}`,
    });

    // Decode the L2 upgrade tx from the broadcast
    const originalUpgradeTxData = decodeLatestL2UpgradeTxData(broadcastPath);

    // Rewrite the L2 upgrade tx with per-chain data via SettlementLayerV31Upgrade
    const rewrittenUpgradeTxData = await settlementLayerUpgrade.getL2UpgradeTxData(
      bridgehubAddr,
      chain.chainId,
      originalUpgradeTxData
    );

    // Relay the upgrade to the L2 chain
    const l2Chain = anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }
    const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);

    const l2TxHash = await prepareAndRelayL2Upgrade(l2Provider, rewrittenUpgradeTxData, isZKsyncOS);
    console.log(`  ✅ L2 upgrade relay tx: ${l2TxHash}`);
    printCastRunTrace(l2TxHash, l2Chain.rpcUrl);

    // Verify the L2 upgrade succeeded
    await verifyL2UpgradeResult(l2Provider, chain.chainId);
  }
}

/**
 * Deploy all L2 system contracts, then relay the upgrade tx.
 *
 * On Anvil EVM, neither the Era ContractDeployer nor ZKsyncOS bytecode deployer
 * infrastructure works. Instead we:
 *   1. Pre-deploy all known contracts via anvil_setCode
 *   2. Skip the force-deployment phase by re-encoding as `upgrade(delegateTo, calldata)`
 *   3. Send the upgrade tx which just delegatecalls to L2V31Upgrade
 */
async function prepareAndRelayL2Upgrade(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string,
  isZKsyncOS: boolean
): Promise<string> {
  // Decode to extract addresses for pre-deployment, then send the ORIGINAL calldata.
  // MockContractDeployer (no-op) handles the force deployment calls from both the outer
  // ComplexUpgrader iteration and the inner performForceDeployedContractsInit calls.
  const { forceDeployAddresses, delegateTo } = decodeUpgradeTxData(upgradeTxData);

  // Pre-deploy all L2 contracts via anvil_setCode
  await deployL2Contracts(l2Provider, forceDeployAddresses, delegateTo, isZKsyncOS);

  // Send the original upgrade calldata to ComplexUpgrader.
  // The outer force deployments no-op (MockContractDeployer), then upgrade() delegatecalls
  // to L2V31Upgrade which runs performForceDeployedContractsInit (inner deploys also no-op).
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
 */
async function deployL2Contracts(
  l2Provider: ethers.providers.JsonRpcProvider,
  forceDeployAddresses: string[],
  delegateTo: string,
  isZKsyncOS: boolean
): Promise<void> {
  // MockContractDeployer: no-op fallback at ContractDeployer address so that
  // forceDeployEra() and conductContractUpgrade() calls succeed silently.
  await l2Provider.send("anvil_setCode", [L2_CONTRACT_DEPLOYER_ADDR, getBytecode("MockContractDeployer")]);

  // Deploy EVM bytecodes at all addresses from the force deployment calldata.
  for (const addr of forceDeployAddresses) {
    const contractName = ADDRESS_TO_CONTRACT.get(addr.toLowerCase());
    if (contractName) {
      await l2Provider.send("anvil_setCode", [addr, getBytecode(contractName)]);
    }
  }

  // Deploy the delegateTo target (L2V31Upgrade).
  // The existing ComplexUpgrader from the v29/v30 state is used as-is — the L1 side
  // (SettlementLayerV31Upgrade) constructs calldata compatible with its ABI.
  await l2Provider.send("anvil_setCode", [delegateTo, getBytecode("L2V31Upgrade")]);

  if (isZKsyncOS) {
    // ZKsyncOS: conductContractUpgrade(ZKsyncOSSystemProxyUpgrade) calls
    // updateZKsyncOSContract → SystemContractProxyAdmin.upgrade(proxy, impl).
    // In production, the proxy is a SystemContractProxy and upgrade() calls upgradeTo().
    // On Anvil, the system addresses hold plain EVM implementations (not proxies), so
    // we use a no-op MockSystemContractProxyAdmin to prevent upgradeTo() from reverting.
    await l2Provider.send("anvil_setCode", [
      L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
      getBytecode("MockSystemContractProxyAdmin"),
    ]);
  }

  // L2BaseTokenEra (storage-based) instead of L2BaseTokenZKOS (MINT precompile).
  // L2V31Upgrade.upgrade() calls BaseToken.initL2() which on ZKsyncOS invokes
  // MINT_BASE_TOKEN_HOOK — a ZK-VM precompile that doesn't exist on Anvil.
  // L2BaseTokenEra uses storage-based balance tracking and works on both Era and ZKsyncOS.
  await l2Provider.send("anvil_setCode", [L2_BASE_TOKEN_ADDR, getBytecode("L2BaseTokenEra")]);
}

// ── Calldata decoding ────────────────────────────────────────────────

/**
 * Decode the ComplexUpgrader calldata (any variant) into its three components:
 * force deployment addresses, delegateTo, and inner upgrade calldata.
 */
function decodeUpgradeTxData(upgradeTxData: string): {
  forceDeployAddresses: string[];
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
    return {
      forceDeployAddresses: deployments.map((fd: { 1: string }) => fd[1]),
      delegateTo,
      innerCalldata,
    };
  }

  if (selector === SELECTORS.universalV29 || selector === SELECTORS.universalV31) {
    // v29 (bool,bytes,address) and v31 (uint8,bytes,address) have identical ABI encoding
    const [deployments, delegateTo, innerCalldata] = abiCoder.decode(
      ["tuple(uint8,bytes,address)[]", "address", "bytes"],
      payload
    );
    return {
      forceDeployAddresses: deployments.map((fd: { 2: string }) => fd[2]),
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
 * l2ProtocolUpgradeTx.data from the SettlementLayerV31Upgrade.upgrade calldata.
 */
function decodeLatestL2UpgradeTxData(broadcastPath: string): string {
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
  const legacyAdminIface = new ethers.utils.Interface([
    "function upgradeChainFromVersion(uint256, tuple(tuple(address,uint8,bool,bytes4[])[],address,bytes))",
  ]);
  const settlementLayerIface = new ethers.utils.Interface(getAbi("SettlementLayerV31Upgrade"));

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
      return proposedUpgrade.l2ProtocolUpgradeTx.data;
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
  if (!l1ChainId.eq(L1_CHAIN_ID)) {
    throw new Error(`Chain ${chainId}: L2AssetTracker.L1_CHAIN_ID = ${l1ChainId}, expected ${L1_CHAIN_ID}`);
  }

  const baseTokenAssetId = await assetTracker.BASE_TOKEN_ASSET_ID();
  const registered = await assetTracker.isAssetRegistered(baseTokenAssetId);
  if (!registered) {
    throw new Error(`Chain ${chainId}: base token not registered after L2 upgrade`);
  }
}

async function verifyProtocolVersions(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  const expectedVersion = ethers.BigNumber.from("0x1f00000000");
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

function decodeGovernanceCalls(hexBytes: string): Array<{ target: string; value: ethers.BigNumber; data: string }> {
  const [calls] = ethers.utils.defaultAbiCoder.decode(["tuple(address,uint256,bytes)[]"], hexBytes);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return calls.map((call: any) => ({ target: call[0], value: call[1], data: call[2] }));
}

async function executeGovernanceCalls(
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

async function seedBatchCounters(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  const TOTAL_BATCHES_EXECUTED_SLOT = ethers.utils.hexZeroPad(ethers.utils.hexlify(11), 32);
  const TOTAL_BATCHES_COMMITTED_SLOT = ethers.utils.hexZeroPad(ethers.utils.hexlify(13), 32);
  const ONE = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 32);

  for (const chain of chains) {
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, TOTAL_BATCHES_EXECUTED_SLOT, ONE]);
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, TOTAL_BATCHES_COMMITTED_SLOT, ONE]);
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

function prepareUpgradeHarnessInputs(
  scenario: V31UpgradeScenario,
  state: {
    l1Addresses: { bridgehub: string; governance: string };
    ctmAddresses: { chainTypeManager: string };
    chainAddresses: Array<{ chainId: number }>;
  }
): { envVars: Record<string, string>; ecosystemOutputPath: string; cleanup: () => void } {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${scenario.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${scenario.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${scenario.label}-to-v31-upgrade.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${scenario.label}-v31-upgrade-ecosystem.toml`);

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

  return {
    envVars: {
      PERMANENT_VALUES_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, permanentValuesPath)}`,
      UPGRADE_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
      UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
    },
    ecosystemOutputPath,
    cleanup: () => fs.rmSync(tempDir, { recursive: true, force: true }),
  };
}

// ── Misc helpers ─────────────────────────────────────────────────────

/**
 * Static mapping from well-known L2 system contract addresses to their EVM contract names.
 * Used to resolve force deployment addresses (from the upgrade calldata) to EVM bytecodes.
 * The addresses come from the calldata — this map only provides the name resolution.
 */
const ADDRESS_TO_CONTRACT: ReadonlyMap<string, ContractName> = new Map<string, ContractName>([
  [L2_MESSAGE_ROOT_ADDR.toLowerCase(), "L2MessageRoot"],
  [L2_BRIDGEHUB_ADDR.toLowerCase(), "L2Bridgehub"],
  [L2_ASSET_ROUTER_ADDR.toLowerCase(), "L2AssetRouter"],
  [L2_NATIVE_TOKEN_VAULT_ADDR.toLowerCase(), "L2NativeTokenVault"],
  [L2_CHAIN_ASSET_HANDLER_ADDR.toLowerCase(), "L2ChainAssetHandler"],
  [L2_ASSET_TRACKER_ADDR.toLowerCase(), "L2AssetTracker"],
  [INTEROP_CENTER_ADDR.toLowerCase(), "InteropCenter"],
  [L2_INTEROP_HANDLER_ADDR.toLowerCase(), "InteropHandler"],
  [L2_BASE_TOKEN_HOLDER_ADDR.toLowerCase(), "BaseTokenHolder"],
  [L2_WRAPPED_BASE_TOKEN_IMPL_ADDR.toLowerCase(), "L2WrappedBaseToken"],
  [GW_ASSET_TRACKER_ADDR.toLowerCase(), "GWAssetTracker"],
]);

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

function readNestedString(obj: Record<string, unknown>, path: string[], label: string): string {
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

function readEcosystemOutput(outputPath: string): Record<string, unknown> {
  if (!fs.existsSync(outputPath)) {
    throw new Error(`Ecosystem output not found at ${outputPath}`);
  }
  return parseToml(fs.readFileSync(outputPath, "utf-8")) as Record<string, unknown>;
}
