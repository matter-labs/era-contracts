import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import { runForgeScript } from "../core/forge";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_PRIVATE_KEY, L1_CHAIN_ID } from "../core/const";
import { L2_ASSET_TRACKER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR } from "../core/const";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { transferOwnable2Step } from "./harness-shims";
import { impersonateAndRun } from "../core/utils";

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");

export type V31UpgradeScenario = {
  label: string;
  stateVersion: string;
  permanentValuesTemplatePath: string;
  upgradeInputTemplatePath: string;
  isZKsyncOS: boolean;
};

function replaceTomlStringValue(contents: string, key: string, value: string): string {
  const pattern = new RegExp(`^(${key}\\s*=\\s*\").*(\")$`, "m");
  if (!pattern.test(contents)) {
    return contents;
  }
  return contents.replace(pattern, `$1${value}$2`);
}

function replaceTomlBareValue(contents: string, key: string, value: string): string {
  const pattern = new RegExp(`^(${key}\\s*=\\s*).*$`, "m");
  if (!pattern.test(contents)) {
    return `${contents.trimEnd()}\n${key} = ${value}\n`;
  }
  return contents.replace(pattern, `$1${value}`);
}

function prepareUpgradeHarnessInputs(
  scenario: V31UpgradeScenario,
  state: {
    l1Addresses: {
      bridgehub: string;
      governance: string;
    };
    ctmAddresses: {
      chainTypeManager: string;
    };
    chainAddresses: Array<{ chainId: number }>;
  }
): {
  envVars: Record<string, string>;
  ecosystemOutputPath: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${scenario.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${scenario.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${scenario.label}-to-v31-upgrade.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${scenario.label}-v31-upgrade-ecosystem.toml`);

  const primaryChainId = state.chainAddresses[0]?.chainId;
  if (!primaryChainId) {
    throw new Error(`No chains loaded for ${scenario.label}`);
  }

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
    cleanup: () => {
      fs.rmSync(tempDir, { recursive: true, force: true });
    },
  };
}

function readNestedString(value: Record<string, unknown>, pathSegments: string[], label: string): string {
  let current: unknown = value;
  for (const segment of pathSegments) {
    if (!current || typeof current !== "object" || !(segment in current)) {
      throw new Error(`Missing ${label} at ${pathSegments.join(".")}`);
    }
    current = (current as Record<string, unknown>)[segment];
  }

  if (typeof current !== "string" || current.length === 0) {
    throw new Error(`Invalid ${label} at ${pathSegments.join(".")}`);
  }

  return current;
}

function decodeLatestL2UpgradeTxData(broadcastPath: string): string {
  const broadcast = JSON.parse(fs.readFileSync(broadcastPath, "utf8")) as {
    transactions?: Array<{ input?: string; transaction?: { input?: string } }>;
  };
  const transactions = broadcast.transactions || [];
  if (transactions.length === 0) {
    throw new Error(`No transactions found in broadcast file ${broadcastPath}`);
  }

  const chainAdminIface = new ethers.utils.Interface(getAbi("ChainAdminOwnable"));
  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
  const settlementLayerUpgradeIface = new ethers.utils.Interface(getAbi("SettlementLayerV31Upgrade"));

  for (const transaction of [...transactions].reverse()) {
    const input = transaction.transaction?.input ?? transaction.input;
    if (typeof input !== "string" || input.length <= 10) {
      continue;
    }

    try {
      const multicallDecoded = chainAdminIface.decodeFunctionData("multicall", input);
      const calls = multicallDecoded[0] as Array<{ target: string; value: ethers.BigNumber; data: string }>;
      if (calls.length !== 1) {
        continue;
      }

      const adminCall = adminIface.decodeFunctionData("upgradeChainFromVersion", calls[0].data);
      const diamondCutData = adminCall[1] as { initCalldata: string };
      const proposedUpgrade = settlementLayerUpgradeIface.decodeFunctionData("upgrade", diamondCutData.initCalldata)[0] as {
        l2ProtocolUpgradeTx: { data: string };
      };

      return proposedUpgrade.l2ProtocolUpgradeTx.data;
    } catch {
      continue;
    }
  }

  throw new Error(`Missing upgradeChainFromVersion multicall input in ${broadcastPath}`);
}

function decodeGovernanceCalls(hexBytes: string): Array<{ target: string; value: ethers.BigNumber; data: string }> {
  const abiCoder = ethers.utils.defaultAbiCoder;
  const [calls] = abiCoder.decode(["tuple(address,uint256,bytes)[]"], hexBytes);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return calls.map((call: any) => ({
    target: call[0],
    value: call[1],
    data: call[2],
  }));
}

async function executeGovernanceCalls(
  provider: ethers.providers.JsonRpcProvider,
  governanceAddr: string,
  calls: Array<{ target: string; value: ethers.BigNumber; data: string }>,
  stageName: string
): Promise<void> {
  if (calls.length === 0) {
    return;
  }

  await provider.send("anvil_impersonateAccount", [governanceAddr]);
  await provider.send("anvil_setBalance", [governanceAddr, "0x56BC75E2D63100000"]);
  const signer = provider.getSigner(governanceAddr);

  for (let i = 0; i < calls.length; i++) {
    const call = calls[i];
    const tx = await signer.sendTransaction({
      to: call.target,
      value: call.value,
      data: call.data,
      gasLimit: 30_000_000,
    });
    const receipt = await tx.wait();
    if (receipt.status !== 1) {
      throw new Error(`${stageName} call ${i + 1} reverted (tx: ${receipt.transactionHash})`);
    }
  }

  await provider.send("anvil_stopImpersonatingAccount", [governanceAddr]);
}

async function transferOwnership2Step(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  governanceAddr: string,
  contractAddr: string
): Promise<void> {
  const ownableContract = new ethers.Contract(contractAddr, getAbi("Ownable2Step"), provider);
  const currentOwner = await ownableContract.owner();
  if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) {
    return;
  }
  if (currentOwner.toLowerCase() !== defaultSigner.address.toLowerCase()) {
    throw new Error(`Expected deployer to remain owner of ${contractAddr}, found ${currentOwner}`);
  }

  await transferOwnable2Step(provider, contractAddr, getAbi("Ownable2Step"), currentOwner, governanceAddr);
}

async function executeL2UpgradeTxs(
  l1Provider: ethers.providers.JsonRpcProvider,
  anvilManager: AnvilManager,
  bridgehubAddr: string,
  settlementLayerUpgradeAddr: string,
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>,
  upgradeTxDataByChainId: Map<number, string>
): Promise<void> {
  const settlementLayerUpgrade = new ethers.Contract(
    settlementLayerUpgradeAddr,
    getAbi("SettlementLayerV31Upgrade"),
    l1Provider
  );

  for (const chain of chainAddresses) {
    const l2Chain = anvilManager.getL2Chains().find((candidate) => candidate.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }

    const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
    const originalUpgradeTxData = upgradeTxDataByChainId.get(chain.chainId);
    if (!originalUpgradeTxData) {
      throw new Error(`Missing decoded L2 upgrade tx data for chain ${chain.chainId}`);
    }

    const rewrittenUpgradeTxData = await settlementLayerUpgrade.getL2UpgradeTxData(
      bridgehubAddr,
      chain.chainId,
      originalUpgradeTxData
    );

    const relayReceipt = await impersonateAndRun(l2Provider, L2_FORCE_DEPLOYER_ADDR, async (signer) => {
      const tx = await signer.sendTransaction({
        to: L2_COMPLEX_UPGRADER_ADDR,
        data: rewrittenUpgradeTxData,
        gasLimit: 100_000_000,
      });
      return tx.wait();
    });

    if (relayReceipt.status !== 1) {
      throw new Error(`L2 upgrade relay failed for chain ${chain.chainId}: ${relayReceipt.transactionHash}`);
    }

    const assetTracker = new ethers.Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Provider);
    const assetTrackerL1ChainId = await assetTracker.L1_CHAIN_ID();
    if (!assetTrackerL1ChainId.eq(L1_CHAIN_ID)) {
      throw new Error(
        `Chain ${chain.chainId} L2AssetTracker.L1_CHAIN_ID mismatch: expected ${L1_CHAIN_ID}, got ${assetTrackerL1ChainId.toString()}`
      );
    }

    const baseTokenAssetId = await assetTracker.BASE_TOKEN_ASSET_ID();
    const isBaseTokenRegistered = await assetTracker.isAssetRegistered(baseTokenAssetId);
    if (!isBaseTokenRegistered) {
      throw new Error(`Chain ${chain.chainId} base token was not registered by the relayed L2 upgrade`);
    }
  }
}

export async function runV31UpgradeScenario(scenario: V31UpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  let cleanupUpgradeHarnessInputs: (() => void) | null = null;

  try {
    const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
    if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
      throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
    }

    const { l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, stateDir);
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }

    const provider = new ethers.providers.JsonRpcProvider(l1Chain.rpcUrl);
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);

    await transferOwnership2Step(provider, defaultSigner, l1Addresses.governance, l1Addresses.bridgehub);
    await transferOwnership2Step(provider, defaultSigner, l1Addresses.governance, l1Addresses.l1SharedBridge);
    await transferOwnership2Step(provider, defaultSigner, l1Addresses.governance, ctmAddresses.chainTypeManager);
    await transferOwnership2Step(provider, defaultSigner, l1Addresses.governance, l1Addresses.l1AssetTracker);

    const chainAdminFactory = new ethers.ContractFactory(
      getAbi("ChainAdminOwnable"),
      getCreationBytecode("ChainAdminOwnable"),
      defaultSigner
    );

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const currentAdmin = await diamondProxy.getAdmin();
      const chainAdmin = await chainAdminFactory.deploy(ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_ACCOUNT_ADDR);
      await chainAdmin.deployed();

      await provider.send("anvil_impersonateAccount", [currentAdmin]);
      await provider.send("anvil_setBalance", [currentAdmin, "0x56BC75E2D63100000"]);
      const adminSigner = provider.getSigner(currentAdmin);
      const setPendingAdminData = new ethers.utils.Interface(getAbi("AdminFacet")).encodeFunctionData("setPendingAdmin", [
        chainAdmin.address,
      ]);
      const tx = await adminSigner.sendTransaction({
        to: chain.diamondProxy,
        data: setPendingAdminData,
        gasLimit: 1_000_000,
      });
      await tx.wait();
      await provider.send("anvil_stopImpersonatingAccount", [currentAdmin]);

      const acceptAdminData = new ethers.utils.Interface(getAbi("AdminFacet")).encodeFunctionData("acceptAdmin", []);
      const chainAdminContract = new ethers.Contract(chainAdmin.address, getAbi("ChainAdminOwnable"), defaultSigner);
      const multicallTx = await chainAdminContract.multicall(
        [{ target: chain.diamondProxy, value: 0, data: acceptAdminData }],
        true
      );
      await multicallTx.wait();
    }

    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, { l1Addresses, ctmAddresses, chainAddresses });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "run()",
    });

    const ecosystemOutputPath = upgradeHarnessInputs.ecosystemOutputPath;
    if (!fs.existsSync(ecosystemOutputPath)) {
      throw new Error(`Ecosystem output not found at ${ecosystemOutputPath}`);
    }

    const outputToml = parseToml(fs.readFileSync(ecosystemOutputPath, "utf-8")) as Record<string, unknown>;
    const govCalls = outputToml.governance_calls as Record<string, string> | undefined;
    if (!govCalls) {
      throw new Error("No governance_calls section in ecosystem output");
    }

    await executeGovernanceCalls(provider, l1Addresses.governance, decodeGovernanceCalls(govCalls.stage0_calls), "Stage 0");
    await executeGovernanceCalls(provider, l1Addresses.governance, decodeGovernanceCalls(govCalls.stage1_calls), "Stage 1");
    await executeGovernanceCalls(provider, l1Addresses.governance, decodeGovernanceCalls(govCalls.stage2_calls), "Stage 2");

    const chainUpgradeBroadcastPath = path.join(
      l1ContractsDir,
      "broadcast/ChainUpgrade_v31.s.sol/31337/run-latest.json"
    );
    const upgradeTxDataByChainId = new Map<number, string>();

    for (const chain of chainAddresses) {
      await runForgeScript({
        scriptPath: "deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol:ChainUpgrade_v31",
        envVars: {},
        rpcUrl: l1Chain.rpcUrl,
        senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
        projectRoot: l1ContractsDir,
        sig: "run(address,uint256)",
        args: `${ctmAddresses.chainTypeManager} ${chain.chainId}`,
      });
      upgradeTxDataByChainId.set(chain.chainId, decodeLatestL2UpgradeTxData(chainUpgradeBroadcastPath));
    }

    const settlementLayerUpgradeAddr = readNestedString(
      outputToml,
      ["state_transition", "default_upgrade_addr"],
      "SettlementLayerV31Upgrade address"
    );

    await executeL2UpgradeTxs(
      provider,
      anvilManager,
      l1Addresses.bridgehub,
      settlementLayerUpgradeAddr,
      chainAddresses,
      upgradeTxDataByChainId
    );

    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    const expectedVersion = ethers.BigNumber.from("0x1f00000000");
    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const protocolVersion = await diamondProxy.getProtocolVersion();
      if (!protocolVersion.eq(expectedVersion)) {
        throw new Error(
          `Chain ${chain.chainId} protocol version mismatch: expected ${expectedVersion.toHexString()}, got ${protocolVersion.toHexString()}`
        );
      }
    }
  } finally {
    if (cleanupUpgradeHarnessInputs) {
      cleanupUpgradeHarnessInputs();
    }
    await anvilManager.stopAll();
  }
}
