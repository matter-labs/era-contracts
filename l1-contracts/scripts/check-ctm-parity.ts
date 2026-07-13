import { Command } from "commander";
import { BigNumber, ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

import {
  buildDescendingBlockRanges,
  ByteRange,
  ChainCreationParamsComparison,
  decodeConsistentImmutableNumberish,
  DiffRange,
  FacetCutComparison,
  FixedForceDeploymentsDataComparison,
  ParsedCtmEvent,
  compareFacetCuts,
  decodeFixedForceDeploymentsData,
  decodeImmutableValues,
  diffByteRanges,
  diffWordIndices,
  flattenImmutableReferences,
  getSolidityCborMetadataRange,
  maskHexAtRanges,
  normalizeAddress,
  normalizeHex,
  normalizeNumberish,
  normalizeSelectors,
  sleep,
  strip0x,
} from "./check-ctm-parity-utils";

type SectionName = "info" | "match" | "expected_diff" | "mismatch" | "best_effort";
type ComparisonMode = "exact" | "masked_immutables" | "raw_diff";
type ImmutablePolicy = "expected_same" | "expected_different" | "informational";

interface ArtifactLike {
  abi?: unknown;
  bytecode?: string | { object?: string };
  deployedBytecode?: string | { object?: string; immutableReferences?: Record<string, { start: number; length: number }[]> };
}

interface ReportItem {
  label: string;
  message: string;
  oldAddress?: string;
  newAddress?: string;
  comparisonMode?: ComparisonMode;
  diffRanges?: DiffRange[];
  decodedImmutables?: Record<
    string,
    {
      policy: ImmutablePolicy;
      old: string[];
      new: string[];
    }
  >;
  details?: Record<string, unknown>;
}

interface Report {
  info: ReportItem[];
  match: ReportItem[];
  expected_diff: ReportItem[];
  mismatch: ReportItem[];
  best_effort: ReportItem[];
}

interface ScriptOptions {
  oldCtm: string;
  newCtm: string;
  rpcUrl?: string;
  oldFromBlock?: number;
  newFromBlock?: number;
  chunkSize: number;
  throttleMs: number;
  json: boolean;
}

interface ProgressReporter {
  log(message: string): void;
}

interface CurrentCtmState {
  owner: string;
  pendingOwner?: string;
  admin: string;
  pendingAdmin?: string;
  storedBatchZero: string;
  initialCutHash: string;
  l1GenesisUpgrade: string;
  protocolVersion: string;
  protocolVersionDeadline: string;
  validatorTimelockPostV29: string;
  serverNotifierAddress: string;
  bridgeHub: string;
}

interface BridgehubState {
  address: string;
  owner: string;
  pendingOwner?: string;
  admin: string;
  assetRouter: string;
  ctmRegistered: boolean;
}

interface OwnershipState {
  owner?: string;
  pendingOwner?: string;
  admin?: string;
  pendingAdmin?: string;
}

interface ProxyControlState {
  proxyAddress: string;
  proxyAdminAddress: string;
  proxyAdminOwner?: string;
}

interface InitializeDataNewChainComparison {
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
}

interface ProxyInitializationSnapshot {
  implementation: string;
  admin: string;
  initializeData: {
    owner: string;
    validatorTimelock: string;
    chainCreationParams: ChainCreationParamsComparison;
    protocolVersion: string;
    serverNotifier: string;
  };
}

interface ComponentDescriptor {
  label: string;
  address: string;
  contractName: string;
  sourceContains?: string;
}

interface CtmSnapshot {
  label: string;
  ctmAddress: string;
  deploymentBlock: number;
  current: CurrentCtmState;
  bridgehub: BridgehubState;
  latestProtocolVersion: string;
  latestChainCreationParams: ChainCreationParamsComparison;
  initializeDataNewChain: InitializeDataNewChainComparison;
  proxyInitialization?: ProxyInitializationSnapshot;
  components: Record<string, ComponentDescriptor>;
  verifierWrapperKind?: "DualVerifier" | "TestnetVerifier";
  proxyControl?: ProxyControlState;
  validatorTimelockControl?: OwnershipState;
  validatorTimelockProxyControl?: ProxyControlState;
  serverNotifierControl?: OwnershipState;
  serverNotifierProxyControl?: ProxyControlState;
  rollupDAManagerControl?: OwnershipState;
}

interface LatestChainCreationCacheEntry {
  chainId: number;
  ctmAddress: string;
  fromBlock: number;
  scannedToBlock: number;
  foundAtBlock: number;
  foundAtLogIndex: number;
  chainCreationParams: ChainCreationParamsComparison;
}

const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const CTM_PENDING_ADMIN_SLOT = 162;
const EXPECTED_NEW_ERA_CHAIN_ID = "301";
const L1_TO_L2_ALIAS_OFFSET = BigNumber.from("0x1111000000000000000000000000000000001111");

const CtmReadAbi = [
  "function owner() view returns (address)",
  "function admin() view returns (address)",
  "function storedBatchZero() view returns (bytes32)",
  "function initialCutHash() view returns (bytes32)",
  "function l1GenesisUpgrade() view returns (address)",
  "function protocolVersion() view returns (uint256)",
  "function protocolVersionDeadline(uint256) view returns (uint256)",
  "function validatorTimelockPostV29() view returns (address)",
  "function serverNotifierAddress() view returns (address)",
  "function BRIDGE_HUB() view returns (address)",
  "function upgradeCutHash(uint256) view returns (bytes32)",
];

const CtmEventsAbi = [
  "event NewChainCreationParams(address genesisUpgrade, bytes32 genesisBatchHash, uint64 genesisIndexRepeatedStorageChanges, bytes32 genesisBatchCommitment, tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata) newInitialCut, bytes32 newInitialCutHash, bytes forceDeploymentsData, bytes32 forceDeploymentHash)",
  "event NewUpgradeCutHash(uint256 indexed protocolVersion, bytes32 indexed upgradeCutHash)",
  "event NewUpgradeCutData(uint256 indexed protocolVersion, tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata) diamondCutData)",
  "event NewProtocolVersion(uint256 indexed oldProtocolVersion, uint256 indexed newProtocolVersion)",
  "event UpdateProtocolVersionDeadline(uint256 indexed protocolVersion, uint256 deadline)",
  "event NewValidatorTimelock(address indexed oldValidatorTimelock, address indexed newValidatorTimelock)",
  "event NewValidatorTimelockPostV29(address indexed oldValidatorTimelockPostV29, address indexed newvalidatorTimelockPostV29)",
  "event NewServerNotifier(address indexed oldServerNotifier, address indexed newServerNotifier)",
  "event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin)",
  "event NewAdmin(address indexed oldAdmin, address indexed newAdmin)",
];

const BridgehubAbi = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function admin() view returns (address)",
  "function assetRouter() view returns (address)",
  "function chainTypeManagerIsRegistered(address) view returns (bool)",
];

const NamedFacetAbi = ["function getName() view returns (string)", "function getRollupDAManager() view returns (address)"];
const VerifierWrapperAbi = [
  "function FFLONK_VERIFIER() view returns (address)",
  "function PLONK_VERIFIER() view returns (address)",
  "function verify(uint256[] calldata,uint256[] calldata) view returns (bool)",
  "function verificationKeyHash() view returns (bytes32)",
];
const ServerNotifierAbi = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function chainTypeManager() view returns (address)",
];
const ValidatorTimelockAbi = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function executionDelay() view returns (uint32)",
  "function BRIDGE_HUB() view returns (address)",
];
const RollupDAManagerAbi = ["function owner() view returns (address)", "function pendingOwner() view returns (address)"];
const Ownable2StepAbi = ["function owner() view returns (address)", "function pendingOwner() view returns (address)"];
const ProxyAdminAbi = ["function owner() view returns (address)"];

const ctmReadInterface = new ethers.utils.Interface(CtmReadAbi);
const ctmEventsInterface = new ethers.utils.Interface(CtmEventsAbi);
const initializeInterface = new ethers.utils.Interface([
  "function initialize((address owner,address validatorTimelock,(address genesisUpgrade,bytes32 genesisBatchHash,uint64 genesisIndexRepeatedStorageChanges,bytes32 genesisBatchCommitment,(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata) diamondCut,bytes forceDeploymentsData) chainCreationParams,uint256 protocolVersion,address serverNotifier))",
]);

const diamondCutAbiType =
  "tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata)";
const initializeDataNewChainAbiType =
  "tuple(address verifier,tuple(bytes32 recursionNodeLevelVkHash,bytes32 recursionLeafLevelVkHash,bytes32 recursionCircuitsSetVksHash) verifierParams,bytes32 l2BootloaderBytecodeHash,bytes32 l2DefaultAccountBytecodeHash,bytes32 l2EvmEmulatorBytecodeHash,uint256 priorityTxMaxGasLimit,tuple(uint8 pubdataPricingMode,uint32 batchOverheadL1Gas,uint32 maxPubdataPerBatch,uint32 maxL2GasPerBatch,uint32 priorityTxMaxPubdata,uint64 minimalL2GasPrice) feeParams)";

const immutablePolicies: Record<string, Record<string, ImmutablePolicy>> = {
  ChainTypeManager: {
    BRIDGE_HUB: "expected_different",
  },
  AdminFacet: {
    L1_CHAIN_ID: "expected_same",
    ROLLUP_DA_MANAGER: "expected_different",
  },
  MailboxFacet: {
    ERA_CHAIN_ID: "expected_different",
    L1_CHAIN_ID: "expected_same",
  },
  ExecutorFacet: {
    L1_CHAIN_ID: "expected_same",
    COMMIT_TIMESTAMP_NOT_OLDER: "expected_same",
  },
  ValidatorTimelock: {
    BRIDGE_HUB: "expected_different",
  },
  DualVerifier: {
    FFLONK_VERIFIER: "expected_different",
    PLONK_VERIFIER: "expected_different",
  },
  TestnetVerifier: {
    FFLONK_VERIFIER: "expected_different",
    PLONK_VERIFIER: "expected_different",
  },
};

const componentHints: Record<string, { contractName: string; sourceContains?: string }> = {
  ChainTypeManagerImplementation: { contractName: "ChainTypeManager", sourceContains: "ChainTypeManager.sol" },
  AdminFacet: { contractName: "AdminFacet", sourceContains: "Admin.sol" },
  MailboxFacet: { contractName: "MailboxFacet", sourceContains: "Mailbox.sol" },
  ExecutorFacet: { contractName: "ExecutorFacet", sourceContains: "Executor.sol" },
  GettersFacet: { contractName: "GettersFacet", sourceContains: "Getters.sol" },
  DiamondInit: { contractName: "DiamondInit", sourceContains: "DiamondInit.sol" },
  L1GenesisUpgrade: { contractName: "L1GenesisUpgrade", sourceContains: "L1GenesisUpgrade.sol" },
  ValidatorTimelock: { contractName: "ValidatorTimelock", sourceContains: "ValidatorTimelock.sol" },
  ServerNotifier: { contractName: "ServerNotifier", sourceContains: "ServerNotifier.sol" },
  RollupDAManager: { contractName: "RollupDAManager", sourceContains: "RollupDAManager.sol" },
  L1VerifierFflonk: { contractName: "L1VerifierFflonk", sourceContains: "L1VerifierFflonk.sol" },
  L1VerifierPlonk: { contractName: "L1VerifierPlonk", sourceContains: "L1VerifierPlonk.sol" },
  DualVerifier: { contractName: "DualVerifier", sourceContains: "DualVerifier.sol" },
  TestnetVerifier: { contractName: "TestnetVerifier", sourceContains: "TestnetVerifier.sol" },
  TransparentUpgradeableProxy: {
    contractName: "TransparentUpgradeableProxy",
    sourceContains: "TransparentUpgradeableProxy.sol",
  },
};

let artifactPathCache: string[] | undefined;

function emptyReport(): Report {
  return {
    info: [],
    match: [],
    expected_diff: [],
    mismatch: [],
    best_effort: [],
  };
}

function pushReport(report: Report, section: SectionName, item: ReportItem) {
  report[section].push(item);
}

function repoRoot(): string {
  return path.resolve(__dirname, "..");
}

function cacheRoot(): string {
  return path.join(repoRoot(), ".cache", "check-ctm-parity");
}

function createProgressReporter(): ProgressReporter {
  return {
    log(message: string) {
      const timestamp = new Date().toISOString();
      process.stderr.write(`[check-ctm-parity ${timestamp}] ${message}\n`);
    },
  };
}

function latestChainCreationCachePath(chainId: number, ctmAddress: string): string {
  return path.join(cacheRoot(), `${chainId}-${normalizeAddress(ctmAddress)}.json`);
}

function readLatestChainCreationCache(
  chainId: number,
  ctmAddress: string,
  fromBlock: number
): LatestChainCreationCacheEntry | undefined {
  const normalizedAddress = normalizeAddress(ctmAddress);
  const canonicalPath = latestChainCreationCachePath(chainId, normalizedAddress);
  if (fs.existsSync(canonicalPath)) {
    const canonicalEntry = JSON.parse(fs.readFileSync(canonicalPath, "utf8")) as LatestChainCreationCacheEntry;
    if (canonicalEntry.foundAtBlock >= fromBlock) {
      return canonicalEntry;
    }
  }

  const legacyPrefix = `${chainId}-${normalizedAddress}-`;
  if (!fs.existsSync(cacheRoot())) {
    return undefined;
  }

  const legacyCandidates = fs
    .readdirSync(cacheRoot())
    .filter((fileName) => fileName.startsWith(legacyPrefix) && fileName.endsWith(".json"))
    .map((fileName) => path.join(cacheRoot(), fileName))
    .map((filePath) => JSON.parse(fs.readFileSync(filePath, "utf8")) as LatestChainCreationCacheEntry)
    .filter((entry) => entry.foundAtBlock >= fromBlock)
    .sort((left, right) => right.scannedToBlock - left.scannedToBlock);

  return legacyCandidates[0];
}

function writeLatestChainCreationCache(entry: LatestChainCreationCacheEntry) {
  fs.mkdirSync(cacheRoot(), { recursive: true });
  fs.writeFileSync(latestChainCreationCachePath(entry.chainId, entry.ctmAddress), `${JSON.stringify(entry, null, 2)}\n`);
}

function defaultRpcUrl(): string {
  const value = process.env.ETH_CLIENT_WEB3_URL;
  if (!value) {
    throw new Error("ETH_CLIENT_WEB3_URL is not set and --rpc-url was not provided");
  }
  return value.split(",")[0];
}

function walkJsonFiles(directory: string, accumulator: string[]) {
  if (!fs.existsSync(directory)) {
    return;
  }

  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const nextPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      walkJsonFiles(nextPath, accumulator);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".json")) {
      accumulator.push(nextPath);
    }
  }
}

function getArtifactJsonPaths(): string[] {
  if (artifactPathCache) {
    return artifactPathCache;
  }

  const root = repoRoot();
  const paths: string[] = [];
  walkJsonFiles(path.join(root, "out"), paths);
  walkJsonFiles(path.join(root, "zkout"), paths);
  artifactPathCache = paths;
  return paths;
}

function loadArtifact(contractName: string, sourceContains?: string): ArtifactLike | undefined {
  const candidates = getArtifactJsonPaths().filter((artifactPath) => {
    if (path.basename(artifactPath) !== `${contractName}.json`) {
      return false;
    }
    return !sourceContains || artifactPath.includes(sourceContains);
  });

  const artifactPath = candidates[0];
  if (!artifactPath) {
    return undefined;
  }

  return JSON.parse(fs.readFileSync(artifactPath, "utf8")) as ArtifactLike;
}

function extractArtifactBytecode(entry: ArtifactLike["bytecode"] | ArtifactLike["deployedBytecode"]): string | undefined {
  if (!entry) {
    return undefined;
  }
  if (typeof entry === "string") {
    return entry;
  }
  return entry.object;
}

function extractImmutableReferences(artifact?: ArtifactLike): Record<string, { start: number; length: number }[]> | undefined {
  if (!artifact || !artifact.deployedBytecode || typeof artifact.deployedBytecode === "string") {
    return undefined;
  }
  return artifact.deployedBytecode.immutableReferences;
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

async function readBytesCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<string> {
  const contract = new ethers.Contract(address, abi, provider);
  return normalizeHex(await contract[method](...args));
}

async function readBooleanCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string,
  args: unknown[] = []
): Promise<boolean> {
  const contract = new ethers.Contract(address, abi, provider);
  return Boolean(await contract[method](...args));
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
  } catch (error) {
    return undefined;
  }
}

async function readOptionalStringCall(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  method: string
): Promise<string | undefined> {
  try {
    const contract = new ethers.Contract(address, abi, provider);
    return String(await contract[method]());
  } catch (error) {
    return undefined;
  }
}

async function readOptionalPendingOwner(
  provider: ethers.providers.Provider,
  address: string
): Promise<string | undefined> {
  try {
    const pendingOwner = await readAddressCall(provider, address, Ownable2StepAbi, "pendingOwner");
    return pendingOwner === ethers.constants.AddressZero ? undefined : pendingOwner;
  } catch (error) {
    return undefined;
  }
}

async function getImplementationAddress(
  provider: ethers.providers.Provider,
  proxyAddress: string
): Promise<string> {
  const raw = await provider.getStorageAt(proxyAddress, IMPLEMENTATION_SLOT);
  return normalizeAddress(ethers.utils.getAddress(`0x${raw.slice(-40)}`));
}

async function getProxyAdminAddress(
  provider: ethers.providers.Provider,
  proxyAddress: string
): Promise<string> {
  const raw = await provider.getStorageAt(proxyAddress, ADMIN_SLOT);
  return normalizeAddress(ethers.utils.getAddress(`0x${raw.slice(-40)}`));
}

async function readAddressFromStorageSlot(
  provider: ethers.providers.Provider,
  contractAddress: string,
  slot: string | number
): Promise<string | undefined> {
  const raw = await provider.getStorageAt(contractAddress, slot);
  const value = ethers.utils.getAddress(`0x${raw.slice(-40)}`);
  if (value === ethers.constants.AddressZero) {
    return undefined;
  }
  return normalizeAddress(value);
}

async function findDeploymentBlock(
  provider: ethers.providers.Provider,
  contractAddress: string
): Promise<number> {
  const latestBlock = await provider.getBlockNumber();
  const currentCode = await provider.getCode(contractAddress, latestBlock);
  if (currentCode === "0x") {
    throw new Error(`No code found at ${contractAddress}`);
  }

  let left = 0;
  let right = latestBlock;
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

async function findDeploymentTransactionHash(
  provider: ethers.providers.Provider,
  contractAddress: string,
  deploymentBlock: number
): Promise<string | undefined> {
  const block = await provider.getBlockWithTransactions(deploymentBlock);
  for (const transaction of block.transactions) {
    if (transaction.to !== null) {
      continue;
    }
    const receipt = await provider.getTransactionReceipt(transaction.hash);
    if (receipt.contractAddress && normalizeAddress(receipt.contractAddress) === normalizeAddress(contractAddress)) {
      return transaction.hash;
    }
  }
  return undefined;
}

function decodeInitializeDataNewChain(calldata: string): InitializeDataNewChainComparison {
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

async function parseKnownCtmLog(log: ethers.providers.Log): Promise<ParsedCtmEvent | undefined> {
  try {
    const parsed = ctmEventsInterface.parseLog(log);
    return {
      name: parsed.name,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      args: parsed.args,
    };
  } catch (error) {
    return undefined;
  }
}

function normalizeChainCreationParams(raw: ethers.utils.Result): ChainCreationParamsComparison {
  return {
    genesisUpgrade: normalizeAddress(raw.genesisUpgrade),
    genesisBatchHash: normalizeHex(raw.genesisBatchHash),
    genesisIndexRepeatedStorageChanges: normalizeNumberish(raw.genesisIndexRepeatedStorageChanges),
    genesisBatchCommitment: normalizeHex(raw.genesisBatchCommitment),
    diamondCut: {
      initAddress: normalizeAddress(raw.newInitialCut.initAddress),
      initCalldata: normalizeHex(raw.newInitialCut.initCalldata),
      facetCuts: (raw.newInitialCut.facetCuts ?? []).map((cut: any, index: number) => ({
        label: `facet_${index}`,
        facetAddress: normalizeAddress(cut.facet),
        action: Number(cut.action),
        isFreezable: Boolean(cut.isFreezable),
        selectors: normalizeSelectors(Array.from(cut.selectors ?? [])),
      })),
    },
    forceDeploymentsData: normalizeHex(raw.forceDeploymentsData),
  };
}

async function findLatestCtmEvent(
  provider: ethers.providers.JsonRpcProvider,
  chainId: number,
  address: string,
  fromBlock: number,
  eventName: string,
  chunkSize: number,
  throttleMs: number,
  progress: ProgressReporter
): Promise<ChainCreationParamsComparison | undefined> {
  const latestBlock = await provider.getBlockNumber();
  const normalizedAddress = normalizeAddress(address);
  const cached = readLatestChainCreationCache(chainId, normalizedAddress, fromBlock);

  if (cached) {
    const validationFromBlock = Math.max(cached.scannedToBlock + 1, cached.foundAtBlock + 1, fromBlock);
    progress.log(
      `Found cached latest ${eventName} for ${normalizedAddress} at block ${cached.foundAtBlock}; validating blocks ${validationFromBlock}-${latestBlock}`
    );

    if (validationFromBlock > latestBlock) {
      progress.log(`Using cached latest ${eventName} for ${normalizedAddress} without rescanning`);
      return cached.chainCreationParams;
    }

    const candidate = await scanLatestCtmEventInRange(
      provider,
      normalizedAddress,
      validationFromBlock,
      latestBlock,
      eventName,
      chunkSize,
      throttleMs,
      progress
    );
    if (!candidate) {
      writeLatestChainCreationCache({
        ...cached,
        scannedToBlock: latestBlock,
      });
      progress.log(`No newer ${eventName} found for ${normalizedAddress}; refreshed cache coverage to block ${latestBlock}`);
      return cached.chainCreationParams;
    }

    const candidateParams = normalizeChainCreationParams(candidate.args);
    writeLatestChainCreationCache({
      chainId,
      ctmAddress: normalizedAddress,
      fromBlock,
      scannedToBlock: latestBlock,
      foundAtBlock: candidate.blockNumber,
      foundAtLogIndex: candidate.logIndex,
      chainCreationParams: candidateParams,
    });
    progress.log(`Updated cached latest ${eventName} for ${normalizedAddress} to block ${candidate.blockNumber}`);
    return candidateParams;
  }

  const found = await scanLatestCtmEventInRange(
    provider,
    normalizedAddress,
    fromBlock,
    latestBlock,
    eventName,
    chunkSize,
    throttleMs,
    progress
  );
  if (!found) {
    return undefined;
  }

  const normalizedChainCreationParams = normalizeChainCreationParams(found.args);
  writeLatestChainCreationCache({
    chainId,
    ctmAddress: normalizedAddress,
    fromBlock,
    scannedToBlock: latestBlock,
    foundAtBlock: found.blockNumber,
    foundAtLogIndex: found.logIndex,
    chainCreationParams: normalizedChainCreationParams,
  });
  progress.log(`Cached latest ${eventName} for ${normalizedAddress} from block ${found.blockNumber}`);
  return normalizedChainCreationParams;
}

async function scanLatestCtmEventInRange(
  provider: ethers.providers.JsonRpcProvider,
  address: string,
  fromBlock: number,
  toBlock: number,
  eventName: string,
  chunkSize: number,
  throttleMs: number,
  progress: ProgressReporter
): Promise<ParsedCtmEvent | undefined> {
  if (toBlock < fromBlock) {
    return undefined;
  }

  const topic = ctmEventsInterface.getEventTopic(eventName);
  const ranges = buildDescendingBlockRanges(fromBlock, toBlock, chunkSize);
  for (let index = 0; index < ranges.length; index += 1) {
    const range = ranges[index];
    progress.log(`Scanning ${eventName} for ${address} in block range ${range.fromBlock}-${range.toBlock}`);
    const logs = await provider.getLogs({
      address,
      topics: [topic],
      fromBlock: range.fromBlock,
      toBlock: range.toBlock,
    });

    for (let logIndex = logs.length - 1; logIndex >= 0; logIndex -= 1) {
      const parsed = await parseKnownCtmLog(logs[logIndex]);
      if (parsed?.name === eventName) {
        progress.log(`Found latest ${eventName} for ${address} at block ${parsed.blockNumber}, log ${parsed.logIndex}`);
        return parsed;
      }
    }

    if (index < ranges.length - 1 && throttleMs > 0) {
      await sleep(throttleMs);
    }
  }

  return undefined;
}

async function readProxyControlState(
  provider: ethers.providers.JsonRpcProvider,
  proxyAddress: string
): Promise<ProxyControlState> {
  const proxyAdminAddress = await getProxyAdminAddress(provider, proxyAddress);
  return {
    proxyAddress: normalizeAddress(proxyAddress),
    proxyAdminAddress,
    proxyAdminOwner: await readOptionalAddressCall(provider, proxyAdminAddress, ProxyAdminAbi, "owner"),
  };
}

async function ensureProxyUsesProxyAdminBytecode(
  provider: ethers.providers.Provider,
  report: Report,
  label: string,
  proxyControl: ProxyControlState
) {
  const artifact = loadArtifact("ProxyAdmin", "ProxyAdmin.sol");
  const expectedCode = extractArtifactBytecode(artifact?.deployedBytecode);
  const actualCode = normalizeHex(await provider.getCode(proxyControl.proxyAdminAddress));

  if (!expectedCode) {
    pushReport(report, "best_effort", {
      label: `${label}.proxyAdmin.bytecode`,
      message: `Could not conclusively validate ProxyAdmin bytecode for ${label}`,
      oldAddress: proxyControl.proxyAdminAddress,
    });
    return;
  }

  if (actualCode === "0x") {
    pushReport(report, "mismatch", {
      label: `${label}.proxyAdmin.bytecode`,
      message: `${label} proxy admin address has no code`,
      oldAddress: proxyControl.proxyAdminAddress,
    });
    return;
  }

  const normalizedExpectedCode = normalizeHex(expectedCode);
  if (normalizedExpectedCode === actualCode) {
    pushReport(report, "match", {
      label: `${label}.proxyAdmin.bytecode`,
      message: `${label} proxy admin uses ProxyAdmin bytecode`,
      oldAddress: proxyControl.proxyAdminAddress,
    });
    return;
  }

  const ranges = diffByteRanges(normalizedExpectedCode, actualCode);
  const expectedMetadataRange = getSolidityCborMetadataRange(normalizedExpectedCode);
  const actualMetadataRange = getSolidityCborMetadataRange(actualCode);
  if (areDiffRangesInsideMetadata(ranges, expectedMetadataRange, actualMetadataRange)) {
    pushReport(report, "match", {
      label: `${label}.proxyAdmin.bytecode`,
      message: `${label} proxy admin uses ProxyAdmin bytecode (CBOR metadata different)`,
      oldAddress: proxyControl.proxyAdminAddress,
      comparisonMode: "raw_diff",
      diffRanges: ranges,
      details: {
        cborMetadataOnly: true,
        expectedCborMetadataRange: expectedMetadataRange,
        actualCborMetadataRange: actualMetadataRange,
      },
    });
    return;
  }

  pushReport(report, "mismatch", {
    label: `${label}.proxyAdmin.bytecode`,
    message: `${label} proxy admin does not use ProxyAdmin bytecode`,
    oldAddress: proxyControl.proxyAdminAddress,
    comparisonMode: "raw_diff",
    diffRanges: ranges,
    details: {
      cborMetadataOnly: false,
      expectedCborMetadataRange: expectedMetadataRange,
      actualCborMetadataRange: actualMetadataRange,
    },
  });
}

async function labelFacetCuts(
  provider: ethers.providers.Provider,
  chainCreationParams: ChainCreationParamsComparison
): Promise<ChainCreationParamsComparison> {
  const labeledCuts: FacetCutComparison[] = [];
  for (let index = 0; index < chainCreationParams.diamondCut.facetCuts.length; index += 1) {
    const cut = chainCreationParams.diamondCut.facetCuts[index];
    const label = (await readOptionalStringCall(provider, cut.facetAddress!, NamedFacetAbi, "getName")) ?? cut.label;
    labeledCuts.push({
      ...cut,
      label,
    });
  }

  return {
    ...chainCreationParams,
    diamondCut: {
      ...chainCreationParams.diamondCut,
      facetCuts: labeledCuts,
    },
  };
}

async function readCurrentCtmState(
  provider: ethers.providers.Provider,
  ctmAddress: string
): Promise<CurrentCtmState> {
  const protocolVersion = await readBigNumberCall(provider, ctmAddress, CtmReadAbi, "protocolVersion");
  return {
    owner: await readAddressCall(provider, ctmAddress, CtmReadAbi, "owner"),
    pendingOwner: await readOptionalPendingOwner(provider, ctmAddress),
    admin: await readAddressCall(provider, ctmAddress, CtmReadAbi, "admin"),
    pendingAdmin: await readAddressFromStorageSlot(provider, ctmAddress, CTM_PENDING_ADMIN_SLOT),
    storedBatchZero: await readBytesCall(provider, ctmAddress, CtmReadAbi, "storedBatchZero"),
    initialCutHash: await readBytesCall(provider, ctmAddress, CtmReadAbi, "initialCutHash"),
    l1GenesisUpgrade: await readAddressCall(provider, ctmAddress, CtmReadAbi, "l1GenesisUpgrade"),
    protocolVersion,
    protocolVersionDeadline: await readBigNumberCall(provider, ctmAddress, CtmReadAbi, "protocolVersionDeadline", [
      protocolVersion,
    ]),
    validatorTimelockPostV29: await readAddressCall(provider, ctmAddress, CtmReadAbi, "validatorTimelockPostV29"),
    serverNotifierAddress: await readAddressCall(provider, ctmAddress, CtmReadAbi, "serverNotifierAddress"),
    bridgeHub: await readAddressCall(provider, ctmAddress, CtmReadAbi, "BRIDGE_HUB"),
  };
}

async function readBridgehubState(
  provider: ethers.providers.Provider,
  bridgehubAddress: string,
  ctmAddress: string
): Promise<BridgehubState> {
  return {
    address: bridgehubAddress,
    owner: await readAddressCall(provider, bridgehubAddress, BridgehubAbi, "owner"),
    pendingOwner: await readOptionalPendingOwner(provider, bridgehubAddress),
    admin: await readAddressCall(provider, bridgehubAddress, BridgehubAbi, "admin"),
    assetRouter: await readAddressCall(provider, bridgehubAddress, BridgehubAbi, "assetRouter"),
    ctmRegistered: await readBooleanCall(provider, bridgehubAddress, BridgehubAbi, "chainTypeManagerIsRegistered", [
      ctmAddress,
    ]),
  };
}

async function readOwnershipState(
  provider: ethers.providers.Provider,
  address: string,
  abi: string[],
  includeAdmin = false
): Promise<OwnershipState> {
  const state: OwnershipState = {
    owner: await readOptionalAddressCall(provider, address, abi, "owner"),
    pendingOwner: undefined,
  };
  const pendingOwner = await readOptionalAddressCall(provider, address, abi, "pendingOwner");
  state.pendingOwner = pendingOwner === ethers.constants.AddressZero ? undefined : pendingOwner;
  if (includeAdmin) {
    state.admin = await readOptionalAddressCall(provider, address, abi, "admin");
    const pendingAdmin = await readOptionalAddressCall(provider, address, abi, "pendingAdmin");
    state.pendingAdmin = pendingAdmin === ethers.constants.AddressZero ? undefined : pendingAdmin;
  }
  return state;
}

async function maybeDecodeProxyInitialization(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddress: string,
  deploymentBlock: number
): Promise<ProxyInitializationSnapshot | undefined> {
  const txHash = await findDeploymentTransactionHash(provider, ctmAddress, deploymentBlock);
  if (!txHash) {
    return undefined;
  }

  const artifact = loadArtifact(
    componentHints.TransparentUpgradeableProxy.contractName,
    componentHints.TransparentUpgradeableProxy.sourceContains
  );
  const creationCode = extractArtifactBytecode(artifact?.bytecode);
  if (!artifact || !creationCode) {
    return undefined;
  }

  const transaction = await provider.getTransaction(txHash);
  if (!transaction.data) {
    return undefined;
  }

  const normalizedCreationCode = strip0x(normalizeHex(creationCode));
  const normalizedTxData = strip0x(normalizeHex(transaction.data));
  if (!normalizedTxData.startsWith(normalizedCreationCode)) {
    return undefined;
  }

  const constructorData = `0x${normalizedTxData.slice(normalizedCreationCode.length)}`;
  const [implementation, admin, initData] = ethers.utils.defaultAbiCoder.decode(
    ["address", "address", "bytes"],
    constructorData
  );

  const parsed = initializeInterface.parseTransaction({ data: initData });
  const decoded = parsed.args[0];

  return {
    implementation: normalizeAddress(implementation),
    admin: normalizeAddress(admin),
    initializeData: {
      owner: normalizeAddress(decoded.owner),
      validatorTimelock: normalizeAddress(decoded.validatorTimelock),
      chainCreationParams: {
        genesisUpgrade: normalizeAddress(decoded.chainCreationParams.genesisUpgrade),
        genesisBatchHash: normalizeHex(decoded.chainCreationParams.genesisBatchHash),
        genesisIndexRepeatedStorageChanges: normalizeNumberish(
          decoded.chainCreationParams.genesisIndexRepeatedStorageChanges
        ),
        genesisBatchCommitment: normalizeHex(decoded.chainCreationParams.genesisBatchCommitment),
        diamondCut: {
          initAddress: normalizeAddress(decoded.chainCreationParams.diamondCut.initAddress),
          initCalldata: normalizeHex(decoded.chainCreationParams.diamondCut.initCalldata),
          facetCuts: (decoded.chainCreationParams.diamondCut.facetCuts ?? []).map((cut: any, index: number) => ({
            label: `facet_${index}`,
            facetAddress: normalizeAddress(cut.facet),
            action: Number(cut.action),
            isFreezable: Boolean(cut.isFreezable),
            selectors: normalizeSelectors(Array.from(cut.selectors ?? [])),
          })),
        },
        forceDeploymentsData: normalizeHex(decoded.chainCreationParams.forceDeploymentsData),
      },
      protocolVersion: normalizeNumberish(decoded.protocolVersion),
      serverNotifier: normalizeAddress(decoded.serverNotifier),
    },
  };
}

async function classifyVerifierWrapper(
  provider: ethers.providers.Provider,
  verifierAddress: string
): Promise<"DualVerifier" | "TestnetVerifier" | undefined> {
  try {
    const contract = new ethers.Contract(verifierAddress, VerifierWrapperAbi, provider);
    await contract.callStatic.verify([], []);
    return "TestnetVerifier";
  } catch (error) {
    try {
      await readAddressCall(provider, verifierAddress, VerifierWrapperAbi, "FFLONK_VERIFIER");
      await readAddressCall(provider, verifierAddress, VerifierWrapperAbi, "PLONK_VERIFIER");
      return "DualVerifier";
    } catch (nestedError) {
      return undefined;
    }
  }
}

async function deriveComponents(
  provider: ethers.providers.Provider,
  ctmAddress: string,
  implementationAddress: string,
  current: CurrentCtmState,
  latestChainCreationParams: ChainCreationParamsComparison,
  initializeDataNewChain: InitializeDataNewChainComparison
): Promise<{ components: Record<string, ComponentDescriptor>; verifierWrapperKind?: "DualVerifier" | "TestnetVerifier" }> {
  const components: Record<string, ComponentDescriptor> = {
    ChainTypeManagerImplementation: {
      label: "ChainTypeManagerImplementation",
      address: implementationAddress,
      ...componentHints.ChainTypeManagerImplementation,
    },
    DiamondInit: {
      label: "DiamondInit",
      address: latestChainCreationParams.diamondCut.initAddress,
      ...componentHints.DiamondInit,
    },
    L1GenesisUpgrade: {
      label: "L1GenesisUpgrade",
      address: latestChainCreationParams.genesisUpgrade,
      ...componentHints.L1GenesisUpgrade,
    },
    ValidatorTimelock: {
      label: "ValidatorTimelock",
      address: current.validatorTimelockPostV29,
      ...componentHints.ValidatorTimelock,
    },
    ServerNotifier: {
      label: "ServerNotifier",
      address: current.serverNotifierAddress,
      ...componentHints.ServerNotifier,
    },
  };

  for (const cut of latestChainCreationParams.diamondCut.facetCuts) {
    components[cut.label] = {
      label: cut.label,
      address: cut.facetAddress!,
      ...(componentHints[cut.label] ?? {
        contractName: cut.label,
      }),
    };
  }

  const adminFacetAddress = components.AdminFacet?.address;
  if (adminFacetAddress) {
    const rollupDAManager = await readOptionalAddressCall(provider, adminFacetAddress, NamedFacetAbi, "getRollupDAManager");
    if (rollupDAManager) {
      components.RollupDAManager = {
        label: "RollupDAManager",
        address: rollupDAManager,
        ...componentHints.RollupDAManager,
      };
    }
  }

  const verifierWrapperKind = await classifyVerifierWrapper(provider, initializeDataNewChain.verifier);
  if (verifierWrapperKind) {
    components.VerifierWrapper = {
      label: "VerifierWrapper",
      address: initializeDataNewChain.verifier,
      ...componentHints[verifierWrapperKind],
    };
    const fflonkAddress = await readAddressCall(provider, initializeDataNewChain.verifier, VerifierWrapperAbi, "FFLONK_VERIFIER");
    const plonkAddress = await readAddressCall(provider, initializeDataNewChain.verifier, VerifierWrapperAbi, "PLONK_VERIFIER");
    components.L1VerifierFflonk = {
      label: "L1VerifierFflonk",
      address: fflonkAddress,
      ...componentHints.L1VerifierFflonk,
    };
    components.L1VerifierPlonk = {
      label: "L1VerifierPlonk",
      address: plonkAddress,
      ...componentHints.L1VerifierPlonk,
    };
  }

  return {
    components,
    verifierWrapperKind,
  };
}

async function buildSnapshot(
  provider: ethers.providers.JsonRpcProvider,
  chainId: number,
  progress: ProgressReporter,
  label: string,
  ctmAddress: string,
  fromBlockOverride: number | undefined,
  chunkSize: number,
  throttleMs: number
): Promise<CtmSnapshot> {
  const normalizedCtmAddress = normalizeAddress(ctmAddress);
  progress.log(`Building ${label} CTM snapshot for ${normalizedCtmAddress}`);
  const deploymentBlock = fromBlockOverride ?? (await findDeploymentBlock(provider, normalizedCtmAddress));
  progress.log(`${label} CTM deployment block resolved to ${deploymentBlock}`);
  const current = await readCurrentCtmState(provider, normalizedCtmAddress);
  progress.log(`Loaded current ${label} CTM state; searching for latest chain creation params`);
  const latestChainCreationParams = await findLatestCtmEvent(
    provider,
    chainId,
    normalizedCtmAddress,
    deploymentBlock,
    "NewChainCreationParams",
    chunkSize,
    throttleMs,
    progress
  );
  if (!latestChainCreationParams) {
    throw new Error(`Could not reconstruct latest chain creation params for ${label} CTM`);
  }

  progress.log(`Latest chain creation params found for ${label} CTM; labeling facet cuts`);
  const labeledChainCreation = await labelFacetCuts(provider, latestChainCreationParams);
  const initializeDataNewChain = decodeInitializeDataNewChain(labeledChainCreation.diamondCut.initCalldata);
  const bridgehub = await readBridgehubState(provider, current.bridgeHub, normalizedCtmAddress);
  const implementationAddress = await getImplementationAddress(provider, normalizedCtmAddress);
  const proxyInitialization = await maybeDecodeProxyInitialization(provider, normalizedCtmAddress, deploymentBlock);
  const proxyControl = await readProxyControlState(provider, normalizedCtmAddress);
  progress.log(`Deriving linked components for ${label} CTM`);
  const derived = await deriveComponents(
    provider,
    normalizedCtmAddress,
    implementationAddress,
    current,
    labeledChainCreation,
    initializeDataNewChain
  );

  const snapshot: CtmSnapshot = {
    label,
    ctmAddress: normalizedCtmAddress,
    deploymentBlock,
    current,
    bridgehub,
    latestProtocolVersion: current.protocolVersion,
    latestChainCreationParams: labeledChainCreation,
    initializeDataNewChain,
    proxyControl,
    proxyInitialization,
    components: derived.components,
    verifierWrapperKind: derived.verifierWrapperKind,
  };

  snapshot.validatorTimelockControl = await readOwnershipState(
    provider,
    snapshot.components.ValidatorTimelock.address,
    ValidatorTimelockAbi
  );
  snapshot.validatorTimelockProxyControl = await readProxyControlState(provider, snapshot.components.ValidatorTimelock.address);
  snapshot.serverNotifierControl = await readOwnershipState(
    provider,
    snapshot.components.ServerNotifier.address,
    ServerNotifierAbi
  );
  snapshot.serverNotifierProxyControl = await readProxyControlState(provider, snapshot.components.ServerNotifier.address);
  if (snapshot.components.RollupDAManager) {
    snapshot.rollupDAManagerControl = await readOwnershipState(
      provider,
      snapshot.components.RollupDAManager.address,
      RollupDAManagerAbi
    );
  }

  return snapshot;
}

function compareValue(
  report: Report,
  label: string,
  oldValue: string,
  newValue: string,
  message?: string
) {
  if (oldValue === newValue) {
    pushReport(report, "match", {
      label,
      message: message ?? `${label} matches`,
      details: { value: oldValue },
    });
  } else {
    pushReport(report, "mismatch", {
      label,
      message: message ?? `${label} differs`,
      details: { old: oldValue, new: newValue },
    });
  }
}

function compareExpectedDifference(report: Report, label: string, oldValue: string, newValue: string, message: string) {
  if (oldValue === newValue) {
    pushReport(report, "match", {
      label,
      message: `${label} unexpectedly stayed the same, but this is acceptable`,
      details: { value: oldValue },
    });
  } else {
    pushReport(report, "expected_diff", {
      label,
      message,
      details: { old: oldValue, new: newValue },
    });
  }
}

function pushInfoValue(report: Report, label: string, value: string | undefined, details?: Record<string, unknown>) {
  pushReport(report, "info", {
    label,
    message: value ?? "not set",
    details,
  });
}

const ansi = {
  reset: "\u001b[0m",
  yellow: "\u001b[33m",
  green: "\u001b[32m",
};

function colorize(text: string, color: keyof typeof ansi): string {
  return `${ansi[color]}${text}${ansi.reset}`;
}

function formatAddressValue(address: string | undefined): string {
  return address ?? "not set";
}

async function renderOwnershipModel(
  provider: ethers.providers.Provider,
  snapshot: CtmSnapshot
): Promise<string> {
  const addressInspectionCache = new Map<string, { kind: "EOA" | "Contract"; ownerState?: OwnershipState }>();

  const inspectAddress = async (
    address: string | undefined
  ): Promise<{ kind?: "EOA" | "Contract"; ownerState?: OwnershipState }> => {
    if (!address || address === ethers.constants.AddressZero) {
      return {};
    }
    const normalized = normalizeAddress(address);
    const cached = addressInspectionCache.get(normalized);
    if (cached) {
      return cached;
    }

    const code = normalizeHex(await provider.getCode(normalized));
    if (code === "0x") {
      const result = { kind: "EOA" as const };
      addressInspectionCache.set(normalized, result);
      return result;
    }

    const ownerState = await readOwnershipState(provider, normalized, Ownable2StepAbi);
    const result = { kind: "Contract" as const, ownerState };
    addressInspectionCache.set(normalized, result);
    return result;
  };

  const formatRoleLine = async (indent: string, role: string, address: string | undefined): Promise<string[]> => {
    if (!address || address === ethers.constants.AddressZero) {
      return [`${indent}${role}: not set`];
    }

    const inspection = await inspectAddress(address);
    const coloredKind =
      inspection.kind === "EOA"
        ? colorize("EOA", "yellow")
        : inspection.kind === "Contract"
          ? colorize("Contract", "green")
          : "unknown";

    const lines = [`${indent}${role}: ${formatAddressValue(address)} (${coloredKind})`];
    if (inspection.kind === "Contract" && inspection.ownerState?.owner) {
      lines.push(`${indent}  owner: ${inspection.ownerState.owner}`);
      if (inspection.ownerState.pendingOwner) {
        lines.push(`${indent}  pendingOwner: ${inspection.ownerState.pendingOwner}`);
      }
    }

    return lines;
  };

  const renderOwnershipBlock = async (
    title: string,
    state: OwnershipState,
    options?: {
      includeAdmin?: boolean;
      extraRoles?: Array<{ role: string; address?: string }>;
    }
  ): Promise<string[]> => {
    const lines = [title];
    lines.push(...(await formatRoleLine("  ", "owner", state.owner)));
    lines.push(...(await formatRoleLine("  ", "pendingOwner", state.pendingOwner)));
    if (options?.includeAdmin) {
      lines.push(...(await formatRoleLine("  ", "admin", state.admin)));
      if (state.pendingAdmin !== undefined) {
        lines.push(...(await formatRoleLine("  ", "pendingAdmin", state.pendingAdmin)));
      } else {
        lines.push("  pendingAdmin: unavailable (no getter)");
      }
    }
    for (const extraRole of options?.extraRoles ?? []) {
      lines.push(...(await formatRoleLine("  ", extraRole.role, extraRole.address)));
    }
    return lines;
  };

  const lines: string[] = ["Ownership Model"];
  lines.push(
    ...(await renderOwnershipBlock("<new-bridgehub>", {
      owner: snapshot.bridgehub.owner,
      pendingOwner: snapshot.bridgehub.pendingOwner,
      admin: snapshot.bridgehub.admin,
    }, {
      includeAdmin: true,
    }))
  );
  lines.push(
    ...(await renderOwnershipBlock("<new-ctm>", {
      owner: snapshot.current.owner,
      pendingOwner: snapshot.current.pendingOwner,
      admin: snapshot.current.admin,
      pendingAdmin: snapshot.current.pendingAdmin,
    }, {
      includeAdmin: true,
      extraRoles: [
        { role: "proxyAdmin", address: snapshot.proxyControl?.proxyAdminAddress },
        { role: "proxyAdminOwner", address: snapshot.proxyControl?.proxyAdminOwner },
      ],
    }))
  );
  lines.push(
    ...(await renderOwnershipBlock("<new-validator-timelock>", snapshot.validatorTimelockControl ?? {}, {
      extraRoles: [
        { role: "proxyAdmin", address: snapshot.validatorTimelockProxyControl?.proxyAdminAddress },
        { role: "proxyAdminOwner", address: snapshot.validatorTimelockProxyControl?.proxyAdminOwner },
      ],
    }))
  );
  lines.push(
    ...(await renderOwnershipBlock("<new-server-notifier>", snapshot.serverNotifierControl ?? {}, {
      extraRoles: [
        { role: "proxyAdmin", address: snapshot.serverNotifierProxyControl?.proxyAdminAddress },
        { role: "proxyAdminOwner", address: snapshot.serverNotifierProxyControl?.proxyAdminOwner },
      ],
    }))
  );
  if (snapshot.rollupDAManagerControl) {
    lines.push(...(await renderOwnershipBlock("<new-rollup-da-manager>", snapshot.rollupDAManagerControl)));
  }

  return lines.join("\n");
}

function compareFeeParams(
  report: Report,
  oldParams: InitializeDataNewChainComparison["feeParams"],
  newParams: InitializeDataNewChainComparison["feeParams"]
) {
  compareValue(report, "FeeParams.pubdataPricingMode", String(oldParams.pubdataPricingMode), String(newParams.pubdataPricingMode));
  compareValue(report, "FeeParams.batchOverheadL1Gas", oldParams.batchOverheadL1Gas, newParams.batchOverheadL1Gas);
  compareValue(report, "FeeParams.maxPubdataPerBatch", oldParams.maxPubdataPerBatch, newParams.maxPubdataPerBatch);
  compareValue(report, "FeeParams.maxL2GasPerBatch", oldParams.maxL2GasPerBatch, newParams.maxL2GasPerBatch);
  compareValue(report, "FeeParams.priorityTxMaxPubdata", oldParams.priorityTxMaxPubdata, newParams.priorityTxMaxPubdata);
  compareValue(report, "FeeParams.minimalL2GasPrice", oldParams.minimalL2GasPrice, newParams.minimalL2GasPrice);
}

function applyL1ToL2Alias(address: string): string {
  const aliasedAddress = BigNumber.from(normalizeAddress(address)).add(L1_TO_L2_ALIAS_OFFSET).mask(160);
  return normalizeAddress(ethers.utils.hexZeroPad(aliasedAddress.toHexString(), 20));
}

function compareDecodedForceDeploymentsData(
  report: Report,
  oldData: FixedForceDeploymentsDataComparison,
  newData: FixedForceDeploymentsDataComparison,
  newBridgehub: BridgehubState
) {
  compareValue(
    report,
    "FixedForceDeploymentsData.l1ChainId",
    oldData.l1ChainId,
    newData.l1ChainId
  );
  compareExpectedDifference(
    report,
    "FixedForceDeploymentsData.eraChainId",
    oldData.eraChainId,
    newData.eraChainId,
    "Era chain id differs as expected between cloned CTMs"
  );
  compareExpectedDifference(
    report,
    "FixedForceDeploymentsData.l1AssetRouter",
    oldData.l1AssetRouter,
    newData.l1AssetRouter,
    "L1 asset router differs as expected between cloned CTMs"
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.l1AssetRouter.newBridgehub",
    newBridgehub.assetRouter,
    newData.l1AssetRouter,
    "New fixed-force deployments data uses the new Bridgehub asset router"
  );
  compareExpectedDifference(
    report,
    "FixedForceDeploymentsData.aliasedL1Governance",
    oldData.aliasedL1Governance,
    newData.aliasedL1Governance,
    "Aliased L1 governance differs as expected between cloned CTMs"
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.aliasedL1Governance.newBridgehubOwner",
    applyL1ToL2Alias(newBridgehub.owner),
    newData.aliasedL1Governance,
    "New fixed-force deployments data uses the aliased new Bridgehub owner"
  );

  compareValue(
    report,
    "FixedForceDeploymentsData.l2TokenProxyBytecodeHash",
    oldData.l2TokenProxyBytecodeHash,
    newData.l2TokenProxyBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.maxNumberOfZKChains",
    oldData.maxNumberOfZKChains,
    newData.maxNumberOfZKChains
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.bridgehubBytecodeHash",
    oldData.bridgehubBytecodeHash,
    newData.bridgehubBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.l2AssetRouterBytecodeHash",
    oldData.l2AssetRouterBytecodeHash,
    newData.l2AssetRouterBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.l2NtvBytecodeHash",
    oldData.l2NtvBytecodeHash,
    newData.l2NtvBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.messageRootBytecodeHash",
    oldData.messageRootBytecodeHash,
    newData.messageRootBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.chainAssetHandlerBytecodeHash",
    oldData.chainAssetHandlerBytecodeHash,
    newData.chainAssetHandlerBytecodeHash
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.l2SharedBridgeLegacyImpl",
    oldData.l2SharedBridgeLegacyImpl,
    newData.l2SharedBridgeLegacyImpl
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.l2BridgedStandardERC20Impl",
    oldData.l2BridgedStandardERC20Impl,
    newData.l2BridgedStandardERC20Impl
  );
  compareValue(
    report,
    "FixedForceDeploymentsData.dangerousTestOnlyForcedBeacon",
    oldData.dangerousTestOnlyForcedBeacon,
    newData.dangerousTestOnlyForcedBeacon
  );
}

function areDiffRangesInsideMetadata(
  diffRanges: DiffRange[],
  oldMetadataRange?: ByteRange,
  newMetadataRange?: ByteRange
): boolean {
  if (diffRanges.length === 0 || (!oldMetadataRange && !newMetadataRange)) {
    return false;
  }

  return diffRanges.every((range) => {
    const insideOld = oldMetadataRange ? range.start >= oldMetadataRange.start && range.end <= oldMetadataRange.end : false;
    const insideNew = newMetadataRange ? range.start >= newMetadataRange.start && range.end <= newMetadataRange.end : false;
    return insideOld || insideNew;
  });
}

function resolveImmutablePolicies(
  contractName: string,
  immutableRefKeys: string[],
  decodedOld: Record<string, string[]>,
  decodedNew: Record<string, string[]>
): Record<string, { label: string; policy: ImmutablePolicy }> {
  const configuredPolicies = Object.entries(immutablePolicies[contractName] ?? {});
  const resolved: Record<string, { label: string; policy: ImmutablePolicy }> = {};
  const usedPolicyNames = new Set<string>();

  const claimPolicyName = (policy: ImmutablePolicy, same: boolean): string | undefined => {
    const candidate = configuredPolicies.find(([name, configuredPolicy]) => {
      if (usedPolicyNames.has(name) || configuredPolicy !== policy) {
        return false;
      }
      if (policy === "expected_same") {
        return same;
      }
      if (policy === "expected_different") {
        return !same;
      }
      return true;
    });
    if (!candidate) {
      return undefined;
    }
    usedPolicyNames.add(candidate[0]);
    return candidate[0];
  };

  for (const key of immutableRefKeys) {
    const directPolicy = configuredPolicies.find(([name]) => key === name || key.endsWith(`:${name}`) || key.endsWith(`.${name}`));
    if (!directPolicy) {
      continue;
    }
    usedPolicyNames.add(directPolicy[0]);
    resolved[key] = {
      label: directPolicy[0],
      policy: directPolicy[1],
    };
  }

  for (const key of immutableRefKeys) {
    if (resolved[key]) {
      continue;
    }

    const same = JSON.stringify(decodedOld[key]) === JSON.stringify(decodedNew[key]);
    const expectedSameName = claimPolicyName("expected_same", same);
    if (expectedSameName) {
      resolved[key] = {
        label: expectedSameName,
        policy: "expected_same",
      };
      continue;
    }

    const expectedDifferentName = claimPolicyName("expected_different", same);
    if (expectedDifferentName) {
      resolved[key] = {
        label: expectedDifferentName,
        policy: "expected_different",
      };
      continue;
    }

    const informationalName = claimPolicyName("informational", same);
    if (informationalName) {
      resolved[key] = {
        label: informationalName,
        policy: "informational",
      };
      continue;
    }

    resolved[key] = {
      label: key,
      policy: "informational",
    };
  }

  return resolved;
}

async function compareComponentBytecode(
  provider: ethers.providers.Provider,
  report: Report,
  left: ComponentDescriptor,
  right: ComponentDescriptor
) {
  const oldCode = normalizeHex(await provider.getCode(left.address));
  const newCode = normalizeHex(await provider.getCode(right.address));
  const contractName = right.contractName || left.contractName;

  if (oldCode === "0x" || newCode === "0x") {
    pushReport(report, "mismatch", {
      label: `${left.label}.bytecode`,
      message: "component bytecode missing",
      oldAddress: left.address,
      newAddress: right.address,
      details: {
        oldCodePresent: oldCode !== "0x",
        newCodePresent: newCode !== "0x",
      },
    });
    return;
  }

  if (oldCode === newCode) {
    pushReport(report, "match", {
      label: `${left.label}.bytecode`,
      message: `${left.label} runtime bytecode matches exactly`,
      oldAddress: left.address,
      newAddress: right.address,
      comparisonMode: "exact",
    });
    return;
  }

  const oldMetadataRange = getSolidityCborMetadataRange(oldCode);
  const newMetadataRange = getSolidityCborMetadataRange(newCode);

  const artifact = loadArtifact(contractName, right.sourceContains ?? left.sourceContains);
  const immutableRefs = extractImmutableReferences(artifact);
  const policy = immutablePolicies[contractName];

  if (immutableRefs && Object.keys(immutableRefs).length > 0) {
    const maskedOld = maskHexAtRanges(oldCode, flattenImmutableReferences(immutableRefs));
    const maskedNew = maskHexAtRanges(newCode, flattenImmutableReferences(immutableRefs));
    const decodedOld = decodeImmutableValues(oldCode, immutableRefs);
    const decodedNew = decodeImmutableValues(newCode, immutableRefs);
    const resolvedPolicies = resolveImmutablePolicies(contractName, Object.keys(immutableRefs), decodedOld, decodedNew);
    const decodedImmutables: ReportItem["decodedImmutables"] = {};
    let expectedSameMismatch = false;
    let informationalDifference = false;
    let allowedDifference = false;

    for (const key of Object.keys(immutableRefs)) {
      const resolved = resolvedPolicies[key];
      const currentPolicy = resolved?.policy ?? policy?.[key] ?? "informational";
      const decodedLabel = resolved?.label ?? key;
      decodedImmutables[decodedLabel] = {
        policy: currentPolicy,
        old: decodedOld[key],
        new: decodedNew[key],
      };
      const same = JSON.stringify(decodedOld[key]) === JSON.stringify(decodedNew[key]);
      if (currentPolicy === "expected_same" && !same) {
        expectedSameMismatch = true;
      }
      if (currentPolicy === "expected_different" && !same) {
        allowedDifference = true;
      }
      if (currentPolicy === "informational" && !same) {
        informationalDifference = true;
      }
    }

    for (const [decodedLabel, decodedValue] of Object.entries(decodedImmutables)) {
      if (decodedLabel !== "ERA_CHAIN_ID") {
        continue;
      }

      const oldEraChainId = decodeConsistentImmutableNumberish(decodedValue.old);
      const newEraChainId = decodeConsistentImmutableNumberish(decodedValue.new);
      if (!oldEraChainId || !newEraChainId) {
        pushReport(report, "mismatch", {
          label: `${left.label}.ERA_CHAIN_ID`,
          message: `${left.label} ERA_CHAIN_ID immutable has inconsistent occurrences across the bytecode`,
          oldAddress: left.address,
          newAddress: right.address,
          comparisonMode: "masked_immutables",
          decodedImmutables: {
            [decodedLabel]: decodedValue,
          },
        });
        continue;
      }

      compareValue(report, `${left.label}.ERA_CHAIN_ID`, EXPECTED_NEW_ERA_CHAIN_ID, newEraChainId);
    }

    if (maskedOld !== maskedNew) {
      const maskedDiffRanges = diffByteRanges(maskedOld, maskedNew);
      pushReport(report, "mismatch", {
        label: `${left.label}.bytecode`,
        message: `${left.label} differs outside immutable ranges`,
        oldAddress: left.address,
        newAddress: right.address,
        comparisonMode: "masked_immutables",
        diffRanges: maskedDiffRanges,
        details: {
          oldCodeLengthBytes: strip0x(oldCode).length / 2,
          newCodeLengthBytes: strip0x(newCode).length / 2,
          cborMetadataOnly: areDiffRangesInsideMetadata(maskedDiffRanges, oldMetadataRange, newMetadataRange),
          oldCborMetadataRange: oldMetadataRange,
          newCborMetadataRange: newMetadataRange,
        },
        decodedImmutables,
      });
      return;
    }

    if (expectedSameMismatch) {
      pushReport(report, "mismatch", {
        label: `${left.label}.immutables`,
        message: `${left.label} immutable values differ where they must match`,
        oldAddress: left.address,
        newAddress: right.address,
        comparisonMode: "masked_immutables",
        decodedImmutables,
      });
      return;
    }

    if (allowedDifference) {
      pushReport(report, "expected_diff", {
        label: `${left.label}.immutables`,
        message: `${left.label} differs only in allowed immutable values`,
        oldAddress: left.address,
        newAddress: right.address,
        comparisonMode: "masked_immutables",
        decodedImmutables,
      });
    } else {
      pushReport(report, "match", {
        label: `${left.label}.bytecode`,
        message: `${left.label} matches after masking immutable ranges`,
        oldAddress: left.address,
        newAddress: right.address,
        comparisonMode: "masked_immutables",
        decodedImmutables,
      });
    }

    if (informationalDifference) {
      pushReport(report, "best_effort", {
        label: `${left.label}.immutables`,
        message: `${left.label} has informational immutable differences to review`,
        oldAddress: left.address,
        newAddress: right.address,
        comparisonMode: "masked_immutables",
        decodedImmutables,
      });
    }
    return;
  }

  const ranges = diffByteRanges(oldCode, newCode);
  const item: ReportItem = {
    label: `${left.label}.bytecode`,
    message: `${left.label} runtime bytecode differs`,
    oldAddress: left.address,
    newAddress: right.address,
    comparisonMode: "raw_diff",
    diffRanges: ranges,
    details: {
      diffCount: ranges.reduce((count, range) => count + (range.end - range.start + 1), 0),
      wordIndices: diffWordIndices(ranges),
      oldCodeLengthBytes: strip0x(oldCode).length / 2,
      newCodeLengthBytes: strip0x(newCode).length / 2,
      cborMetadataOnly: areDiffRangesInsideMetadata(ranges, oldMetadataRange, newMetadataRange),
      oldCborMetadataRange: oldMetadataRange,
      newCborMetadataRange: newMetadataRange,
    },
  };

  if (policy && Object.keys(policy).length > 0) {
    pushReport(report, "best_effort", item);
  } else {
    pushReport(report, "mismatch", item);
  }
}

async function compareComponentGraph(
  provider: ethers.providers.Provider,
  report: Report,
  oldSnapshot: CtmSnapshot,
  newSnapshot: CtmSnapshot
) {
  const labels = new Set<string>([
    ...Object.keys(oldSnapshot.components),
    ...Object.keys(newSnapshot.components),
  ]);

  for (const label of labels) {
    const left = oldSnapshot.components[label];
    const right = newSnapshot.components[label];
    if (!left || !right) {
      pushReport(report, "mismatch", {
        label: `${label}.component`,
        message: `${label} is missing from one component graph`,
        oldAddress: left?.address,
        newAddress: right?.address,
      });
      continue;
    }

    if (left.address !== right.address) {
      pushReport(report, "expected_diff", {
        label: `${label}.address`,
        message: `${label} is a fresh deployment with a different address`,
        oldAddress: left.address,
        newAddress: right.address,
      });
    } else {
      pushReport(report, "match", {
        label: `${label}.address`,
        message: `${label} reuses the same address`,
        oldAddress: left.address,
        newAddress: right.address,
      });
    }

    await compareComponentBytecode(provider, report, left, right);
  }
}

async function compareSnapshotSemantics(
  provider: ethers.providers.Provider,
  report: Report,
  oldSnapshot: CtmSnapshot,
  newSnapshot: CtmSnapshot
) {
  compareValue(report, "CTM.protocolVersion", oldSnapshot.latestProtocolVersion, newSnapshot.latestProtocolVersion);
  compareValue(report, "CTM.protocolVersionDeadline", oldSnapshot.current.protocolVersionDeadline, newSnapshot.current.protocolVersionDeadline);
  compareValue(report, "CTM.storedBatchZero", oldSnapshot.current.storedBatchZero, newSnapshot.current.storedBatchZero);
  compareValue(report, "CTM.initialCutHash", oldSnapshot.current.initialCutHash, newSnapshot.current.initialCutHash);
  compareExpectedDifference(
    report,
    "CTM.BRIDGE_HUB",
    oldSnapshot.current.bridgeHub,
    newSnapshot.current.bridgeHub,
    "Bridgehub differs as expected between the old and new CTM"
  );

  compareValue(
    report,
    "ChainCreation.genesisBatchHash",
    oldSnapshot.latestChainCreationParams.genesisBatchHash,
    newSnapshot.latestChainCreationParams.genesisBatchHash
  );
  compareValue(
    report,
    "ChainCreation.genesisIndexRepeatedStorageChanges",
    oldSnapshot.latestChainCreationParams.genesisIndexRepeatedStorageChanges,
    newSnapshot.latestChainCreationParams.genesisIndexRepeatedStorageChanges
  );
  compareValue(
    report,
    "ChainCreation.genesisBatchCommitment",
    oldSnapshot.latestChainCreationParams.genesisBatchCommitment,
    newSnapshot.latestChainCreationParams.genesisBatchCommitment
  );
  const oldFixedForceDeploymentsData = decodeFixedForceDeploymentsData(oldSnapshot.latestChainCreationParams.forceDeploymentsData);
  const newFixedForceDeploymentsData = decodeFixedForceDeploymentsData(newSnapshot.latestChainCreationParams.forceDeploymentsData);
  compareDecodedForceDeploymentsData(
    report,
    oldFixedForceDeploymentsData,
    newFixedForceDeploymentsData,
    newSnapshot.bridgehub
  );
  compareValue(report, "NewCTM.eraChainId", EXPECTED_NEW_ERA_CHAIN_ID, newFixedForceDeploymentsData.eraChainId);
  compareValue(
    report,
    "CTM.l1GenesisUpgradeBinding.old",
    oldSnapshot.current.l1GenesisUpgrade,
    oldSnapshot.components.L1GenesisUpgrade.address,
    "Old CTM points at the L1GenesisUpgrade component"
  );
  compareValue(
    report,
    "CTM.l1GenesisUpgradeBinding.new",
    newSnapshot.current.l1GenesisUpgrade,
    newSnapshot.components.L1GenesisUpgrade.address,
    "New CTM points at the L1GenesisUpgrade component"
  );
  compareExpectedDifference(
    report,
    "ChainCreation.genesisUpgrade",
    oldSnapshot.latestChainCreationParams.genesisUpgrade,
    newSnapshot.latestChainCreationParams.genesisUpgrade,
    "Genesis upgrade address differs as expected because it is redeployed"
  );
  compareExpectedDifference(
    report,
    "ChainCreation.diamondInit",
    oldSnapshot.latestChainCreationParams.diamondCut.initAddress,
    newSnapshot.latestChainCreationParams.diamondCut.initAddress,
    "Diamond init address differs as expected because it is redeployed"
  );

  const facetComparison = compareFacetCuts(
    oldSnapshot.latestChainCreationParams.diamondCut.facetCuts,
    newSnapshot.latestChainCreationParams.diamondCut.facetCuts
  );
  if (facetComparison.equal) {
    pushReport(report, "match", {
      label: "ChainCreation.facetCuts",
      message: "Facet selector sets, actions, and freezability match",
    });
  } else {
    pushReport(report, "mismatch", {
      label: "ChainCreation.facetCuts",
      message: facetComparison.reason ?? "Facet cuts differ",
    });
  }

  compareExpectedDifference(
    report,
    "InitializeDataNewChain.verifier",
    oldSnapshot.initializeDataNewChain.verifier,
    newSnapshot.initializeDataNewChain.verifier,
    "Verifier wrapper address differs as expected because it is redeployed"
  );
  compareValue(
    report,
    "InitializeDataNewChain.verifierParams.recursionNodeLevelVkHash",
    oldSnapshot.initializeDataNewChain.verifierParams.recursionNodeLevelVkHash,
    newSnapshot.initializeDataNewChain.verifierParams.recursionNodeLevelVkHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.verifierParams.recursionLeafLevelVkHash",
    oldSnapshot.initializeDataNewChain.verifierParams.recursionLeafLevelVkHash,
    newSnapshot.initializeDataNewChain.verifierParams.recursionLeafLevelVkHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.verifierParams.recursionCircuitsSetVksHash",
    oldSnapshot.initializeDataNewChain.verifierParams.recursionCircuitsSetVksHash,
    newSnapshot.initializeDataNewChain.verifierParams.recursionCircuitsSetVksHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.l2BootloaderBytecodeHash",
    oldSnapshot.initializeDataNewChain.l2BootloaderBytecodeHash,
    newSnapshot.initializeDataNewChain.l2BootloaderBytecodeHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.l2DefaultAccountBytecodeHash",
    oldSnapshot.initializeDataNewChain.l2DefaultAccountBytecodeHash,
    newSnapshot.initializeDataNewChain.l2DefaultAccountBytecodeHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.l2EvmEmulatorBytecodeHash",
    oldSnapshot.initializeDataNewChain.l2EvmEmulatorBytecodeHash,
    newSnapshot.initializeDataNewChain.l2EvmEmulatorBytecodeHash
  );
  compareValue(
    report,
    "InitializeDataNewChain.priorityTxMaxGasLimit",
    oldSnapshot.initializeDataNewChain.priorityTxMaxGasLimit,
    newSnapshot.initializeDataNewChain.priorityTxMaxGasLimit
  );
  compareFeeParams(report, oldSnapshot.initializeDataNewChain.feeParams, newSnapshot.initializeDataNewChain.feeParams);

  if (oldSnapshot.bridgehub.ctmRegistered && newSnapshot.bridgehub.ctmRegistered) {
    pushReport(report, "match", {
      label: "Bridgehub.CTMRegistration",
      message: "Both CTMs are registered on their respective Bridgehubs",
      oldAddress: oldSnapshot.bridgehub.address,
      newAddress: newSnapshot.bridgehub.address,
    });
  } else {
    pushReport(report, "mismatch", {
      label: "Bridgehub.CTMRegistration",
      message: "A CTM is not registered on its Bridgehub",
      oldAddress: oldSnapshot.bridgehub.address,
      newAddress: newSnapshot.bridgehub.address,
      details: {
        oldRegistered: oldSnapshot.bridgehub.ctmRegistered,
        newRegistered: newSnapshot.bridgehub.ctmRegistered,
      },
    });
  }

  compareValue(
    report,
    "BridgehubBinding.old",
    oldSnapshot.current.bridgeHub,
    oldSnapshot.bridgehub.address,
    "Old CTM points to the Bridgehub it is checked against"
  );
  compareValue(
    report,
    "BridgehubBinding.new",
    newSnapshot.current.bridgeHub,
    newSnapshot.bridgehub.address,
    "New CTM points to the Bridgehub it is checked against"
  );
}

async function compareProtocolVersionHistory(
  provider: ethers.providers.Provider,
  report: Report,
  oldSnapshot: CtmSnapshot,
  newSnapshot: CtmSnapshot
) {
  const latestVersion = oldSnapshot.latestProtocolVersion;
  const zeroHash = ethers.constants.HashZero.toLowerCase();
  const latestUpgradeCutHash = await readBytesCall(provider, newSnapshot.ctmAddress, CtmReadAbi, "upgradeCutHash", [latestVersion]);
  if (latestUpgradeCutHash === zeroHash) {
    pushReport(report, "match", {
      label: `LatestProtocolVersion.upgradeCutHash.${latestVersion}`,
      message: `New CTM correctly has no upgrade cut hash for its current protocol version ${latestVersion}`,
    });
  } else {
    pushReport(report, "mismatch", {
      label: `LatestProtocolVersion.upgradeCutHash.${latestVersion}`,
      message: `New CTM unexpectedly stores upgrade data for its current protocol version ${latestVersion}`,
      details: {
        upgradeCutHash: latestUpgradeCutHash,
      },
    });
  }
  pushReport(report, "best_effort", {
    label: "LegacyProtocolVersions",
    message:
      "Legacy protocol-version slots were not exhaustively scanned. The checker validates the active version deadline via direct getters and requires the new CTM to have no upgrade cut hash for its active version.",
    details: {
      checkedLatestVersion: latestVersion,
    },
  });
}

async function compareComponentSpecificState(
  provider: ethers.providers.Provider,
  report: Report,
  oldSnapshot: CtmSnapshot,
  newSnapshot: CtmSnapshot
) {
  if (oldSnapshot.proxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "old.CTM", oldSnapshot.proxyControl);
  }
  if (newSnapshot.proxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "new.CTM", newSnapshot.proxyControl);
  }

  const oldImplementation = oldSnapshot.components.ChainTypeManagerImplementation.address;
  const newImplementation = newSnapshot.components.ChainTypeManagerImplementation.address;
  compareExpectedDifference(
    report,
    "ChainTypeManagerImplementation.BRIDGE_HUB",
    await readAddressCall(provider, oldImplementation, CtmReadAbi, "BRIDGE_HUB"),
    await readAddressCall(provider, newImplementation, CtmReadAbi, "BRIDGE_HUB"),
    "ChainTypeManager implementation points at different Bridgehubs as expected"
  );

  const oldTimelock = oldSnapshot.components.ValidatorTimelock.address;
  const newTimelock = newSnapshot.components.ValidatorTimelock.address;
  if (oldSnapshot.validatorTimelockProxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "old.ValidatorTimelock", oldSnapshot.validatorTimelockProxyControl);
  }
  if (newSnapshot.validatorTimelockProxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "new.ValidatorTimelock", newSnapshot.validatorTimelockProxyControl);
  }
  compareValue(
    report,
    "ValidatorTimelock.executionDelay",
    await readBigNumberCall(provider, oldTimelock, ValidatorTimelockAbi, "executionDelay"),
    await readBigNumberCall(provider, newTimelock, ValidatorTimelockAbi, "executionDelay")
  );
  compareExpectedDifference(
    report,
    "ValidatorTimelock.BRIDGE_HUB",
    await readAddressCall(provider, oldTimelock, ValidatorTimelockAbi, "BRIDGE_HUB"),
    await readAddressCall(provider, newTimelock, ValidatorTimelockAbi, "BRIDGE_HUB"),
    "Validator timelock points at different Bridgehubs as expected"
  );

  const oldServerNotifier = oldSnapshot.components.ServerNotifier.address;
  const newServerNotifier = newSnapshot.components.ServerNotifier.address;
  if (oldSnapshot.serverNotifierProxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "old.ServerNotifier", oldSnapshot.serverNotifierProxyControl);
  }
  if (newSnapshot.serverNotifierProxyControl) {
    await ensureProxyUsesProxyAdminBytecode(provider, report, "new.ServerNotifier", newSnapshot.serverNotifierProxyControl);
  }
  compareValue(
    report,
    "ServerNotifier.chainTypeManager.old",
    oldSnapshot.ctmAddress,
    await readAddressCall(provider, oldServerNotifier, ServerNotifierAbi, "chainTypeManager"),
    "Old server notifier points at the old CTM"
  );
  compareValue(
    report,
    "ServerNotifier.chainTypeManager.new",
    newSnapshot.ctmAddress,
    await readAddressCall(provider, newServerNotifier, ServerNotifierAbi, "chainTypeManager"),
    "New server notifier points at the new CTM"
  );

  if (oldSnapshot.components.VerifierWrapper && newSnapshot.components.VerifierWrapper) {
    compareValue(
      report,
      "VerifierWrapper.kind",
      oldSnapshot.verifierWrapperKind ?? "unknown",
      newSnapshot.verifierWrapperKind ?? "unknown"
    );
    compareValue(
      report,
      "VerifierWrapper.verificationKeyHash",
      await readBytesCall(provider, oldSnapshot.components.VerifierWrapper.address, VerifierWrapperAbi, "verificationKeyHash"),
      await readBytesCall(provider, newSnapshot.components.VerifierWrapper.address, VerifierWrapperAbi, "verificationKeyHash")
    );
  }

  if (oldSnapshot.components.RollupDAManager && newSnapshot.components.RollupDAManager) {
    pushReport(report, "best_effort", {
      label: "RollupDAManager.allowedDAPairs",
      message: "Allowed DA pair state was not compared because CTM parity does not expose a single authoritative pair set to check here",
      oldAddress: oldSnapshot.components.RollupDAManager.address,
      newAddress: newSnapshot.components.RollupDAManager.address,
    });
  }
}

function printTextReport(report: Report) {
  const sections: Array<[SectionName, string]> = [
    ["mismatch", "Mismatch"],
    ["expected_diff", "Expected Diff"],
    ["match", "Match"],
    ["best_effort", "Best Effort"],
  ];

  const isCborMetadataOnlyDifference = (item: ReportItem): boolean => Boolean(item.details?.cborMetadataOnly);

  const itemPrefix = (section: SectionName, item: ReportItem): string => {
    if (section === "info") {
      return "ℹ️";
    }
    if (section === "match" || section === "expected_diff") {
      return "✅";
    }
    if (section === "best_effort") {
      return "⚠️";
    }
    if (isCborMetadataOnlyDifference(item)) {
      return "⚠️";
    }
    return "❌";
  };

  const itemMessage = (section: SectionName, item: ReportItem): string => {
    if (section === "mismatch" && isCborMetadataOnlyDifference(item)) {
      return `${item.message} (CBOR metadata different)`;
    }
    return item.message;
  };

  for (const [key, title] of sections) {
    console.log(`\n${title}:`);
    if (report[key].length === 0) {
      console.log("  - none");
      continue;
    }

    for (const item of report[key]) {
      console.log(`  ${itemPrefix(key, item)} ${item.label}: ${itemMessage(key, item)}`);
      if (item.oldAddress || item.newAddress) {
        console.log(`    old=${item.oldAddress ?? "-"} new=${item.newAddress ?? "-"}`);
      }
      if (item.comparisonMode) {
        console.log(`    comparisonMode=${item.comparisonMode}`);
      }
      if (item.diffRanges && item.diffRanges.length > 0) {
        const rendered = item.diffRanges.map((range) => `${range.start}-${range.end}`).join(", ");
        console.log(`    diffRanges=${rendered}`);
      }
      if (item.details) {
        console.log(`    details=${JSON.stringify(item.details)}`);
      }
      if (item.decodedImmutables) {
        console.log(`    decodedImmutables=${JSON.stringify(item.decodedImmutables)}`);
      }
    }
  }
}

async function main() {
  const program = new Command();

  program
    .name("check-ctm-parity")
    .description("Checks parity between an old CTM and a newly deployed CTM using Foundry artifacts when available")
    .requiredOption("--old-ctm <address>")
    .requiredOption("--new-ctm <address>")
    .option("--rpc-url <url>")
    .option("--old-from-block <block>", undefined, (value) => parseInt(value, 10))
    .option("--new-from-block <block>", undefined, (value) => parseInt(value, 10))
    .option("--chunk-size <size>", undefined, (value) => parseInt(value, 10), 50000)
    .option("--throttle-ms <ms>", undefined, (value) => parseInt(value, 10), 250)
    .option("--json");

  await program.parseAsync(process.argv);
  const options = program.opts() as ScriptOptions;
  const rpcUrl = options.rpcUrl ?? defaultRpcUrl();
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const progress = createProgressReporter();
  const network = await provider.getNetwork();
  progress.log(`Connected to chainId=${network.chainId}`);

  const report = emptyReport();

  progress.log("Starting old CTM snapshot");
  const oldSnapshot = await buildSnapshot(
    provider,
    network.chainId,
    progress,
    "old",
    options.oldCtm,
    options.oldFromBlock,
    options.chunkSize,
    options.throttleMs
  );
  progress.log("Starting new CTM snapshot");
  const newSnapshot = await buildSnapshot(
    provider,
    network.chainId,
    progress,
    "new",
    options.newCtm,
    options.newFromBlock,
    options.chunkSize,
    options.throttleMs
  );

  progress.log("Comparing CTM semantics");
  await compareSnapshotSemantics(provider, report, oldSnapshot, newSnapshot);
  progress.log("Checking protocol-version constraints");
  await compareProtocolVersionHistory(provider, report, oldSnapshot, newSnapshot);
  progress.log("Comparing component graph and bytecode");
  await compareComponentGraph(provider, report, oldSnapshot, newSnapshot);
  progress.log("Comparing component-specific state");
  await compareComponentSpecificState(provider, report, oldSnapshot, newSnapshot);

  if (oldSnapshot.proxyInitialization && newSnapshot.proxyInitialization) {
    compareValue(
      report,
      "ProxyInitialization.protocolVersion",
      oldSnapshot.proxyInitialization.initializeData.protocolVersion,
      newSnapshot.proxyInitialization.initializeData.protocolVersion
    );
  } else {
    pushReport(report, "best_effort", {
      label: "ProxyInitialization",
      message: "Proxy deployment calldata could not be decoded from Foundry artifacts in this workspace",
    });
  }

  if (options.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(await renderOwnershipModel(provider, newSnapshot));
    printTextReport(report);
  }
  progress.log("Finished");

  if (report.mismatch.length > 0) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});
