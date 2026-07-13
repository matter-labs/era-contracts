import { Command } from "commander";
import { BigNumber, ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const ADDRESS_ALIAS_OFFSET = BigNumber.from("0x1111000000000000000000000000000000001111");
const DETERMINISTIC_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const ZERO_ADDRESS = ethers.constants.AddressZero;
const LEGACY_TESTNET_GOVERNANCE_SECURITY_COUNCIL = "0x25Ab0397DA109A50C8921A1d4a034e0973602469";
const LEGACY_TESTNET_GOVERNANCE_MIN_DELAY = "0";

const ctmReadAbi = [
  "function owner() view returns (address)",
  "function protocolVersion() view returns (uint256)",
  "function validatorTimelockPostV29() view returns (address)",
  "function BRIDGE_HUB() view returns (address)",
];

const ctmEventsAbi = [
  "event NewChainCreationParams(address genesisUpgrade, bytes32 genesisBatchHash, uint64 genesisIndexRepeatedStorageChanges, bytes32 genesisBatchCommitment, tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata) newInitialCut, bytes32 newInitialCutHash, bytes forceDeploymentsData, bytes32 forceDeploymentHash)",
];

const bridgehubAbi = [
  "function owner() view returns (address)",
  "function admin() view returns (address)",
  "function assetRouter() view returns (address)",
];

const governanceAbi = [
  "function owner() view returns (address)",
  "function securityCouncil() view returns (address)",
  "function minDelay() view returns (uint256)",
];

const assetRouterAbi = ["function L1_WETH_TOKEN() view returns (address)"];
const validatorTimelockAbi = ["function executionDelay() view returns (uint32)"];
const verifierWrapperAbi = [
  "function FFLONK_VERIFIER() view returns (address)",
  "function PLONK_VERIFIER() view returns (address)",
  "function verify(uint256[] calldata,uint256[] calldata) view returns (bool)",
];

const diamondCutAbiType =
  "tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata)";
const initializeDataNewChainAbiType =
  "tuple(address verifier,tuple(bytes32 recursionNodeLevelVkHash,bytes32 recursionLeafLevelVkHash,bytes32 recursionCircuitsSetVksHash) verifierParams,bytes32 l2BootloaderBytecodeHash,bytes32 l2DefaultAccountBytecodeHash,bytes32 l2EvmEmulatorBytecodeHash,uint256 priorityTxMaxGasLimit,tuple(uint8 pubdataPricingMode,uint32 batchOverheadL1Gas,uint32 maxPubdataPerBatch,uint32 maxL2GasPerBatch,uint32 priorityTxMaxPubdata,uint64 minimalL2GasPrice) feeParams)";
const fixedForceDeploymentsAbiType =
  "tuple(uint256 l1ChainId,uint256 eraChainId,address l1AssetRouter,bytes32 l2TokenProxyBytecodeHash,address aliasedL1Governance,uint256 maxNumberOfZKChains,bytes32 bridgehubBytecodeHash,bytes32 l2AssetRouterBytecodeHash,bytes32 l2NtvBytecodeHash,bytes32 messageRootBytecodeHash,bytes32 chainAssetHandlerBytecodeHash,address l2SharedBridgeLegacyImpl,address l2BridgedStandardERC20Impl,address dangerousTestOnlyForcedBeacon)";

const ctmEventsInterface = new ethers.utils.Interface(ctmEventsAbi);

interface ScriptOptions {
  ctm: string;
  rpcUrl: string;
  output: string;
  targetBridgehub?: string;
  ownerAddress?: string;
  eraChainId?: string;
  create2FactorySalt?: string;
  create2FactoryAddr: string;
  chunkSize: number;
  throttleMs: number;
}

interface FixedForceDeploymentsData {
  l1ChainId: string;
  eraChainId: string;
  l1AssetRouter: string;
  l2TokenProxyBytecodeHash: string;
  aliasedL1Governance: string;
  maxNumberOfZKChains: string;
  bridgehubBytecodeHash: string;
  l2AssetRouterBytecodeHash: string;
  l2NtvBytecodeHash: string;
  messageRootBytecodeHash: string;
  chainAssetHandlerBytecodeHash: string;
  l2SharedBridgeLegacyImpl: string;
  l2BridgedStandardERC20Impl: string;
  dangerousTestOnlyForcedBeacon: string;
}

interface SourceContext {
  ctm: string;
  bridgehub: string;
  bridgehubOwner: string;
  governanceOwner: string;
  governanceSecurityCouncil: string;
  governanceMinDelay: string;
  assetRouter: string;
  wethToken: string;
  owner: string;
  protocolVersion: string;
  validatorTimelockPostV29: string;
  validatorTimelockExecutionDelay: string;
  deploymentBlock: number;
  latestChainCreationEvent: ethers.providers.Log;
  latestChainCreationParams: {
    genesisUpgrade: string;
    genesisBatchHash: string;
    genesisIndexRepeatedStorageChanges: string;
    genesisBatchCommitment: string;
    diamondCut: {
      initAddress: string;
      initCalldata: string;
      facetCuts: Array<{
        facet: string;
        action: number;
        isFreezable: boolean;
        selectors: string[];
      }>;
    };
    forceDeploymentsData: string;
    newInitialCutHash: string;
    forceDeploymentHash: string;
  };
  initializeDataNewChain: {
    verifier: string;
    verifierParams: {
      recursionNodeLevelVkHash: string;
      recursionLeafLevelVkHash: string;
      recursionCircuitsSetVksHash: string;
    };
    l2BootloaderBytecodeHash: string;
    l2DefaultAccountBytecodeHash: string;
    l2EvmEmulatorBytecodeHash: string;
    priorityTxMaxGasLimit: string;
    feeParams: {
      pubdataPricingMode: number;
      batchOverheadL1Gas: string;
      maxPubdataPerBatch: string;
      maxL2GasPerBatch: string;
      priorityTxMaxPubdata: string;
      minimalL2GasPrice: string;
    };
  };
  fixedForceDeploymentsData: FixedForceDeploymentsData;
  testnetVerifier: boolean;
}

interface TargetContext {
  bridgehub?: string;
  governance?: string;
  governanceOwner?: string;
  governanceSecurityCouncil?: string;
  governanceMinDelay?: string;
  assetRouter?: string;
  wethToken?: string;
  usedLegacyGovernanceFallback?: boolean;
}

function normalizeAddress(value: string): string {
  return ethers.utils.getAddress(value);
}

function normalizeHex(value: string): string {
  return ethers.utils.hexlify(value).toLowerCase();
}

function normalizeNumberish(value: ethers.BigNumberish): string {
  return BigNumber.from(value).toString();
}

function applyL1ToL2Alias(address: string): string {
  return normalizeAddress(ethers.utils.hexZeroPad(BigNumber.from(address).add(ADDRESS_ALIAS_OFFSET).toHexString(), 20));
}

function randomBytes32(): string {
  return ethers.utils.hexlify(ethers.utils.randomBytes(32));
}

async function readAddressCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<string> {
  const contract = new ethers.Contract(address, abi, provider);
  return normalizeAddress(await contract[method](...args));
}

async function readOptionalAddressCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<string | undefined> {
  try {
    return await readAddressCall(provider, address, abi, method, args);
  } catch {
    return undefined;
  }
}

async function readBigNumberCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<string> {
  const contract = new ethers.Contract(address, abi, provider);
  return normalizeNumberish(await contract[method](...args));
}

async function readOptionalBigNumberCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<string | undefined> {
  try {
    return await readBigNumberCall(provider, address, abi, method, args);
  } catch {
    return undefined;
  }
}

async function classifyVerifierWrapper(
  provider: ethers.providers.Provider,
  verifierAddress: string
): Promise<"DualVerifier" | "TestnetVerifier" | undefined> {
  try {
    const contract = new ethers.Contract(verifierAddress, verifierWrapperAbi, provider);
    await contract.callStatic.verify([], []);
    return "TestnetVerifier";
  } catch {
    try {
      await readAddressCall(provider, verifierAddress, verifierWrapperAbi, "FFLONK_VERIFIER");
      await readAddressCall(provider, verifierAddress, verifierWrapperAbi, "PLONK_VERIFIER");
      return "DualVerifier";
    } catch {
      return undefined;
    }
  }
}

async function findDeploymentBlock(provider: ethers.providers.JsonRpcProvider, contractAddress: string): Promise<number> {
  let left = 0;
  let right = await provider.getBlockNumber();

  while (left < right) {
    const middle = Math.floor((left + right) / 2);
    const code = await provider.getCode(contractAddress, middle);
    if (code === "0x") {
      left = middle + 1;
    } else {
      right = middle;
    }
  }

  return left;
}

async function findLatestChainCreationParamsEvent(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddress: string,
  deploymentBlock: number,
  chunkSize: number,
  throttleMs: number
): Promise<ethers.providers.Log> {
  const latestBlock = await provider.getBlockNumber();
  const topic0 = ctmEventsInterface.getEventTopic("NewChainCreationParams");

  let currentTo = latestBlock;
  while (currentTo >= deploymentBlock) {
    const currentFrom = Math.max(deploymentBlock, currentTo - chunkSize + 1);
    const logs = await provider.getLogs({
      address: ctmAddress,
      topics: [topic0],
      fromBlock: currentFrom,
      toBlock: currentTo,
    });

    if (logs.length > 0) {
      return logs.sort((left, right) => {
        if (left.blockNumber !== right.blockNumber) {
          return right.blockNumber - left.blockNumber;
        }
        return right.logIndex - left.logIndex;
      })[0];
    }

    currentTo = currentFrom - 1;
    if (currentTo >= deploymentBlock && throttleMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, throttleMs));
    }
  }

  throw new Error(`Could not find a NewChainCreationParams event for CTM ${ctmAddress}`);
}

function decodeInitializeDataNewChain(calldata: string) {
  const [decoded] = ethers.utils.defaultAbiCoder.decode([initializeDataNewChainAbiType], calldata);
  return {
    verifier: normalizeAddress(decoded.verifier),
    verifierParams: {
      recursionNodeLevelVkHash: normalizeHex(decoded.verifierParams.recursionNodeLevelVkHash),
      recursionLeafLevelVkHash: normalizeHex(decoded.verifierParams.recursionLeafLevelVkHash),
      recursionCircuitsSetVksHash: normalizeHex(decoded.verifierParams.recursionCircuitsSetVksHash),
    },
    l2BootloaderBytecodeHash: normalizeHex(decoded.l2BootloaderBytecodeHash),
    l2DefaultAccountBytecodeHash: normalizeHex(decoded.l2DefaultAccountBytecodeHash),
    l2EvmEmulatorBytecodeHash: normalizeHex(decoded.l2EvmEmulatorBytecodeHash),
    priorityTxMaxGasLimit: normalizeNumberish(decoded.priorityTxMaxGasLimit),
    feeParams: {
      pubdataPricingMode: Number(decoded.feeParams.pubdataPricingMode),
      batchOverheadL1Gas: normalizeNumberish(decoded.feeParams.batchOverheadL1Gas),
      maxPubdataPerBatch: normalizeNumberish(decoded.feeParams.maxPubdataPerBatch),
      maxL2GasPerBatch: normalizeNumberish(decoded.feeParams.maxL2GasPerBatch),
      priorityTxMaxPubdata: normalizeNumberish(decoded.feeParams.priorityTxMaxPubdata),
      minimalL2GasPrice: normalizeNumberish(decoded.feeParams.minimalL2GasPrice),
    },
  };
}

function decodeFixedForceDeploymentsData(data: string): FixedForceDeploymentsData {
  const [decoded] = ethers.utils.defaultAbiCoder.decode([fixedForceDeploymentsAbiType], data);
  return {
    l1ChainId: normalizeNumberish(decoded.l1ChainId),
    eraChainId: normalizeNumberish(decoded.eraChainId),
    l1AssetRouter: normalizeAddress(decoded.l1AssetRouter),
    l2TokenProxyBytecodeHash: normalizeHex(decoded.l2TokenProxyBytecodeHash),
    aliasedL1Governance: normalizeAddress(decoded.aliasedL1Governance),
    maxNumberOfZKChains: normalizeNumberish(decoded.maxNumberOfZKChains),
    bridgehubBytecodeHash: normalizeHex(decoded.bridgehubBytecodeHash),
    l2AssetRouterBytecodeHash: normalizeHex(decoded.l2AssetRouterBytecodeHash),
    l2NtvBytecodeHash: normalizeHex(decoded.l2NtvBytecodeHash),
    messageRootBytecodeHash: normalizeHex(decoded.messageRootBytecodeHash),
    chainAssetHandlerBytecodeHash: normalizeHex(decoded.chainAssetHandlerBytecodeHash),
    l2SharedBridgeLegacyImpl: normalizeAddress(decoded.l2SharedBridgeLegacyImpl),
    l2BridgedStandardERC20Impl: normalizeAddress(decoded.l2BridgedStandardERC20Impl),
    dangerousTestOnlyForcedBeacon: normalizeAddress(decoded.dangerousTestOnlyForcedBeacon),
  };
}

function encodeFixedForceDeploymentsData(data: FixedForceDeploymentsData): string {
  return ethers.utils.defaultAbiCoder.encode(
    [fixedForceDeploymentsAbiType],
    [
      {
        l1ChainId: data.l1ChainId,
        eraChainId: data.eraChainId,
        l1AssetRouter: data.l1AssetRouter,
        l2TokenProxyBytecodeHash: data.l2TokenProxyBytecodeHash,
        aliasedL1Governance: data.aliasedL1Governance,
        maxNumberOfZKChains: data.maxNumberOfZKChains,
        bridgehubBytecodeHash: data.bridgehubBytecodeHash,
        l2AssetRouterBytecodeHash: data.l2AssetRouterBytecodeHash,
        l2NtvBytecodeHash: data.l2NtvBytecodeHash,
        messageRootBytecodeHash: data.messageRootBytecodeHash,
        chainAssetHandlerBytecodeHash: data.chainAssetHandlerBytecodeHash,
        l2SharedBridgeLegacyImpl: data.l2SharedBridgeLegacyImpl,
        l2BridgedStandardERC20Impl: data.l2BridgedStandardERC20Impl,
        dangerousTestOnlyForcedBeacon: data.dangerousTestOnlyForcedBeacon,
      },
    ]
  );
}

async function buildSourceContext(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddress: string,
  chunkSize: number,
  throttleMs: number
): Promise<SourceContext> {
  const normalizedCtm = normalizeAddress(ctmAddress);
  const deploymentBlock = await findDeploymentBlock(provider, normalizedCtm);
  const latestLog = await findLatestChainCreationParamsEvent(provider, normalizedCtm, deploymentBlock, chunkSize, throttleMs);
  const parsed = ctmEventsInterface.parseLog(latestLog);

  const bridgehub = await readAddressCall(provider, normalizedCtm, ctmReadAbi, "BRIDGE_HUB");
  const bridgehubOwner = await readAddressCall(provider, bridgehub, bridgehubAbi, "owner");
  const assetRouter = await readAddressCall(provider, bridgehub, bridgehubAbi, "assetRouter");
  const wethToken = await readAddressCall(provider, assetRouter, assetRouterAbi, "L1_WETH_TOKEN");
  const protocolVersion = await readBigNumberCall(provider, normalizedCtm, ctmReadAbi, "protocolVersion");
  const validatorTimelockPostV29 = await readAddressCall(provider, normalizedCtm, ctmReadAbi, "validatorTimelockPostV29");
  const validatorTimelockExecutionDelay = await readBigNumberCall(
    provider,
    validatorTimelockPostV29,
    validatorTimelockAbi,
    "executionDelay"
  );

  const latestChainCreationParams = {
    genesisUpgrade: normalizeAddress(parsed.args.genesisUpgrade),
    genesisBatchHash: normalizeHex(parsed.args.genesisBatchHash),
    genesisIndexRepeatedStorageChanges: normalizeNumberish(parsed.args.genesisIndexRepeatedStorageChanges),
    genesisBatchCommitment: normalizeHex(parsed.args.genesisBatchCommitment),
    diamondCut: {
      initAddress: normalizeAddress(parsed.args.newInitialCut.initAddress),
      initCalldata: normalizeHex(parsed.args.newInitialCut.initCalldata),
      facetCuts: Array.from(parsed.args.newInitialCut.facetCuts ?? []).map((cut: any) => ({
        facet: normalizeAddress(cut.facet),
        action: Number(cut.action),
        isFreezable: Boolean(cut.isFreezable),
        selectors: Array.from(cut.selectors ?? []).map((selector: string) => selector.toLowerCase()),
      })),
    },
    forceDeploymentsData: normalizeHex(parsed.args.forceDeploymentsData),
    newInitialCutHash: normalizeHex(parsed.args.newInitialCutHash),
    forceDeploymentHash: normalizeHex(parsed.args.forceDeploymentHash),
  };

  const initializeDataNewChain = decodeInitializeDataNewChain(latestChainCreationParams.diamondCut.initCalldata);
  const fixedForceDeploymentsData = decodeFixedForceDeploymentsData(latestChainCreationParams.forceDeploymentsData);
  const verifierKind = await classifyVerifierWrapper(provider, initializeDataNewChain.verifier);
  const bridgehubOwnerCode = await provider.getCode(bridgehubOwner);
  const governanceOwner =
    bridgehubOwnerCode !== "0x"
      ? (await readOptionalAddressCall(provider, bridgehubOwner, governanceAbi, "owner")) ?? bridgehubOwner
      : bridgehubOwner;
  const governanceSecurityCouncil =
    bridgehubOwnerCode !== "0x"
      ? (await readOptionalAddressCall(provider, bridgehubOwner, governanceAbi, "securityCouncil")) ??
        LEGACY_TESTNET_GOVERNANCE_SECURITY_COUNCIL
      : LEGACY_TESTNET_GOVERNANCE_SECURITY_COUNCIL;
  const governanceMinDelay =
    bridgehubOwnerCode !== "0x"
      ? (await readOptionalBigNumberCall(provider, bridgehubOwner, governanceAbi, "minDelay")) ??
        LEGACY_TESTNET_GOVERNANCE_MIN_DELAY
      : LEGACY_TESTNET_GOVERNANCE_MIN_DELAY;

  return {
    ctm: normalizedCtm,
    bridgehub,
    bridgehubOwner,
    governanceOwner,
    governanceSecurityCouncil,
    governanceMinDelay,
    assetRouter,
    wethToken,
    owner: await readAddressCall(provider, normalizedCtm, ctmReadAbi, "owner"),
    protocolVersion,
    validatorTimelockPostV29,
    validatorTimelockExecutionDelay,
    deploymentBlock,
    latestChainCreationEvent: latestLog,
    latestChainCreationParams,
    initializeDataNewChain,
    fixedForceDeploymentsData,
    testnetVerifier: verifierKind === "TestnetVerifier",
  };
}

async function buildTargetContext(
  provider: ethers.providers.JsonRpcProvider,
  targetBridgehub: string | undefined
): Promise<TargetContext> {
  if (!targetBridgehub) {
    return {};
  }

  const bridgehub = normalizeAddress(targetBridgehub);
  const governance = await readAddressCall(provider, bridgehub, bridgehubAbi, "owner");
  const assetRouter = await readAddressCall(provider, bridgehub, bridgehubAbi, "assetRouter");
  const wethToken = await readAddressCall(provider, assetRouter, assetRouterAbi, "L1_WETH_TOKEN");

  let governanceOwner: string | undefined;
  let governanceSecurityCouncil = LEGACY_TESTNET_GOVERNANCE_SECURITY_COUNCIL;
  let governanceMinDelay = LEGACY_TESTNET_GOVERNANCE_MIN_DELAY;
  let usedLegacyGovernanceFallback = false;

  const governanceCode = await provider.getCode(governance);
  if (governanceCode !== "0x") {
    governanceOwner = await readOptionalAddressCall(provider, governance, governanceAbi, "owner");

    const discoveredSecurityCouncil = await readOptionalAddressCall(provider, governance, governanceAbi, "securityCouncil");
    if (discoveredSecurityCouncil) {
      governanceSecurityCouncil = discoveredSecurityCouncil;
    } else {
      usedLegacyGovernanceFallback = true;
    }

    const discoveredMinDelay = await readOptionalBigNumberCall(provider, governance, governanceAbi, "minDelay");
    if (discoveredMinDelay) {
      governanceMinDelay = discoveredMinDelay;
    } else {
      usedLegacyGovernanceFallback = true;
    }
  } else {
    governanceOwner = governance;
  }

  return {
    bridgehub,
    governance,
    governanceOwner,
    governanceSecurityCouncil,
    governanceMinDelay,
    assetRouter,
    wethToken,
    usedLegacyGovernanceFallback,
  };
}

function mergeFixedForceDeploymentsData(
  source: FixedForceDeploymentsData,
  target: TargetContext,
  l1ChainId: string,
  eraChainId: string
): FixedForceDeploymentsData {
  return {
    ...source,
    l1ChainId,
    eraChainId,
    l1AssetRouter: target.assetRouter ?? source.l1AssetRouter,
    aliasedL1Governance: target.governance ? applyL1ToL2Alias(target.governance) : source.aliasedL1Governance,
  };
}

function renderToml(params: {
  source: SourceContext;
  target: TargetContext;
  fixedForceDeploymentsData: FixedForceDeploymentsData;
  encodedForceDeploymentsData: string;
  eraChainId: string;
  ownerAddress: string;
  create2FactorySalt: string;
  create2FactoryAddr: string;
  l1ChainId: string;
}): string {
  const { source, target, fixedForceDeploymentsData, encodedForceDeploymentsData } = params;
  const supportLegacy = fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon !== ZERO_ADDRESS;
  const governanceSecurityCouncil = target.governanceSecurityCouncil ?? source.governanceSecurityCouncil;
  const governanceMinDelay = target.governanceMinDelay ?? source.governanceMinDelay;
  const wethToken = target.wethToken ?? source.wethToken;

  const targetNotes = target.bridgehub
    ? [
        `# Target bridgehub overrides were applied for the actual L1 contract fields.`,
        `# target_bridgehub = "${target.bridgehub}"`,
        `# target_governance = "${target.governance}"`,
      ]
    : [
        `# Warning: no target bridgehub was provided, so actual L1 contract fields inside`,
        `# force_deployments_data were copied from the source ecosystem.`,
      ];

  return `${targetNotes.join("\n")}
# Generated from source CTM ${source.ctm}
# Latest NewChainCreationParams event tx: ${source.latestChainCreationEvent.transactionHash}

era_chain_id = ${params.eraChainId}
owner_address = "${params.ownerAddress}"
testnet_verifier = ${source.testnetVerifier}
support_l2_legacy_shared_bridge_test = ${supportLegacy}

[gateway]
chain_id = 0

[contracts]
governance_security_council_address = "${governanceSecurityCouncil}"
governance_min_delay = ${governanceMinDelay}
max_number_of_chains = ${fixedForceDeploymentsData.maxNumberOfZKChains}
create2_factory_salt = "${params.create2FactorySalt}"
create2_factory_addr = "${params.create2FactoryAddr}"
validator_timelock_execution_delay = ${source.validatorTimelockExecutionDelay}
genesis_root = "${source.latestChainCreationParams.genesisBatchHash}"
genesis_rollup_leaf_index = ${source.latestChainCreationParams.genesisIndexRepeatedStorageChanges}
genesis_batch_commitment = "${source.latestChainCreationParams.genesisBatchCommitment}"
latest_protocol_version = ${source.protocolVersion}
recursion_node_level_vk_hash = "${source.initializeDataNewChain.verifierParams.recursionNodeLevelVkHash}"
recursion_leaf_level_vk_hash = "${source.initializeDataNewChain.verifierParams.recursionLeafLevelVkHash}"
recursion_circuits_set_vks_hash = "${source.initializeDataNewChain.verifierParams.recursionCircuitsSetVksHash}"
priority_tx_max_gas_limit = ${source.initializeDataNewChain.priorityTxMaxGasLimit}
diamond_init_pubdata_pricing_mode = ${source.initializeDataNewChain.feeParams.pubdataPricingMode}
diamond_init_batch_overhead_l1_gas = ${source.initializeDataNewChain.feeParams.batchOverheadL1Gas}
diamond_init_max_pubdata_per_batch = ${source.initializeDataNewChain.feeParams.maxPubdataPerBatch}
diamond_init_max_l2_gas_per_batch = ${source.initializeDataNewChain.feeParams.maxL2GasPerBatch}
diamond_init_priority_tx_max_pubdata = ${source.initializeDataNewChain.feeParams.priorityTxMaxPubdata}
diamond_init_minimal_l2_gas_price = ${source.initializeDataNewChain.feeParams.minimalL2GasPrice}
bootloader_hash = "${source.initializeDataNewChain.l2BootloaderBytecodeHash}"
default_aa_hash = "${source.initializeDataNewChain.l2DefaultAccountBytecodeHash}"
evm_emulator_hash = "${source.initializeDataNewChain.l2EvmEmulatorBytecodeHash}"
force_deployments_data = "${encodedForceDeploymentsData}"

[tokens]
token_weth_address = "${wethToken}"

[source_ctm]
address = "${source.ctm}"
bridgehub = "${source.bridgehub}"
deployment_block = ${source.deploymentBlock}
latest_chain_creation_block = ${source.latestChainCreationEvent.blockNumber}
latest_chain_creation_tx_hash = "${source.latestChainCreationEvent.transactionHash}"
validator_timelock_post_v29 = "${source.validatorTimelockPostV29}"
validator_timelock_execution_delay = ${source.validatorTimelockExecutionDelay}
protocol_version = ${source.protocolVersion}
chain_creation_params_init_address = "${source.latestChainCreationParams.diamondCut.initAddress}"
chain_creation_params_init_calldata = "${source.latestChainCreationParams.diamondCut.initCalldata}"
chain_creation_params_new_initial_cut_hash = "${source.latestChainCreationParams.newInitialCutHash}"
chain_creation_params_force_deployment_hash = "${source.latestChainCreationParams.forceDeploymentHash}"

[force_deployments]
l1_chain_id = ${fixedForceDeploymentsData.l1ChainId}
era_chain_id = ${fixedForceDeploymentsData.eraChainId}
l1_asset_router = "${fixedForceDeploymentsData.l1AssetRouter}"
l2_token_proxy_bytecode_hash = "${fixedForceDeploymentsData.l2TokenProxyBytecodeHash}"
aliased_l1_governance = "${fixedForceDeploymentsData.aliasedL1Governance}"
max_number_of_zk_chains = ${fixedForceDeploymentsData.maxNumberOfZKChains}
bridgehub_bytecode_hash = "${fixedForceDeploymentsData.bridgehubBytecodeHash}"
l2_asset_router_bytecode_hash = "${fixedForceDeploymentsData.l2AssetRouterBytecodeHash}"
l2_ntv_bytecode_hash = "${fixedForceDeploymentsData.l2NtvBytecodeHash}"
message_root_bytecode_hash = "${fixedForceDeploymentsData.messageRootBytecodeHash}"
chain_asset_handler_bytecode_hash = "${fixedForceDeploymentsData.chainAssetHandlerBytecodeHash}"
l2_shared_bridge_legacy_impl = "${fixedForceDeploymentsData.l2SharedBridgeLegacyImpl}"
l2_bridged_standard_erc20_impl = "${fixedForceDeploymentsData.l2BridgedStandardERC20Impl}"
dangerous_test_only_forced_beacon = "${fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon}"

[target]
bridgehub = "${target.bridgehub ?? ZERO_ADDRESS}"
governance = "${target.governance ?? source.bridgehubOwner}"
governance_owner = "${target.governanceOwner ?? source.governanceOwner}"
asset_router = "${target.assetRouter ?? source.assetRouter}"
token_weth_address = "${wethToken}"
l1_chain_id = ${params.l1ChainId}
`;
}

async function main() {
  const program = new Command();

  program
    .requiredOption("--ctm <address>", "Source CTM to clone")
    .requiredOption("--rpc-url <url>", "RPC URL")
    .option(
      "--output <path>",
      "Output TOML path",
      path.join(process.cwd(), "script-config", "config-deploy-cloned-ctm.toml")
    )
    .option("--target-bridgehub <address>", "Target Bridgehub whose L1 contracts should be used")
    .option("--owner-address <address>", "Owner EOA for the generated config")
    .option("--era-chain-id <id>", "Override era_chain_id / fixed force deployments eraChainId")
    .option("--create2-factory-salt <bytes32>", "Override create2 factory salt")
    .option("--create2-factory-addr <address>", "Create2 factory address", DETERMINISTIC_CREATE2_FACTORY)
    .option("--chunk-size <blocks>", "Backward scan chunk size", (value) => Number(value), 50_000)
    .option("--throttle-ms <ms>", "Delay between RPC log scans", (value) => Number(value), 0);

  program.parse(process.argv);
  const options = program.opts<ScriptOptions>();

  const provider = new ethers.providers.JsonRpcProvider(options.rpcUrl);
  const network = await provider.getNetwork();

  const source = await buildSourceContext(provider, options.ctm, options.chunkSize, options.throttleMs);
  const target = await buildTargetContext(provider, options.targetBridgehub);

  const ownerAddressInput = options.ownerAddress ?? target.governanceOwner;
  if (!ownerAddressInput) {
    throw new Error(
      "Could not determine owner_address from the target bridgehub. Pass --owner-address explicitly instead of reusing the source owner."
    );
  }
  const ownerAddress = normalizeAddress(ownerAddressInput);
  const eraChainId = options.eraChainId ?? source.fixedForceDeploymentsData.eraChainId;
  const create2FactorySalt = normalizeHex(options.create2FactorySalt ?? randomBytes32());
  const create2FactoryAddr = normalizeAddress(options.create2FactoryAddr);

  const mergedFixedForceDeployments = mergeFixedForceDeploymentsData(
    source.fixedForceDeploymentsData,
    target,
    String(network.chainId),
    String(eraChainId)
  );
  const encodedForceDeploymentsData = normalizeHex(encodeFixedForceDeploymentsData(mergedFixedForceDeployments));

  const toml = renderToml({
    source,
    target,
    fixedForceDeploymentsData: mergedFixedForceDeployments,
    encodedForceDeploymentsData,
    eraChainId: String(eraChainId),
    ownerAddress,
    create2FactorySalt,
    create2FactoryAddr,
    l1ChainId: String(network.chainId),
  });

  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  fs.writeFileSync(options.output, toml);

  const warnings: string[] = [];
  if (!options.targetBridgehub) {
    warnings.push("No target bridgehub was provided, so force_deployments_data still points at source L1 contracts.");
  }
  if (target.usedLegacyGovernanceFallback) {
    warnings.push(
      `Using governance fallback defaults when target governance introspection is incomplete: securityCouncil=${target.governanceSecurityCouncil}, minDelay=${target.governanceMinDelay}.`
    );
  }

  console.log(`Wrote cloned CTM config to ${options.output}`);
  console.log(`Source CTM: ${source.ctm}`);
  console.log(`Latest NewChainCreationParams tx: ${source.latestChainCreationEvent.transactionHash}`);
  console.log(`Target bridgehub: ${target.bridgehub ?? "(not provided)"}`);
  console.log(`owner_address: ${ownerAddress}`);
  console.log(`era_chain_id: ${eraChainId}`);
  console.log(`create2_factory_salt: ${create2FactorySalt}`);

  for (const warning of warnings) {
    console.warn(`Warning: ${warning}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
