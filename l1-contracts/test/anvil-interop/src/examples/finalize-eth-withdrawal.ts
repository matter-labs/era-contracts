import type { providers } from "ethers";
import { Contract, ethers, Wallet } from "ethers";

import { getAbi } from "../core/contracts";
import {
  BundleStatus,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_CENTER_ADDR,
  L1_MESSAGE_SENT_EVENT_SIG,
  L2_TO_L1_MESSENGER_ADDR,
} from "../core/const";

const DEFAULT_PROOF_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_PROOF_TYPE = "messageRoot";
const INTEROP_BUNDLE_IDENTIFIER = "0x01";

interface RawLog {
  address: string;
  topics: string[];
  data: string;
}

interface RawL2ToL1Log {
  sender: string;
  transactionIndex?: number | string;
}

interface RawL2Receipt {
  blockNumber: number | string;
  logs: RawLog[];
  l1BatchTxIndex?: number | string;
  l2ToL1Logs?: RawL2ToL1Log[];
}

interface L2ToL1LogProof {
  batchNumber: number | string;
  id: number | string;
  proof: string[];
}

interface WithdrawalMessage {
  bundle: string;
  bundleHash: string;
  l2ToL1LogIndex: number;
  l2TxNumberInBatch: number;
  messageData: string;
  sender: string;
}

function requiredEnvironmentVariable(_name: string): string {
  const value = process.env[_name]?.trim();
  if (!value) {
    throw new Error(`${_name} is required`);
  }
  return value;
}

function numericRpcValue(_value: number | string): number {
  return ethers.BigNumber.from(_value).toNumber();
}

function extractWithdrawalMessage(_receipt: RawL2Receipt): WithdrawalMessage {
  const messageTopic = ethers.utils.id(L1_MESSAGE_SENT_EVENT_SIG);
  const messageLogs = _receipt.logs.filter(
    (_log) =>
      _log.address.toLowerCase() === L2_TO_L1_MESSENGER_ADDR.toLowerCase() &&
      _log.topics[0].toLowerCase() === messageTopic.toLowerCase()
  );
  if (messageLogs.length !== 1) {
    throw new Error(`Expected one withdrawal message, found ${messageLogs.length}`);
  }

  const messageLog = messageLogs[0];
  const sender = ethers.utils.getAddress(ethers.utils.hexDataSlice(messageLog.topics[1], 12));
  if (sender.toLowerCase() !== INTEROP_CENTER_ADDR.toLowerCase()) {
    throw new Error(`Withdrawal message sender is ${sender}, expected ${INTEROP_CENTER_ADDR}`);
  }

  const messageData: string = ethers.utils.defaultAbiCoder.decode(["bytes"], messageLog.data)[0];
  if (ethers.utils.hexDataSlice(messageData, 0, 1) !== INTEROP_BUNDLE_IDENTIFIER) {
    throw new Error("The L2 message is not an interop bundle");
  }
  const bundle = ethers.utils.hexDataSlice(messageData, 1);

  const interopCenterInterface = new ethers.utils.Interface(getAbi("InteropCenter"));
  let bundleHash: string | undefined;
  for (const logEntry of _receipt.logs) {
    if (logEntry.address.toLowerCase() !== INTEROP_CENTER_ADDR.toLowerCase()) {
      continue;
    }
    try {
      const parsedLog = interopCenterInterface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsedLog.name === "InteropBundleSent") {
        bundleHash = parsedLog.args.interopBundleHash;
        break;
      }
    } catch {
      // Ignore other InteropCenter events.
    }
  }
  if (!bundleHash) {
    throw new Error("InteropBundleSent was not found in the withdrawal transaction");
  }

  const l2ToL1LogIndex = (_receipt.l2ToL1Logs ?? []).findIndex(
    (_log) => _log.sender.toLowerCase() === L2_TO_L1_MESSENGER_ADDR.toLowerCase()
  );
  if (l2ToL1LogIndex === -1) {
    throw new Error("The receipt does not contain the messenger L2-to-L1 log");
  }

  const l2TxNumber = _receipt.l2ToL1Logs?.[l2ToL1LogIndex]?.transactionIndex ?? _receipt.l1BatchTxIndex;
  if (l2TxNumber === undefined) {
    throw new Error("The receipt does not contain the L2 transaction number in batch");
  }

  return {
    bundle,
    bundleHash,
    l2ToL1LogIndex,
    l2TxNumberInBatch: numericRpcValue(l2TxNumber),
    messageData,
    sender,
  };
}

async function waitUntilFinalized(
  _provider: providers.JsonRpcProvider,
  _blockNumber: number,
  _timeoutMs: number
): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt <= _timeoutMs) {
    const finalizedBlock = await _provider.getBlock("finalized");
    if (finalizedBlock && finalizedBlock.number >= _blockNumber) {
      return;
    }
    await new Promise((_resolve) => setTimeout(_resolve, _provider.pollingInterval));
  }
  throw new Error(`Timed out waiting for L2 block ${_blockNumber} to finalize`);
}

async function waitForProof(
  _provider: providers.JsonRpcProvider,
  _txHash: string,
  _l2ToL1LogIndex: number,
  _proofType: string,
  _timeoutMs: number
): Promise<L2ToL1LogProof> {
  const startedAt = Date.now();
  let lastError: unknown;

  while (Date.now() - startedAt <= _timeoutMs) {
    try {
      const proof = (await _provider.send("zks_getL2ToL1LogProof", [
        _txHash,
        _l2ToL1LogIndex,
        _proofType,
      ])) as L2ToL1LogProof | null;
      if (proof) {
        return proof;
      }
    } catch (_error: unknown) {
      lastError = _error;
    }
    await new Promise((_resolve) => setTimeout(_resolve, _provider.pollingInterval));
  }

  const suffix = lastError instanceof Error ? `: ${lastError.message}` : "";
  throw new Error(`Timed out waiting for the L2-to-L1 proof${suffix}`);
}

async function main(): Promise<void> {
  const l1RpcUrl = requiredEnvironmentVariable("L1_RPC_URL");
  const l2RpcUrl = requiredEnvironmentVariable("L2_RPC_URL");
  const privateKey = requiredEnvironmentVariable("PRIVATE_KEY");
  const nullifierAddress = requiredEnvironmentVariable("L1_NULLIFIER_ADDRESS");
  const withdrawalTxHash = requiredEnvironmentVariable("L2_WITHDRAWAL_TX_HASH");
  const proofType = process.env.L2_TO_L1_PROOF_TYPE?.trim() || DEFAULT_PROOF_TYPE;
  const proofTimeoutMs = Number(process.env.PROOF_TIMEOUT_MS ?? DEFAULT_PROOF_TIMEOUT_MS);

  const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);
  const l2Provider = new ethers.providers.JsonRpcProvider(l2RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);

  const receipt = (await l2Provider.send("eth_getTransactionReceipt", [withdrawalTxHash])) as RawL2Receipt | null;
  if (!receipt) {
    throw new Error(`Withdrawal transaction ${withdrawalTxHash} is not mined`);
  }

  const sourceChainId = (await l2Provider.getNetwork()).chainId;
  const withdrawal = extractWithdrawalMessage(receipt);
  await waitUntilFinalized(l2Provider, numericRpcValue(receipt.blockNumber), proofTimeoutMs);
  const proof = await waitForProof(l2Provider, withdrawalTxHash, withdrawal.l2ToL1LogIndex, proofType, proofTimeoutMs);

  const nullifier = new Contract(nullifierAddress, getAbi("L1Nullifier"), l1Provider);
  const interopHandlerAddress: string = await nullifier.l1InteropHandler();
  const interopHandler = new Contract(interopHandlerAddress, getAbi("L1InteropHandler"), l1Wallet);
  const inclusionProof = {
    chainId: sourceChainId,
    l1BatchNumber: numericRpcValue(proof.batchNumber),
    l2MessageIndex: numericRpcValue(proof.id),
    message: {
      txNumberInBatch: withdrawal.l2TxNumberInBatch,
      sender: withdrawal.sender,
      data: withdrawal.messageData,
    },
    proof: proof.proof,
  };

  await interopHandler.callStatic.executeBundle(withdrawal.bundle, inclusionProof, {
    gasLimit: DEFAULT_TX_GAS_LIMIT,
  });
  const finalizationTx = await interopHandler.executeBundle(withdrawal.bundle, inclusionProof, {
    gasLimit: DEFAULT_TX_GAS_LIMIT,
  });
  const finalizationReceipt = await finalizationTx.wait();

  const status: number = await interopHandler.bundleStatus(withdrawal.bundleHash);
  if (Number(status) !== BundleStatus.FullyExecuted) {
    throw new Error(`Unexpected bundle status ${status.toString()}`);
  }

  console.log(`L1 finalization transaction: ${finalizationReceipt.transactionHash}`);
}

main().catch((_error: unknown) => {
  console.error(_error);
  process.exitCode = 1;
});
