import { ethers, providers, utils } from "ethers";
import { parse as parseToml } from "toml";
import * as fs from "fs";
import * as path from "path";
import { ANVIL_FUND_BALANCE, L1_MESSAGE_SENT_EVENT_SIG, L1_TO_L2_ALIAS_OFFSET, L2_ASSET_TRACKER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, NEW_PRIORITY_REQUEST_EVENT_SIG } from "./const";
import type { FinalizeWithdrawalParams, PriorityRequestData } from "./types";

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

export function saveTomlConfig(filePath: string, data: Record<string, unknown>): void {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const lines: string[] = [];

  function writeSection(obj: Record<string, unknown>, prefix = ""): void {
    for (const [key, value] of Object.entries(obj)) {
      const fullKey = prefix ? `${prefix}.${key}` : key;

      if (value && typeof value === "object" && !Array.isArray(value)) {
        lines.push(`\n[${fullKey}]`);
        writeSection(value as Record<string, unknown>, fullKey);
      } else if (typeof value === "string") {
        lines.push(`${key} = "${value}"`);
      } else if (typeof value === "boolean") {
        lines.push(`${key} = ${value}`);
      } else if (typeof value === "number") {
        lines.push(`${key} = ${value}`);
      } else if (Array.isArray(value)) {
        lines.push(`${key} = [${value.map((v) => (typeof v === "string" ? `"${v}"` : v)).join(", ")}]`);
      }
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

export function encodeNtvAssetId(chainId: number, tokenAddress: string): string {
  const abiCoder = new utils.AbiCoder();
  return utils.keccak256(
    abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress])
  );
}

/**
 * Get chain IDs of chains settled on the gateway (not L1, not GW itself, not direct-settled chain 10).
 */
export function getGwSettledChainIds(
  chains: Array<{ chainId: number; isL1?: boolean; isGateway?: boolean }>
): number[] {
  return chains
    .filter((c) => !c.isL1 && !c.isGateway && c.chainId !== 10)
    .map((c) => c.chainId);
}

export function formatChainInfo(chainId: number, port: number, isL1: boolean): string {
  const type = isL1 ? "L1" : "L2";
  return `${type} Chain ${chainId} on port ${port}`;
}

/**
 * Impersonate an account on Anvil, fund it, run the callback, then stop impersonating.
 */
export async function impersonateAndRun<T>(
  provider: providers.JsonRpcProvider,
  account: string,
  fn: (signer: providers.JsonRpcSigner) => Promise<T>,
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function loadAbiFromOut(artifactRelativePath: string): any[] {
  return loadArtifactFromOut(artifactRelativePath).abi;
}

export function loadBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.deployedBytecode?.object || artifact.bytecode?.object || "0x";
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function loadArtifactFromOut(artifactRelativePath: string): any {
  const outRoot = path.resolve(__dirname, "../../../out");
  const artifactPath = path.join(outRoot, artifactRelativePath);
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
}

/**
 * Apply L1-to-L2 address alias (AddressAliasHelper.applyL1ToL2Alias).
 */
export function applyL1ToL2Alias(l1Address: string): string {
  const result = ethers.BigNumber.from(l1Address).add(ethers.BigNumber.from(L1_TO_L2_ALIAS_OFFSET)).mod(ethers.BigNumber.from(2).pow(160));
  return ethers.utils.getAddress(ethers.utils.hexZeroPad(result.toHexString(), 20));
}

/**
 * Extract FinalizeWithdrawalParams from an L2 transaction receipt.
 *
 * Parses the L1MessageSent event from the MockL2ToL1Messenger and builds
 * the finalization params needed to call receiveL1ToGatewayMigrationOnL1 on L1.
 * Uses an empty merkle proof (relies on DummyL1MessageRoot returning true).
 */
export function buildFinalizeWithdrawalParams(
  l2Receipt: ethers.providers.TransactionReceipt,
  chainId: number
): FinalizeWithdrawalParams {
  // Parse L1MessageSent event from MockL2ToL1Messenger
  const l1MessageSentTopic = ethers.utils.id(L1_MESSAGE_SENT_EVENT_SIG);
  const l1MessageSentLog = l2Receipt.logs.find(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (logEntry: any) => logEntry.topics[0] === l1MessageSentTopic
  );

  if (!l1MessageSentLog) {
    throw new Error("L1MessageSent event not found in L2 tx receipt. Check MockL2ToL1Messenger emits the event.");
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
  diamondProxyAddr: string
): PriorityRequestData[] {
  const newPriorityRequestTopic = ethers.utils.id(NEW_PRIORITY_REQUEST_EVENT_SIG);

  const priorityRequestLogs = receipt.logs.filter(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (logEntry: any) =>
      logEntry.address.toLowerCase() === diamondProxyAddr.toLowerCase() &&
      logEntry.topics[0] === newPriorityRequestTopic
  );

  // Lazy import to avoid circular dependency at module init time
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { mailboxFacetAbi } = require("./contracts");
  const mailboxIface = new ethers.utils.Interface(mailboxFacetAbi());

  return priorityRequestLogs.map((logEntry) => {
    const parsed = mailboxIface.parseLog({ topics: logEntry.topics, data: logEntry.data });
    const toUint256 = ethers.BigNumber.from(parsed.args.transaction.to);
    const fromUint256 = ethers.BigNumber.from(parsed.args.transaction.from);
    return {
      from: ethers.utils.getAddress(ethers.utils.hexZeroPad(fromUint256.toHexString(), 20)),
      to: ethers.utils.getAddress(ethers.utils.hexZeroPad(toUint256.toHexString(), 20)),
      calldata: parsed.args.transaction.data,
    };
  });
}

/**
 * Relay a transaction on an Anvil chain by impersonating the given sender.
 * Returns { txHash, success } — does NOT throw on revert.
 */
export async function relayTx(
  provider: providers.JsonRpcProvider,
  from: string,
  to: string,
  calldata: string,
): Promise<{ txHash: string; success: boolean }> {
  try {
    return await impersonateAndRun(provider, from, async (signer) => {
      const tx = await signer.sendTransaction({
        to,
        data: calldata,
        gasLimit: 30_000_000,
      });
      const receipt = await tx.wait();
      return { txHash: receipt.transactionHash, success: receipt.status === 1 };
    });
  } catch (error) {
    // Transaction may have reverted — return failure instead of throwing
    const msg = error instanceof Error ? error.message : String(error);
    console.warn(`   relayTx reverted: ${msg.slice(0, 200)}`);
    return { txHash: "", success: false };
  }
}

/**
 * Extract NewPriorityRequest events from an L1 receipt and relay them to the target chains.
 *
 * For each chain entry, filters events from the corresponding diamond proxy, extracts the
 * sender, destination address, and calldata from the event data, and relays the transaction
 * by impersonating the original sender on the target chain.
 *
 * @returns Array of relay transaction hashes
 */
export async function extractAndRelayNewPriorityRequests(
  receipt: ethers.providers.TransactionReceipt,
  chains: Array<{ diamondProxy: string; provider: providers.JsonRpcProvider }>,
  logger?: (line: string) => void,
): Promise<string[]> {
  const log = logger || console.log;
  const txHashes: string[] = [];

  for (const chain of chains) {
    const requests = extractNewPriorityRequests(receipt, chain.diamondProxy);
    for (const req of requests) {
      log(`   Relaying priority request from ${req.from} to ${req.to} via proxy ${chain.diamondProxy}`);
      const result = await relayTx(chain.provider, req.from, req.to, req.calldata);
      if (result.success) {
        txHashes.push(result.txHash);
        log(`   Relay tx: ${result.txHash}`);
      } else {
        throw new Error(`Relay tx failed: from=${req.from} to=${req.to} via proxy ${chain.diamondProxy}`);
      }
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
  logger?: (line: string) => void,
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

  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { mailboxFacetAbi } = require("./contracts");
  const mailboxIface = new ethers.utils.Interface(mailboxFacetAbi());

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
      log(`   Relay tx: ${result.txHash}`);
    } else {
      log(`   Relay tx failed (non-fatal)`);
    }
  }

  return txHashes;
}
