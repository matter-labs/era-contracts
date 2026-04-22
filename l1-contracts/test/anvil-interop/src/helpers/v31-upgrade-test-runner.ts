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
  INITIAL_BASE_TOKEN_HOLDER_BALANCE,
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
  L2_INTEROP_ROOT_STORAGE_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
  NTV_WETH_TOKEN_SLOT,
  NTV_L1_CHAIN_ID_SLOT,
  NTV_L2_TOKEN_PROXY_BYTECODE_HASH_SLOT,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode, LEGACY_ADMIN_ABI, LEGACY_COMPLEX_UPGRADER_ABI } from "../core/contracts";
import type { ContractName } from "../core/contracts";
import { transferOwnable2Step } from "./harness-shims";
import { impersonateAndRun } from "../core/utils";
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
const ECOSYSTEM_UPGRADE_TEST_SCRIPT =
  "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:EcosystemUpgradeV31ForTests";

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
  // Split into two calls to reduce peak EVM memory and avoid broadcast deadlocks.
  // step2 loads all L2 bytecodes for the diamond cut AND generates governance calls — it
  // must be a single forge invocation because state-transition facet addresses, diamond-cut
  // data and other CTM state can't be reliably round-tripped through TOML between invocations.
  // It needs extra EVM memory (256MB) to hold the L2 bytecodes.
  await runForgeScript({ ...baseParams, sig: "step1()" });
  // step2 deploys CTM contracts + generates governance calls in a single forge invocation.
  // ZKsyncOS upgrades are more gas-intensive (larger bytecodes), so we raise both the EVM
  // memory limit and the gas limit to prevent OOG in the forge simulation.
  await runForgeScript({
    ...baseParams,
    sig: "step2()",
    extraForgeArgs: ["--memory-limit", "536870912", "--gas-limit", "18446744073709551615"],
  });
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
    getAbi(isZKsyncOS ? "ZKsyncOSSettlementLayerV31Upgrade" : "EraSettlementLayerV31Upgrade"),
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

    // getL2UpgradeTxData is called externally (not delegatecalled from the diamond),
    // so it reads s.zksyncOS from the upgrade contract's own storage. Seed it for ZKsyncOS chains.
    if (isZKsyncOS) {
      const ZKSYNC_OS_SLOT = ethers.utils.hexZeroPad(ethers.utils.hexlify(60), 32);
      const TRUE = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 32);
      await l1Provider.send("anvil_setStorageAt", [settlementLayerUpgradeAddr, ZKSYNC_OS_SLOT, TRUE]);
    }

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
 *   2. Place a MockContractDeployer at 0x8006 so force-deployment phase by re-encoding as `upgrade(delegateTo, calldata)`
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
  const { forceDeployEntries, delegateTo } = decodeUpgradeTxData(upgradeTxData);

  // Pre-deploy all L2 contracts via anvil_setCode
  await deployL2Contracts(l2Provider, forceDeployEntries, delegateTo, isZKsyncOS);

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
  delegateTo: string,
  isZKsyncOS: boolean
): Promise<void> {
  // MockContractDeployer: no-op fallback at ContractDeployer address so that
  // forceDeployEra() and conductContractUpgrade() calls succeed silently.
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
  const contractMap = buildAddressToContract(isZKsyncOS);
  for (const entry of forceDeployEntries) {
    // ZKsyncOSUnsafeForceDeployment entries are direct deployments (e.g. the SystemContractProxyAdmin
    // at L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, and L2V31Upgrade at a random delegate address).
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
      // or are already present in the loaded v29/v30 chain state, so we do not need to deploy
      // their bytecode via anvil_setCode. Skip silently for entries we do not know about.
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

  // Deploy the delegateTo target (L2V31Upgrade).
  await l2Provider.send("anvil_setCode", [delegateTo, getBytecode("L2V31Upgrade")]);

  // L2BaseToken: for Era it's deployed directly as L2BaseTokenEra (not in force deployment list).
  // For ZKsyncOS it's in the force deployment list as ZKsyncOSSystemProxyUpgrade and handled above.
  if (!isZKsyncOS) {
    await l2Provider.send("anvil_setCode", [L2_BASE_TOKEN_ADDR, getBytecode("L2BaseTokenEra")]);
  }

  // L2BaseToken.initL2 (called from _initializeV31Contracts) mints an initial balance into the
  // BaseTokenHolder. For Era it reads the pre-existing __DEPRECATED_totalSupply; for ZKsyncOS it
  // mints via the MINT_BASE_TOKEN_HOOK system hook, which is a no-op mock in the anvil harness.
  // In both cases L2BaseToken then transfers ETH to the holder, so it needs a non-zero balance
  // on the anvil chain or the transfer reverts with "Address: insufficient balance".
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
    ethers.utils.hexZeroPad(ethers.utils.hexlify(L1_CHAIN_ID), 32),
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
 * TODO: This proxy setup should ideally be done during the V30 chain state generation
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
  const legacyAdminIface = new ethers.utils.Interface(LEGACY_ADMIN_ABI);
  const settlementLayerIface = new ethers.utils.Interface(getAbi("EraSettlementLayerV31Upgrade"));

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
    cleanup: () => fs.rmSync(tempDir, { recursive: true, force: true }),
  };
}

// ── Misc helpers ─────────────────────────────────────────────────────

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
    [L2_INTEROP_HANDLER_ADDR.toLowerCase(), "InteropHandler"],
    [L2_BASE_TOKEN_HOLDER_ADDR.toLowerCase(), "BaseTokenHolder"],
    [L2_WRAPPED_BASE_TOKEN_IMPL_ADDR.toLowerCase(), "L2WrappedBaseToken"],
    [GW_ASSET_TRACKER_ADDR.toLowerCase(), "GWAssetTracker"],
    [L2_MESSAGE_VERIFICATION_ADDR.toLowerCase(), "L2MessageVerification"],
    [L2_INTEROP_ROOT_STORAGE_ADDR.toLowerCase(), "L2InteropRootStorage"],
  ];
  if (isZKsyncOS) {
    entries.push(
      [L2_BASE_TOKEN_ADDR.toLowerCase(), "L2BaseTokenZKOS"],
      [L2_TO_L1_MESSENGER_ADDR.toLowerCase(), "L1MessengerZKOS"],
      [SYSTEM_CONTEXT_ADDR.toLowerCase(), "SystemContext"],
      [L2_CONTRACT_DEPLOYER_ADDR.toLowerCase(), "ZKOSContractDeployer"]
    );
  }
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
