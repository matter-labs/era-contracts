import { BigNumber, ethers } from "ethers";

export interface ImmutableReference {
  start: number;
  length: number;
}

export interface DiffRange {
  start: number;
  end: number;
}

export interface ByteRange {
  start: number;
  end: number;
}

export interface BlockRange {
  fromBlock: number;
  toBlock: number;
}

export interface FacetCutComparison {
  label: string;
  facetAddress?: string;
  action: number;
  isFreezable: boolean;
  selectors: string[];
}

export interface DiamondCutComparison {
  facetCuts: FacetCutComparison[];
  initAddress: string;
  initCalldata: string;
}

export interface ChainCreationParamsComparison {
  genesisUpgrade: string;
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: string;
  genesisBatchCommitment: string;
  diamondCut: DiamondCutComparison;
  forceDeploymentsData: string;
}

export interface FixedForceDeploymentsDataComparison {
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

export interface ReplayedCtmState {
  latestChainCreationParams?: ChainCreationParamsComparison;
  latestInitialCutHash?: string;
  latestForceDeploymentHash?: string;
  upgradeCutHashByVersion: Record<string, string>;
  upgradeCutDataByVersion: Record<string, DiamondCutComparison>;
  protocolVersionDeadlineByVersion: Record<string, string>;
  protocolVersionsSeen: string[];
  validatorTimelock?: string;
  validatorTimelockPostV29?: string;
  serverNotifier?: string;
  pendingAdmin?: string;
  admin?: string;
}

export interface ParsedCtmEvent {
  name: string;
  blockNumber: number;
  logIndex: number;
  args: ethers.utils.Result;
}

export function normalizeAddress(value: string): string {
  return ethers.utils.getAddress(value).toLowerCase();
}

export function normalizeHex(value: string): string {
  return ethers.utils.hexlify(value).toLowerCase();
}

export function normalizeNumberish(value: ethers.BigNumberish): string {
  return BigNumber.from(value).toString();
}

export function normalizeSelectors(selectors: string[]): string[] {
  return selectors.map((selector) => selector.toLowerCase()).sort();
}

export function normalizeFacetCutForComparison(
  label: string,
  cut: {
    facetAddress?: string;
    action: number;
    isFreezable: boolean;
    selectors: string[];
  }
): FacetCutComparison {
  return {
    label,
    facetAddress: cut.facetAddress ? normalizeAddress(cut.facetAddress) : undefined,
    action: Number(cut.action),
    isFreezable: cut.isFreezable,
    selectors: normalizeSelectors(cut.selectors),
  };
}

export function compareFacetCuts(
  left: FacetCutComparison[],
  right: FacetCutComparison[]
): { equal: boolean; reason?: string } {
  if (left.length !== right.length) {
    return {
      equal: false,
      reason: `facet count mismatch (${left.length} != ${right.length})`,
    };
  }

  const normalize = (cuts: FacetCutComparison[]) =>
    cuts
      .map((cut) => ({
        ...cut,
        selectors: [...cut.selectors].sort(),
      }))
      .sort((a, b) => a.label.localeCompare(b.label));

  const leftNormalized = normalize(left);
  const rightNormalized = normalize(right);

  for (let index = 0; index < leftNormalized.length; index += 1) {
    const leftCut = leftNormalized[index];
    const rightCut = rightNormalized[index];
    if (leftCut.label !== rightCut.label) {
      return {
        equal: false,
        reason: `facet label mismatch (${leftCut.label} != ${rightCut.label})`,
      };
    }
    if (leftCut.action !== rightCut.action) {
      return {
        equal: false,
        reason: `facet action mismatch for ${leftCut.label}`,
      };
    }
    if (leftCut.isFreezable !== rightCut.isFreezable) {
      return {
        equal: false,
        reason: `facet freezability mismatch for ${leftCut.label}`,
      };
    }
    if (JSON.stringify(leftCut.selectors) !== JSON.stringify(rightCut.selectors)) {
      return {
        equal: false,
        reason: `facet selector mismatch for ${leftCut.label}`,
      };
    }
  }

  return { equal: true };
}

export function strip0x(value: string): string {
  return value.startsWith("0x") ? value.slice(2) : value;
}

function splitHexPairs(hexValue: string): string[] {
  const normalized = strip0x(hexValue).toLowerCase();
  if (normalized.length === 0) {
    return [];
  }
  if (normalized.length % 2 !== 0) {
    throw new Error(`Hex value must have an even number of nybbles, got ${normalized.length}`);
  }
  return normalized.match(/.{1,2}/g) ?? [];
}

export function maskHexAtRanges(hexValue: string, ranges: ImmutableReference[]): string {
  const bytes = splitHexPairs(hexValue);
  for (const range of ranges) {
    for (let offset = range.start; offset < range.start + range.length && offset < bytes.length; offset += 1) {
      bytes[offset] = "**";
    }
  }
  return `0x${bytes.join("")}`;
}

export function flattenImmutableReferences(
  references: Record<string, ImmutableReference[]>
): ImmutableReference[] {
  return Object.values(references).flat();
}

export function decodeImmutableValues(
  hexValue: string,
  references: Record<string, ImmutableReference[]>
): Record<string, string[]> {
  const normalized = strip0x(normalizeHex(hexValue));
  const decoded: Record<string, string[]> = {};

  for (const [key, ranges] of Object.entries(references)) {
    decoded[key] = ranges.map((range) => {
      const start = range.start * 2;
      const end = start + range.length * 2;
      return `0x${normalized.slice(start, end)}`;
    });
  }

  return decoded;
}

export function diffByteRanges(leftHex: string, rightHex: string): DiffRange[] {
  const left = splitHexPairs(leftHex);
  const right = splitHexPairs(rightHex);
  const maxLength = Math.max(left.length, right.length);
  const ranges: DiffRange[] = [];
  let currentStart: number | null = null;

  for (let index = 0; index < maxLength; index += 1) {
    const isDifferent = left[index] !== right[index];
    if (isDifferent && currentStart === null) {
      currentStart = index;
    }
    if (!isDifferent && currentStart !== null) {
      ranges.push({ start: currentStart, end: index - 1 });
      currentStart = null;
    }
  }

  if (currentStart !== null) {
    ranges.push({ start: currentStart, end: maxLength - 1 });
  }

  return ranges;
}

export function diffWordIndices(ranges: DiffRange[]): number[] {
  const words = new Set<number>();
  for (const range of ranges) {
    const startWord = Math.floor(range.start / 32);
    const endWord = Math.floor(range.end / 32);
    for (let word = startWord; word <= endWord; word += 1) {
      words.add(word);
    }
  }
  return Array.from(words).sort((a, b) => a - b);
}

export function getSolidityCborMetadataRange(hexValue: string): ByteRange | undefined {
  const normalized = strip0x(normalizeHex(hexValue));
  if (normalized.length < 4) {
    return undefined;
  }

  const totalBytes = normalized.length / 2;
  const metadataLength = parseInt(normalized.slice(-4), 16);
  const totalTrailerBytes = metadataLength + 2;
  if (!Number.isFinite(metadataLength) || totalTrailerBytes > totalBytes) {
    return undefined;
  }

  return {
    start: totalBytes - totalTrailerBytes,
    end: totalBytes - 1,
  };
}

export function buildDescendingBlockRanges(fromBlock: number, toBlock: number, chunkSize: number): BlockRange[] {
  if (chunkSize <= 0) {
    throw new Error(`chunkSize must be positive, got ${chunkSize}`);
  }

  if (toBlock < fromBlock) {
    return [];
  }

  const ranges: BlockRange[] = [];
  let currentTo = toBlock;

  while (currentTo >= fromBlock) {
    const currentFrom = Math.max(fromBlock, currentTo - chunkSize + 1);
    ranges.push({
      fromBlock: currentFrom,
      toBlock: currentTo,
    });
    currentTo = currentFrom - 1;
  }

  return ranges;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function pushProtocolVersion(state: ReplayedCtmState, version: ethers.BigNumberish) {
  const normalized = normalizeNumberish(version);
  if (!state.protocolVersionsSeen.includes(normalized)) {
    state.protocolVersionsSeen.push(normalized);
  }
}

export function createEmptyReplayedCtmState(): ReplayedCtmState {
  return {
    latestChainCreationParams: undefined,
    latestInitialCutHash: undefined,
    latestForceDeploymentHash: undefined,
    upgradeCutHashByVersion: {},
    upgradeCutDataByVersion: {},
    protocolVersionDeadlineByVersion: {},
    protocolVersionsSeen: [],
    validatorTimelock: undefined,
    validatorTimelockPostV29: undefined,
    serverNotifier: undefined,
    pendingAdmin: undefined,
    admin: undefined,
  };
}

function normalizeDiamondCut(rawCut: any): DiamondCutComparison {
  return {
    initAddress: normalizeAddress(rawCut.initAddress),
    initCalldata: normalizeHex(rawCut.initCalldata),
    facetCuts: (rawCut.facetCuts ?? []).map((cut: any, index: number) =>
      normalizeFacetCutForComparison(cut.label ?? `facet_${index}`, {
        facetAddress: cut.facet,
        action: Number(cut.action),
        isFreezable: Boolean(cut.isFreezable),
        selectors: Array.from(cut.selectors ?? []).map((selector: string) => selector.toLowerCase()),
      })
    ),
  };
}

export function replayCtmEvents(events: ParsedCtmEvent[]): ReplayedCtmState {
  const orderedEvents = [...events].sort((left, right) => {
    if (left.blockNumber !== right.blockNumber) {
      return left.blockNumber - right.blockNumber;
    }
    return left.logIndex - right.logIndex;
  });

  const state = createEmptyReplayedCtmState();

  for (const event of orderedEvents) {
    if (event.name === "NewChainCreationParams") {
      state.latestChainCreationParams = {
        genesisUpgrade: normalizeAddress(event.args.genesisUpgrade),
        genesisBatchHash: normalizeHex(event.args.genesisBatchHash),
        genesisIndexRepeatedStorageChanges: normalizeNumberish(event.args.genesisIndexRepeatedStorageChanges),
        genesisBatchCommitment: normalizeHex(event.args.genesisBatchCommitment),
        diamondCut: normalizeDiamondCut(event.args.newInitialCut),
        forceDeploymentsData: normalizeHex(event.args.forceDeploymentsData),
      };
      state.latestInitialCutHash = normalizeHex(event.args.newInitialCutHash);
      state.latestForceDeploymentHash = normalizeHex(event.args.forceDeploymentHash);
      continue;
    }

    if (event.name === "NewUpgradeCutHash") {
      const version = normalizeNumberish(event.args.protocolVersion);
      state.upgradeCutHashByVersion[version] = normalizeHex(event.args.upgradeCutHash);
      pushProtocolVersion(state, version);
      continue;
    }

    if (event.name === "NewUpgradeCutData") {
      const version = normalizeNumberish(event.args.protocolVersion);
      state.upgradeCutDataByVersion[version] = normalizeDiamondCut(event.args.diamondCutData);
      pushProtocolVersion(state, version);
      continue;
    }

    if (event.name === "NewProtocolVersion") {
      pushProtocolVersion(state, event.args.oldProtocolVersion);
      pushProtocolVersion(state, event.args.newProtocolVersion);
      continue;
    }

    if (event.name === "UpdateProtocolVersionDeadline") {
      const version = normalizeNumberish(event.args.protocolVersion);
      state.protocolVersionDeadlineByVersion[version] = normalizeNumberish(event.args.deadline);
      pushProtocolVersion(state, version);
      continue;
    }

    if (event.name === "NewValidatorTimelock") {
      state.validatorTimelock = normalizeAddress(event.args.newValidatorTimelock);
      continue;
    }

    if (event.name === "NewValidatorTimelockPostV29") {
      state.validatorTimelockPostV29 = normalizeAddress(event.args.newvalidatorTimelockPostV29);
      continue;
    }

    if (event.name === "NewServerNotifier") {
      state.serverNotifier = normalizeAddress(event.args.newServerNotifier);
      continue;
    }

    if (event.name === "NewPendingAdmin") {
      const nextAdmin = normalizeAddress(event.args.newPendingAdmin);
      state.pendingAdmin = nextAdmin === ethers.constants.AddressZero ? undefined : nextAdmin;
      continue;
    }

    if (event.name === "NewAdmin") {
      state.admin = normalizeAddress(event.args.newAdmin);
    }
  }

  state.protocolVersionsSeen.sort((left, right) => {
    const leftNumber = BigNumber.from(left);
    const rightNumber = BigNumber.from(right);
    if (leftNumber.lt(rightNumber)) {
      return -1;
    }
    if (leftNumber.gt(rightNumber)) {
      return 1;
    }
    return 0;
  });
  return state;
}

export function getLegacyProtocolVersions(
  oldProtocolVersions: string[],
  latestProtocolVersion: ethers.BigNumberish
): string[] {
  const latest = normalizeNumberish(latestProtocolVersion);
  return oldProtocolVersions
    .map((version) => normalizeNumberish(version))
    .filter((version) => version !== latest)
    .sort((left, right) => {
      const leftNumber = BigNumber.from(left);
      const rightNumber = BigNumber.from(right);
      if (leftNumber.lt(rightNumber)) {
        return -1;
      }
      if (leftNumber.gt(rightNumber)) {
        return 1;
      }
      return 0;
    });
}

const fixedForceDeploymentsAbiType =
  "tuple(uint256 l1ChainId,uint256 eraChainId,address l1AssetRouter,bytes32 l2TokenProxyBytecodeHash,address aliasedL1Governance,uint256 maxNumberOfZKChains,bytes32 bridgehubBytecodeHash,bytes32 l2AssetRouterBytecodeHash,bytes32 l2NtvBytecodeHash,bytes32 messageRootBytecodeHash,bytes32 chainAssetHandlerBytecodeHash,address l2SharedBridgeLegacyImpl,address l2BridgedStandardERC20Impl,address dangerousTestOnlyForcedBeacon)";

export function decodeFixedForceDeploymentsData(data: string): FixedForceDeploymentsDataComparison {
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

export function decodeConsistentImmutableNumberish(values: string[]): string | undefined {
  if (values.length === 0) {
    return undefined;
  }

  const normalizedValues = values.map((value) => normalizeNumberish(BigNumber.from(value)));
  const [firstValue] = normalizedValues;
  const allEqual = normalizedValues.every((value) => value === firstValue);

  return allEqual ? firstValue : undefined;
}
