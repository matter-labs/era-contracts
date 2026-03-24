import { ethers, providers } from "ethers";
import { parse as parseToml } from "toml";
import * as fs from "fs";
import * as path from "path";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_FUND_BALANCE,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L1_CHAIN_ID,
  L1_MESSAGE_SENT_EVENT_SIG,
  L1_TO_L2_ALIAS_OFFSET,
  L2_ASSET_TRACKER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  NEW_PRIORITY_REQUEST_EVENT_SIG,
} from "./const";
import { getAbi } from "./contracts";
import type {
  AnvilChainConfig,
  ChainAddresses,
  ChainInfo,
  ChainRole,
  DeploymentState,
  FinalizeWithdrawalParams,
  InteropBundle,
  L2ChainInfo,
  PriorityRequestData,
} from "./types";

/**
 * Simple timing helper: call to start, invoke the returned function to log elapsed time.
 */
export function timeIt(label: string, prefix = "⏱️  [TIMING]"): () => void {
  const start = Date.now();
  console.log(`${prefix} Starting: ${label}`);
  return () => console.log(`${prefix} Finished: ${label} in ${((Date.now() - start) / 1000).toFixed(1)}s`);
}

export async function waitForChainReady(rpcUrl: string, maxAttempts = 30): Promise<boolean> {
  const provider = new providers.JsonRpcProvider(rpcUrl);

  for (let i = 0; i < maxAttempts; i++) {
    try {
      const chainId = await provider.send("eth_chainId", []);
      if (chainId) {
        console.log(`✅ Chain ready at ${rpcUrl}, chainId: ${chainId}`);
        return true;
      }
    } catch (error) {
      await sleep(1000);
    }
  }

  console.error(`❌ Chain at ${rpcUrl} not ready after ${maxAttempts} attempts`);
  return false;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Assert that a contract is deployed (has code) at the given address.
 * Throws with a descriptive message if the address has no code.
 */
export async function assertContractDeployed(
  provider: providers.JsonRpcProvider,
  address: string,
  label: string
): Promise<void> {
  const code = await provider.getCode(address);
  if (code === "0x" || code === "0x0") {
    throw new Error(`${label} at ${address} has no code — contract not deployed`);
  }
}

export function saveTomlConfig(filePath: string, data: Record<string, unknown>): void {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const lines: string[] = [];

  function writeSection(obj: Record<string, unknown>, prefix = ""): void {
    const entries = Object.entries(obj);

    for (const [key, value] of entries) {
      if (value && typeof value === "object" && !Array.isArray(value)) {
        continue;
      }

      if (typeof value === "string") {
        lines.push(`${key} = "${value}"`);
      } else if (typeof value === "boolean") {
        lines.push(`${key} = ${value}`);
      } else if (typeof value === "number") {
        lines.push(`${key} = ${value}`);
      } else if (Array.isArray(value)) {
        lines.push(`${key} = [${value.map((v) => (typeof v === "string" ? `"${v}"` : v)).join(", ")}]`);
      }
    }

    for (const [key, value] of entries) {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        continue;
      }

      const fullKey = prefix ? `${prefix}.${key}` : key;
      lines.push(`\n[${fullKey}]`);
      writeSection(value as Record<string, unknown>, fullKey);
    }
  }

  writeSection(data);
  fs.writeFileSync(filePath, lines.join("\n"));
}

export function parseForgeScriptOutput(outputPath: string): Record<string, unknown> {
  if (!fs.existsSync(outputPath)) {
    throw new Error(`Output file not found: ${outputPath}`);
  }

  const content = fs.readFileSync(outputPath, "utf-8");
  return parseToml(content);
}

export function ensureDirectoryExists(dirPath: string): void {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

/**
 * Find an L2 chain by chain ID in the deployment state, or throw.
 */
export function getL2Chain(chains: ChainInfo, chainId: number): L2ChainInfo {
  const chain = chains.l2.find((c) => c.chainId === chainId);
  if (!chain) {
    throw new Error(`L2 chain ${chainId} not found. Available: ${chains.l2.map((c) => c.chainId).join(", ")}`);
  }
  return chain;
}

/**
 * Find a chain's diamond proxy address by chain ID, or throw.
 */
export function getChainDiamondProxy(chainAddresses: ChainAddresses[], chainId: number): string {
  const addr = chainAddresses.find((c) => c.chainId === chainId);
  if (!addr) {
    throw new Error(`Chain addresses for ${chainId} not found`);
  }
  return addr.diamondProxy;
}

/**
 * Find the chain ID with a given role from the anvil config.
 */
export function getChainIdByRole(config: AnvilChainConfig[], role: ChainRole): number {
  const chain = config.find((c) => c.role === role);
  if (!chain) {
    throw new Error(`No chain with role '${role}' found in config`);
  }
  return chain.chainId;
}

/**
 * Find all chain IDs with a given role from the anvil config.
 */
export function getChainIdsByRole(config: AnvilChainConfig[], role: ChainRole): number[] {
  return config.filter((c) => c.role === role).map((c) => c.chainId);
}

export function formatChainInfo(chainId: number, port: number, isL1: boolean): string {
  const type = isL1 ? "L1" : "L2";
  return `${type} Chain ${chainId} on port ${port}`;
}

/**
 * Convenience accessor: get the L1 RPC URL from deployment state.
 */
export function getL1RpcUrl(state: DeploymentState): string {
  if (!state.chains?.l1) {
    throw new Error("Deployment state missing L1 chain");
  }
  return state.chains.l1.rpcUrl;
}

/**
 * Convenience accessor: get the RPC URL for an L2 chain from deployment state.
 */
export function getL2RpcUrl(state: DeploymentState, chainId: number): string {
  return getL2Chain(state.chains!, chainId).rpcUrl;
}

/**
 * Impersonate an account on Anvil, fund it, run the callback, then stop impersonating.
 */
export async function impersonateAndRun<T>(
  provider: providers.JsonRpcProvider,
  account: string,
  fn: (signer: providers.JsonRpcSigner) => Promise<T>
): Promise<T> {
  await provider.send("anvil_impersonateAccount", [account]);
  await provider.send("anvil_setBalance", [account, ANVIL_FUND_BALANCE]);
  try {
    const signer = provider.getSigner(account);
    return await fn(signer);
  } finally {
    await provider.send("anvil_stopImpersonatingAccount", [account]);
  }
}

/**
 * Apply L1-to-L2 address alias (AddressAliasHelper.applyL1ToL2Alias).
 */
export function applyL1ToL2Alias(l1Address: string): string {
  const result = ethers.BigNumber.from(l1Address)
    .add(ethers.BigNumber.from(L1_TO_L2_ALIAS_OFFSET))
    .mod(ethers.BigNumber.from(2).pow(160));
  return ethers.utils.getAddress(ethers.utils.hexZeroPad(result.toHexString(), 20));
}

/**
 * Build the merkle proof for withdrawal finalization.
 *
 * DummyL1MessageRoot bypasses verification, but getProofData() still parses the
 * proof structure to extract settlementLayerChainId (used by L1AssetTracker to
 * update the correct chainBalance).
 *
 * For direct settlement (chain on L1): old format → settlementLayerChainId = 0
 * For gateway settlement: new format → settlementLayerChainId = GW chain ID
 */
export function buildWithdrawalMerkleProof(settlementLayerChainId: number): string[] {
  if (settlementLayerChainId > 0) {
    // New format: metadata + logLeafSibling + batchLeafProofMask + packedBatchInfo + slChainId
    // Metadata: version=0x01, logLeafProofLen=1, batchLeafProofLen=0, finalProofNode=0
    return [
      "0x0101000000000000000000000000000000000000000000000000000000000000",
      ethers.constants.HashZero, // log leaf merkle sibling (dummy)
      ethers.constants.HashZero, // batchLeafProofMask = 0
      ethers.constants.HashZero, // packed(settlementLayerBatchNumber=0, batchRootMask=0)
      ethers.utils.hexZeroPad(ethers.utils.hexlify(settlementLayerChainId), 32),
    ];
  } else {
    // Old format: single non-zero element → finalProofNode=true → settlementLayerChainId=0
    return ["0x0000000100000001000000010000000100000001000000010000000100000001"];
  }
}

/**
 * Determine the settlement layer chain ID for a given chain.
 * Returns 0 for direct L1 settlement, or the GW chain ID for gateway settlement.
 */
export async function getSettlementLayerChainId(
  l1Provider: providers.JsonRpcProvider,
  bridgehubAddr: string,
  chainId: number
): Promise<number> {
  const bridgehub = new ethers.Contract(bridgehubAddr, getAbi("IL1Bridgehub"), l1Provider);
  const slChainId = await bridgehub.settlementLayer(chainId);
  const slChainIdNum = slChainId.toNumber();
  const isGatewaySettled = slChainIdNum !== 0 && slChainIdNum !== L1_CHAIN_ID;
  return isGatewaySettled ? slChainIdNum : 0;
}

/**
 * Extract FinalizeWithdrawalParams from an L2 transaction receipt.
 *
 * Parses the L1MessageSent event from the L1MessengerZKOS and builds
 * the finalization params needed to call receiveL1ToGatewayMigrationOnL1 on L1.
 * Uses an empty merkle proof (relies on DummyL1MessageRoot returning true).
 */
export function buildFinalizeWithdrawalParams(
  l2Receipt: ethers.providers.TransactionReceipt,
  chainId: number
): FinalizeWithdrawalParams {
  // Parse L1MessageSent event from L1MessengerZKOS
  const l1MessageSentTopic = ethers.utils.id(L1_MESSAGE_SENT_EVENT_SIG);
  const l1MessageSentLog = l2Receipt.logs.find((logEntry) => logEntry.topics[0] === l1MessageSentTopic);

  if (!l1MessageSentLog) {
    throw new Error("L1MessageSent event not found in L2 tx receipt. Check L1MessengerZKOS emits the event.");
  }

  // Decode the message bytes from the event data
  // Event: L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message)
  const messageBytes = ethers.utils.defaultAbiCoder.decode(["bytes"], l1MessageSentLog.data)[0] as string;

  return {
    chainId,
    l2BatchNumber: 0,
    l2MessageIndex: 0,
    l2Sender: L2_ASSET_TRACKER_ADDR,
    l2TxNumberInBatch: 0,
    message: messageBytes,
    merkleProof: [], // Empty proof — DummyL1MessageRoot always returns true
  };
}

/**
 * Extract {from, to, calldata} tuples from NewPriorityRequest events in an L1 receipt.
 *
 * Filters logs by the given diamond proxy address and decodes the NewPriorityRequest
 * event to extract the sender, destination, and calldata from the transaction struct.
 */
export function extractNewPriorityRequests(
  receipt: ethers.providers.TransactionReceipt,
  diamondProxyAddr?: string
): PriorityRequestData[] {
  const newPriorityRequestTopic = ethers.utils.id(NEW_PRIORITY_REQUEST_EVENT_SIG);

  const priorityRequestLogs = receipt.logs.filter((logEntry) => {
    if (logEntry.topics[0] !== newPriorityRequestTopic) return false;
    if (diamondProxyAddr) {
      return logEntry.address.toLowerCase() === diamondProxyAddr.toLowerCase();
    }
    return true;
  });

  const mailboxIface = new ethers.utils.Interface(getAbi("MailboxFacet"));

  return priorityRequestLogs.map((logEntry) => {
    const parsed = mailboxIface.parseLog({ topics: logEntry.topics, data: logEntry.data });
    const toUint256 = ethers.BigNumber.from(parsed.args.transaction.to);
    const fromUint256 = ethers.BigNumber.from(parsed.args.transaction.from);
    return {
      from: ethers.utils.getAddress(ethers.utils.hexZeroPad(fromUint256.toHexString(), 20)),
      to: ethers.utils.getAddress(ethers.utils.hexZeroPad(toUint256.toHexString(), 20)),
      calldata: parsed.args.transaction.data,
      value: ethers.BigNumber.from(parsed.args.transaction.value),
    };
  });
}

/**
 * Relay a transaction on an Anvil chain by impersonating the given sender.
 * Returns { txHash, success, receipt } — does NOT throw on revert.
 */
export async function relayTx(
  provider: providers.JsonRpcProvider,
  from: string,
  to: string,
  calldata: string,
  value?: ethers.BigNumber
): Promise<{ txHash: string; success: boolean; receipt?: ethers.providers.TransactionReceipt }> {
  try {
    return await impersonateAndRun(provider, from, async (signer) => {
      const tx = await signer.sendTransaction({
        to,
        data: calldata,
        gasLimit: 30_000_000,
        ...(value && !value.isZero() ? { value } : {}),
      });
      const receipt = await tx.wait();
      return { txHash: receipt.transactionHash, success: receipt.status === 1, receipt };
    });
  } catch (error) {
    // Transaction may have reverted — return failure instead of throwing
    const msg = error instanceof Error ? error.message : String(error);
    console.warn(`   relayTx reverted: ${msg.slice(0, 200)}`);
    return { txHash: "", success: false };
  }
}

interface PriorityRelayChainTarget {
  diamondProxy: string;
  provider: providers.JsonRpcProvider;
}

interface PriorityRelayResolvedPath {
  l1RpcUrl: string;
  bridgehubAddr: string;
  chainId: number;
  chainRpcUrl: string;
  gwRpcUrl?: string;
}

async function relayPriorityRequestsToTargets(
  receipt: ethers.providers.TransactionReceipt,
  chains: PriorityRelayChainTarget[],
  log: (line: string) => void
): Promise<string[]> {
  // Relay across different target chains in parallel (different providers = no nonce conflicts).
  // Within each chain, requests are relayed sequentially (same impersonated sender).
  const perChainResults = await Promise.all(
    chains.map(async (chain) => {
      const hashes: string[] = [];
      const requests = extractNewPriorityRequests(receipt, chain.diamondProxy);
      for (const req of requests) {
        log(`   Relaying priority request from ${req.from} to ${req.to} via proxy ${chain.diamondProxy}`);
        const result = await relayTx(chain.provider, req.from, req.to, req.calldata, req.value);
        if (result.success) {
          hashes.push(result.txHash);
          log(`   Relay tx: cast run ${result.txHash} -r ${chain.provider.connection.url}`);
        } else {
          throw new Error(`Relay tx failed: from=${req.from} to=${req.to} via proxy ${chain.diamondProxy}`);
        }
      }
      return hashes;
    })
  );

  return perChainResults.flat();
}

async function resolvePriorityRelayPath(path: PriorityRelayResolvedPath): Promise<{
  l2Provider: providers.JsonRpcProvider;
  l1DiamondProxy: string;
  settlementLayerChainId: number;
  gwProvider?: providers.JsonRpcProvider;
  gwDiamondProxy?: string;
  nestedL1DiamondProxy?: string;
}> {
  const l1Provider = new providers.JsonRpcProvider(path.l1RpcUrl);
  const l2Provider = new providers.JsonRpcProvider(path.chainRpcUrl);
  const bridgehub = new ethers.Contract(path.bridgehubAddr, getAbi("L1Bridgehub"), l1Provider);
  const settlementLayerChainId = await getSettlementLayerChainId(l1Provider, path.bridgehubAddr, path.chainId);
  const relayChainId = settlementLayerChainId === 0 ? path.chainId : settlementLayerChainId;
  const l1DiamondProxy: string = await bridgehub.getZKChain(relayChainId);

  if (l1DiamondProxy === ethers.constants.AddressZero) {
    const targetLabel =
      settlementLayerChainId === 0
        ? `target chain ${path.chainId}`
        : `gateway settlement layer ${settlementLayerChainId} for chain ${path.chainId}`;
    throw new Error(`No L1 diamond proxy registered for ${targetLabel}`);
  }

  if (settlementLayerChainId === 0) {
    return { l2Provider, l1DiamondProxy, settlementLayerChainId };
  }

  if (!path.gwRpcUrl) {
    throw new Error(
      `Chain ${path.chainId} settles through gateway chain ${settlementLayerChainId}; gwRpcUrl is required`
    );
  }

  // For GW-settled chains, the nested chain also has an L1 diamond proxy.
  // The L1 receipt contains NewPriorityRequest from BOTH:
  //   - The GW's L1 diamond proxy (wrapped tx for the GW chain)
  //   - The nested chain's L1 diamond proxy (original tx for the L2 chain)
  const nestedL1DiamondProxy: string = await bridgehub.getZKChain(path.chainId);
  if (nestedL1DiamondProxy === ethers.constants.AddressZero) {
    throw new Error(`No L1 diamond proxy registered for nested chain ${path.chainId}`);
  }

  const gwProvider = new providers.JsonRpcProvider(path.gwRpcUrl);
  const gwBridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);
  const gwDiamondProxy: string = await gwBridgehub.getZKChain(path.chainId);

  if (gwDiamondProxy === ethers.constants.AddressZero) {
    throw new Error(`No GW diamond proxy registered for chain ${path.chainId}`);
  }

  return {
    l2Provider,
    l1DiamondProxy,
    settlementLayerChainId,
    gwProvider,
    gwDiamondProxy,
    nestedL1DiamondProxy,
  };
}

/**
 * Extract NewPriorityRequest events from a receipt and relay them to the target chains.
 *
 * Supports two modes:
 * - explicit targets: relay the receipt's requests to the given diamond proxy / provider pairs
 * - resolved chain path: look up settlement on L1Bridgehub and relay to L2 directly or via GW
 *
 * @returns Array of relay transaction hashes
 */
export async function extractAndRelayNewPriorityRequests(
  receipt: ethers.providers.TransactionReceipt,
  chainsOrPath: PriorityRelayChainTarget[] | PriorityRelayResolvedPath,
  logger?: (line: string) => void
): Promise<string[]> {
  const log = logger || console.log;

  if (Array.isArray(chainsOrPath)) {
    return relayPriorityRequestsToTargets(receipt, chainsOrPath, log);
  }

  const { l2Provider, l1DiamondProxy, settlementLayerChainId, gwProvider, gwDiamondProxy, nestedL1DiamondProxy } =
    await resolvePriorityRelayPath(chainsOrPath);

  if (settlementLayerChainId === 0) {
    return relayPriorityRequestsToTargets(receipt, [{ diamondProxy: l1DiamondProxy, provider: l2Provider }], log);
  }

  // Hop 1: relay L1→GW (the wrapped forwarding transaction from the GW's L1 diamond proxy)
  const gwTxHashes = await relayPriorityRequestsToTargets(
    receipt,
    [{ diamondProxy: l1DiamondProxy, provider: gwProvider! }],
    log
  );

  // Hop 2: relay to the final L2 chain.
  //
  // On L1, the nested chain's diamond proxy emits NewPriorityRequest with the
  // *actual* L2 transaction data, and then forwards a wrapped copy to the GW's
  // L1 diamond proxy. The GW receipt only contains NewRelayedPriorityTransaction
  // (no full tx data), so we cannot extract the hop-2 payload from it.
  //
  // Instead we extract the NewPriorityRequest events emitted by the nested
  // chain's L1 diamond proxy directly from the original L1 receipt, and relay
  // those to the L2 chain after hop 1 has been confirmed.
  const l2TxHashes = await relayPriorityRequestsToTargets(
    receipt,
    [{ diamondProxy: nestedL1DiamondProxy!, provider: l2Provider }],
    log
  );

  return [...gwTxHashes, ...l2TxHashes];
}

/**
 * Convenience wrapper: relay priority requests from a receipt to a single L2 chain.
 * Shorthand for `extractAndRelayNewPriorityRequests(receipt, [{ diamondProxy, provider }])`.
 */
export async function relayPriorityRequestsToChain(
  receipt: ethers.providers.TransactionReceipt,
  diamondProxy: string,
  l2Provider: providers.JsonRpcProvider,
  logger?: (line: string) => void
): Promise<string[]> {
  return extractAndRelayNewPriorityRequests(receipt, [{ diamondProxy, provider: l2Provider }], logger);
}

/**
 * Build a mock InteropProof struct for test bundle execution.
 * In the test environment, proof verification is bypassed, so we only need the correct shape.
 */
export function buildMockInteropProof(sourceChainId: number) {
  return {
    chainId: sourceChainId,
    l1BatchNumber: 0,
    l2MessageIndex: 0,
    message: {
      txNumberInBatch: 0,
      sender: INTEROP_CENTER_ADDR,
      data: "0x",
    },
    proof: [],
  };
}

/**
 * Extract InteropBundleSent events from a receipt and execute each bundle on the
 * destination chain via L2InteropHandler.executeBundle().
 *
 * Used for real interop flows only. L1-originated deposits should stay on the
 * NewPriorityRequest relay path even when they pass through the gateway chain.
 *
 * @returns Array of relay tx hashes on the destination chain
 */
export async function extractAndRelayInteropBundles(
  receipt: ethers.providers.TransactionReceipt,
  sourceChainId: number,
  destProvider: providers.JsonRpcProvider,
  logger?: (line: string) => void
): Promise<string[]> {
  const log = logger || console.log;
  const interopCenterIface = new ethers.utils.Interface(getAbi("InteropCenter"));
  const abiCoder = ethers.utils.defaultAbiCoder;

  // Extract all InteropBundleSent events
  const bundles: unknown[] = [];
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenterIface.parseLog({
        topics: logEntry.topics as string[],
        data: logEntry.data,
      });
      if (parsed && parsed.name === "InteropBundleSent") {
        bundles.push(parsed.args["interopBundle"]);
      }
    } catch {
      // Ignore non-InteropCenter logs
    }
  }

  if (bundles.length === 0) {
    log("   No InteropBundleSent events found in receipt");
    return [];
  }

  log(`   Found ${bundles.length} InteropBundleSent event(s)`);

  const txHashes: string[] = [];
  const mockProof = buildMockInteropProof(sourceChainId);

  for (const bundle of bundles) {
    const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [bundle]);

    // executeBundle can be called by any EOA — use the default Anvil account
    const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, destProvider);
    const interopHandler = new ethers.Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);
    let result: { txHash: string; success: boolean };
    try {
      const tx = await interopHandler.executeBundle(bundleData, mockProof, { gasLimit: 5_000_000 });
      const r = await tx.wait();
      result = { txHash: r.transactionHash, success: r.status === 1 };
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      log(`   executeBundle failed: ${msg.slice(0, 200)}`);
      result = { txHash: "", success: false };
    }

    if (result.success) {
      txHashes.push(result.txHash);
      log(`   Interop bundle relayed: cast run ${result.txHash} -r ${destProvider.connection.url}`);
    } else {
      throw new Error("Interop bundle execution failed on destination chain");
    }
  }

  return txHashes;
}

/**
 * Scan L1 blocks for NewPriorityRequest events on a diamond proxy and relay them to the GW chain.
 *
 * @returns Array of relay transaction hashes (successful relays only)
 */
export async function scanAndRelayPriorityRequests(
  l1Provider: providers.JsonRpcProvider,
  gwDiamondProxy: string,
  gwProvider: providers.JsonRpcProvider,
  fromBlock: number,
  toBlock: number | "latest",
  logger?: (line: string) => void
): Promise<string[]> {
  const log = logger || console.log;
  const newPriorityRequestTopic = ethers.utils.id(NEW_PRIORITY_REQUEST_EVENT_SIG);

  const logs = await l1Provider.getLogs({
    address: gwDiamondProxy,
    topics: [newPriorityRequestTopic],
    fromBlock,
    toBlock,
  });

  if (logs.length === 0) {
    log(`   No NewPriorityRequest events found in blocks [${fromBlock}, ${toBlock}]`);
    return [];
  }

  log(`   Found ${logs.length} NewPriorityRequest event(s) in blocks [${fromBlock}, ${toBlock}]`);

  const mailboxIface = new ethers.utils.Interface(getAbi("MailboxFacet"));

  const txHashes: string[] = [];
  for (const logEntry of logs) {
    const parsed = mailboxIface.parseLog({ topics: logEntry.topics, data: logEntry.data });
    const toUint256 = ethers.BigNumber.from(parsed.args.transaction.to);
    const fromUint256 = ethers.BigNumber.from(parsed.args.transaction.from);
    const from = ethers.utils.getAddress(ethers.utils.hexZeroPad(fromUint256.toHexString(), 20));
    const to = ethers.utils.getAddress(ethers.utils.hexZeroPad(toUint256.toHexString(), 20));
    const calldata = parsed.args.transaction.data;

    log(`   Relaying priority request from ${from} to ${to}`);
    const result = await relayTx(gwProvider, from, to, calldata);
    if (result.success) {
      txHashes.push(result.txHash);
      log(`   Relay tx: cast run ${result.txHash} -r ${gwProvider.connection.url}`);
    } else {
      log("   Relay tx failed (non-fatal)");
    }
  }

  return txHashes;
}

/**
 * Extract the InteropBundle struct from a transaction receipt.
 * Parses the InteropBundleSent event emitted by InteropCenter.
 *
 * @returns The interopBundle argument from the first InteropBundleSent event found.
 */
export async function extractInteropBundle(rpcUrl: string, txHash: string): Promise<InteropBundle> {
  const provider = new providers.JsonRpcProvider(rpcUrl);
  const receipt = await provider.getTransactionReceipt(txHash);
  const iface = new ethers.utils.Interface(getAbi("InteropCenter"));

  for (const logEntry of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed.name === "InteropBundleSent") {
        return parsed.args["interopBundle"] as InteropBundle;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  throw new Error(`InteropBundleSent event not found in tx ${txHash}`);
}
