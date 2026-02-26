import { BigNumber, Contract, ethers, providers } from "ethers";
import { gwAssetTrackerAbi, l2BridgehubAbi, l2MessageRootAbi } from "./contracts";
import { impersonateAndRun } from "./utils";
import {
  CHAIN_ID_LEAF_PADDING,
  FINALIZE_DEPOSIT_SIG,
  GW_ASSET_TRACKER_ADDR,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH,
  L2_MESSAGE_ROOT_ADDR,
  L2_TO_L1_LOGS_MERKLE_TREE_DEPTH,
  L2_TO_L1_MESSENGER_ADDR,
} from "./const";

// ───────────────────────────────────────────────────────────────
// Types
// ───────────────────────────────────────────────────────────────

export interface L2Log {
  l2ShardId: number;
  isService: boolean;
  txNumberInBatch: number;
  sender: string;
  key: string;
  value: string;
}

export interface ProcessLogsResult {
  txHash: string;
  logsRoot: string;
  messageRoot: string;
  chainBatchRoot: string;
}

// ───────────────────────────────────────────────────────────────
// Merkle tree helpers (matching DynamicIncrementalMerkleMemory)
// ───────────────────────────────────────────────────────────────

/**
 * efficientHash — keccak256(left ++ right) matching Merkle.efficientHash in Solidity.
 */
function efficientHash(left: string, right: string): string {
  return ethers.utils.keccak256(ethers.utils.concat([left, right]));
}

/**
 * Hash an L2Log into a leaf, matching MessageHashing.getLeafHashFromLog:
 *   keccak256(abi.encodePacked(l2ShardId, isService, txNumberInBatch, sender, key, value))
 *
 * Packed encoding: uint8 + bool(uint8) + uint16 + address(20) + bytes32 + bytes32 = 88 bytes
 */
export function hashLog(log: L2Log): string {
  return ethers.utils.keccak256(
    ethers.utils.solidityPack(
      ["uint8", "bool", "uint16", "address", "bytes32", "bytes32"],
      [log.l2ShardId, log.isService, log.txNumberInBatch, log.sender, log.key, log.value]
    )
  );
}

/**
 * Build the logs Merkle root matching DynamicIncrementalMerkleMemory with:
 *   createTree(L2_TO_L1_LOGS_MERKLE_TREE_DEPTH)   // depth = 15
 *   setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH)
 *   for each log: push(hashLog(log))
 *   extendUntilEnd()
 *   return root()
 *
 * The DynamicIncrementalMerkle is an incremental tree that starts at depth 0
 * and grows dynamically. After extendUntilEnd() it fills the tree up to the
 * maximum depth (15) using zeros[level] for missing subtrees.
 *
 * We replicate this with a straightforward simulation of the push + extendUntilEnd algorithm.
 */
export function buildLogsMerkleRoot(logs: L2Log[]): string {
  // State matching the Solidity struct
  const maxDepth = L2_TO_L1_LOGS_MERKLE_TREE_DEPTH; // 15
  const sides: string[] = new Array(maxDepth + 1).fill(ethers.constants.HashZero);
  const zeros: string[] = new Array(maxDepth + 1).fill(ethers.constants.HashZero);
  let sidesLen = 0;
  let zerosLen = 0;
  let nextLeafIndex = 0;

  // setup(defaultLeaf) — initializes zeros[0], sides[0], lengths=1
  zeros[0] = L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH;
  zerosLen = 1;
  sides[0] = ethers.constants.HashZero;
  sidesLen = 1;

  // push each log leaf
  for (const log of logs) {
    const leaf = hashLog(log);
    const leafIndex = nextLeafIndex++;
    let levels = zerosLen - 1;

    // Grow tree if full at current level
    if (leafIndex === 1 << levels) {
      const zero = zeros[levels];
      const newZero = efficientHash(zero, zero);
      zeros[zerosLen] = newZero;
      zerosLen++;
      sides[sidesLen] = ethers.constants.HashZero;
      sidesLen++;
      levels++;
    }

    // Rebuild branch from leaf to root
    let currentIndex = leafIndex;
    let currentLevelHash = leaf;
    let updatedSides = false;
    for (let i = 0; i < levels; i++) {
      const isLeft = currentIndex % 2 === 0;

      if (isLeft && !updatedSides) {
        sides[i] = currentLevelHash;
        updatedSides = true;
      }

      currentLevelHash = isLeft
        ? efficientHash(currentLevelHash, zeros[i])
        : efficientHash(sides[i], currentLevelHash);

      currentIndex >>= 1;
    }
    // Store root in sides[levels]
    sides[levels] = currentLevelHash;
  }

  // extendUntilEnd() — extend from current depth up to maxDepth
  let currentZero = zeros[zerosLen - 1];
  if (nextLeafIndex === 0) {
    sides[0] = currentZero;
  }
  let currentSide = sides[sidesLen - 1];
  const finalDepth = maxDepth; // sides.length in Solidity = _treeDepth from createTree

  for (let i = sidesLen; i < finalDepth; i++) {
    currentSide = efficientHash(currentSide, currentZero);
    currentZero = efficientHash(currentZero, currentZero);
    zeros[i] = currentZero;
    sides[i] = currentSide;
  }
  sidesLen = finalDepth;
  zerosLen = finalDepth;

  // root() — the last element of sides
  return sides[sidesLen - 1];
}

// ───────────────────────────────────────────────────────────────
// Empty message root computation (matching _getEmptyMessageRoot)
// ───────────────────────────────────────────────────────────────

/**
 * Compute the empty message root for a given chain ID.
 * Matches GWAssetTracker._getEmptyMessageRoot():
 *
 *   FullMerkleMemory sharedTree; sharedTree.createTree(1); sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
 *   DynamicIncrementalMerkle chainTree; chainTree.createTree(1); initialChainTreeHash = chainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
 *   leafHash = MessageHashing.chainIdLeafHash(initialChainTreeHash, chainId);
 *   emptyMessageRoot = sharedTree.pushNewLeaf(leafHash);
 *
 * chainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH) returns bytes32(0) (setup always returns 0).
 * chainIdLeafHash(bytes32(0), chainId) = keccak256(abi.encodePacked(CHAIN_ID_LEAF_PADDING, bytes32(0), uint256(chainId)))
 *
 * sharedTree is FullMerkle with depth=1, setup(SHARED_ROOT_TREE_EMPTY_HASH).
 * pushNewLeaf(leafHash) inserts leafHash at index 0 into a depth-1 tree.
 * For a depth-1 tree with a single leaf at index 0:
 *   root = hash(leaf, zeros[0]) where zeros[0] = SHARED_ROOT_TREE_EMPTY_HASH
 */
export function computeEmptyMessageRoot(chainId: number): string {
  // DynamicIncrementalMerkle setup returns bytes32(0)
  const initialChainTreeHash = ethers.constants.HashZero;

  // chainIdLeafHash(initialChainTreeHash, chainId)
  const leafHash = ethers.utils.keccak256(
    ethers.utils.solidityPack(
      ["bytes32", "bytes32", "uint256"],
      [CHAIN_ID_LEAF_PADDING, initialChainTreeHash, chainId]
    )
  );

  // FullMerkle createTree(1) → maxLeafNumber=1, height=0
  // pushNewLeaf(leafHash) with height=0 → updateLeaf just returns leafHash directly
  // (no parent hashing when tree height is 0)
  return leafHash;
}

// ───────────────────────────────────────────────────────────────
// Log + message construction helpers
// ───────────────────────────────────────────────────────────────

/**
 * Build an AssetRouter withdrawal L2Log + message.
 *
 * This represents a withdrawal from an L2 chain (settled on GW) going to L1.
 * The message format matches DataEncoding.encodeAssetRouterFinalizeDepositData:
 *   abi.encodePacked(finalizeDeposit.selector, uint256 messageSourceChainId, bytes32 assetId, bytes transferData)
 * Where transferData = abi.encode(originalCaller, receiver, originToken, amount, erc20Metadata)
 */
export function buildAssetRouterWithdrawalLog(params: {
  txNumberInBatch: number;
  assetId: string;
  amount: BigNumber;
  receiver: string;
  originToken: string;
  originalCaller: string;
  tokenOriginChainId: number;
}): { log: L2Log; message: string } {
  const abiCoder = ethers.utils.defaultAbiCoder;

  // erc20Metadata = NEW_ENCODING_VERSION (0x01) ++ abi.encode(tokenOriginChainId, name, symbol, decimals)
  // Matches DataEncoding.encodeTokenData format
  const erc20MetadataInner = abiCoder.encode(
    ["uint256", "bytes", "bytes", "bytes"],
    [params.tokenOriginChainId, "0x", "0x", "0x"]
  );
  const erc20Metadata = ethers.utils.hexlify(
    ethers.utils.concat(["0x01", erc20MetadataInner])
  );

  // transferData = abi.encode(originalCaller, receiver, originToken, amount, erc20Metadata)
  const transferData = abiCoder.encode(
    ["address", "address", "address", "uint256", "bytes"],
    [params.originalCaller, params.receiver, params.originToken, params.amount, erc20Metadata]
  );

  const finalizeDepositSelector = ethers.utils.id(FINALIZE_DEPOSIT_SIG).slice(0, 10);

  // message = abi.encodePacked(selector, messageSourceChainId=0, assetId, transferData)
  const message = ethers.utils.hexlify(
    ethers.utils.concat([
      finalizeDepositSelector,
      ethers.utils.hexZeroPad(ethers.BigNumber.from(0).toHexString(), 32), // messageSourceChainId (not used)
      params.assetId,
      transferData,
    ])
  );

  const log: L2Log = {
    l2ShardId: 0,
    isService: true,
    txNumberInBatch: params.txNumberInBatch,
    sender: L2_TO_L1_MESSENGER_ADDR,
    key: ethers.utils.hexZeroPad(L2_ASSET_ROUTER_ADDR, 32),
    value: ethers.utils.keccak256(message),
  };

  return { log, message };
}

/**
 * Build an InteropCenter bundle L2Log + message.
 *
 * The message format is: 0x01 ++ abi.encode(InteropBundle)
 * The log key is bytes32(uint256(uint160(INTEROP_CENTER_ADDR)))
 */
export function buildInteropBundleLog(params: {
  txNumberInBatch: number;
  interopBundle: unknown;
}): { log: L2Log; message: string } {
  const abiCoder = ethers.utils.defaultAbiCoder;

  // BUNDLE_IDENTIFIER = 0x01
  const bundleEncoded = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [params.interopBundle]);
  const message = ethers.utils.hexlify(ethers.utils.concat(["0x01", bundleEncoded]));

  const log: L2Log = {
    l2ShardId: 0,
    isService: true,
    txNumberInBatch: params.txNumberInBatch,
    sender: L2_TO_L1_MESSENGER_ADDR,
    key: ethers.utils.hexZeroPad(INTEROP_CENTER_ADDR, 32),
    value: ethers.utils.keccak256(message),
  };

  return { log, message };
}

// ───────────────────────────────────────────────────────────────
// callProcessLogsAndMessages
// ───────────────────────────────────────────────────────────────

/**
 * Look up the chain's ZKChain address on GW Bridgehub.
 * Chains must be registered during setup (step 5) via gateway-setup.ts.
 */
async function getZKChainAddressOnGW(
  gwProvider: providers.JsonRpcProvider,
  chainId: number
): Promise<string> {
  const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BridgehubAbi(), gwProvider);
  const addr: string = await bridgehub.getZKChain(chainId);
  if (addr === ethers.constants.AddressZero) {
    throw new Error(
      `Chain ${chainId} not registered on GW Bridgehub. Ensure step 5 (gateway setup) ran correctly.`
    );
  }
  return addr;
}

/**
 * Call GWAssetTracker.processLogsAndMessages on the gateway chain.
 *
 * Steps:
 * 1. Compute logsRoot from logs
 * 2. Compute messageRoot (empty message root for the chain)
 * 3. Compute chainBatchRoot = keccak256(logsRoot ++ messageRoot)
 * 4. Resolve the chain's diamond proxy on GW (from zkChainAddress param or L2Bridgehub)
 * 5. Impersonate that address (onlyChain modifier)
 * 6. Call processLogsAndMessages
 */
export async function callProcessLogsAndMessages(params: {
  gwProvider: providers.JsonRpcProvider;
  gwRpcUrl: string;
  chainId: number;
  batchNumber?: number;
  logs: L2Log[];
  messages: string[];
  zkChainAddress?: string;
  logger?: (line: string) => void;
}): Promise<ProcessLogsResult> {
  const log = params.logger || console.log;
  const { gwProvider, chainId, logs, messages } = params;

  // Auto-detect batch number if not provided: query currentChainBatchNumber + 1
  let batchNumber = params.batchNumber;
  if (batchNumber === undefined) {
    const messageRoot = new Contract(L2_MESSAGE_ROOT_ADDR, l2MessageRootAbi(), gwProvider);
    const currentBatch: BigNumber = await messageRoot.currentChainBatchNumber(chainId);
    batchNumber = currentBatch.toNumber() + 1;
  }

  // 1. Compute logs root
  const logsRoot = buildLogsMerkleRoot(logs);
  log(`   Logs root: ${logsRoot}`);

  // 2. Compute empty message root
  const messageRoot = computeEmptyMessageRoot(chainId);
  log(`   Message root: ${messageRoot}`);

  // 3. Compute chain batch root
  const chainBatchRoot = efficientHash(logsRoot, messageRoot);
  log(`   Chain batch root: ${chainBatchRoot}`);

  // 4. Resolve the chain's diamond proxy on GW
  let zkChainAddr: string;
  if (params.zkChainAddress) {
    zkChainAddr = params.zkChainAddress;
    log(`   Using provided ZK Chain address: ${zkChainAddr}`);
  } else {
    zkChainAddr = await getZKChainAddressOnGW(gwProvider, chainId);
    log(`   ZK Chain diamond proxy on GW: ${zkChainAddr}`);
  }

  // 5. Encode the ProcessLogsInput struct
  // Convert logs to the Solidity tuple format
  const solidityLogs = logs.map((l) => [l.l2ShardId, l.isService, l.txNumberInBatch, l.sender, l.key, l.value]);

  // 6. Impersonate the diamond proxy address (passes onlyChain modifier)
  const gwAssetTracker = new Contract(GW_ASSET_TRACKER_ADDR, gwAssetTrackerAbi(), gwProvider);

  const txHash = await impersonateAndRun(gwProvider, zkChainAddr, async (signer) => {
    const trackerAsSigner = gwAssetTracker.connect(signer);

    const processLogsInput = {
      logs: solidityLogs,
      messages,
      chainId,
      batchNumber,
      chainBatchRoot,
      messageRoot,
      settlementFeePayer: ethers.constants.AddressZero,
    };

    const tx = await trackerAsSigner.processLogsAndMessages(processLogsInput, {
      gasLimit: 10_000_000,
    });
    await tx.wait();
    log(`   processLogsAndMessages tx: cast run ${tx.hash} -r ${params.gwRpcUrl}`);
    return tx.hash;
  });

  return { txHash, logsRoot, messageRoot, chainBatchRoot };
}

/**
 * Helper to read GWAssetTracker.chainBalance(chainId, assetId) on the GW.
 */
export async function getGWChainBalance(
  gwProvider: providers.JsonRpcProvider,
  chainId: number,
  assetId: string
): Promise<BigNumber> {
  const abi = gwAssetTrackerAbi();
  const tracker = new Contract(GW_ASSET_TRACKER_ADDR, abi, gwProvider);
  return tracker.chainBalance(chainId, assetId);
}

/**
 * Query the ETH asset ID from the Bridgehub on GW (baseTokenAssetId for a chain).
 */
export async function getBaseTokenAssetId(
  gwProvider: providers.JsonRpcProvider,
  chainId: number
): Promise<string> {
  const bridgehubAbi = l2BridgehubAbi();
  const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, bridgehubAbi, gwProvider);
  return bridgehub.baseTokenAssetId(chainId);
}
