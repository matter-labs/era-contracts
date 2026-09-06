import { encodeDirectInteropRequest } from "../core/interop-requests";
import type { BigNumber } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import type { CoreDeployedAddresses } from "../core/types";
import { extractAndRelayNewPriorityRequests, createProvider } from "../core/utils";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
  ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  ERC20_DEPOSIT_L2_GAS_LIMIT,
} from "../core/const";
import { submitERC20Deposit } from "./l1-deposit-submission";

export interface DepositETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  recipient?: string;
  /** Required only for GW-settled chains. */
  gwRpcUrl?: string;
}

export interface DepositETHResult {
  l1TxHash: string;
  l2TxHash: string | null;
  amount: BigNumber;
  mintValue: BigNumber;
}

export interface DepositERC20Params {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  tokenAddress: string;
  amount: BigNumber;
  recipient?: string;
  /** Required only for GW-settled chains. */
  gwRpcUrl?: string;
}

export interface DepositERC20Result {
  l1TxHash: string;
  l2TxHash: string | null;
  amount: BigNumber;
  mintValue: BigNumber;
  assetId: string;
}

/**
 * Deposit ETH from L1 to an L2 chain via L1InteropCenter.sendMessage.
 *
 * For ETH-base-token chains, the base token deposit goes through the direct path
 * (indirectCall rejects base token deposits with AssetIdNotSupported).
 * The settlement route is resolved from L1 Bridgehub:
 * direct-settled chains relay L1 -> L2, gateway-settled chains relay L1 -> GW -> L2
 * through nested NewPriorityRequest events.
 */
export async function depositETHToL2(params: DepositETHParams): Promise<DepositETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = createProvider(l1RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);
  const interopCenter = new Contract(await bridgehub.interopCenter(), getAbi("L1InteropCenter"), l1Wallet);

  const l2GasLimit = ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT;
  const l2GasPerPubdataByteLimit = ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
  const gasPrice = ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI;

  const baseCost = await interopCenter.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
  const mintValue = baseCost.add(amount);

  const request = {
    chainId,
    mintValue,
    l2Contract: recipient,
    l2Value: amount,
    l2Calldata: "0x",
    l2GasLimit,
    l2GasPerPubdataByteLimit,
    factoryDeps: [],
    refundRecipient: recipient,
  };

  console.log(`   Depositing ${ethers.utils.formatEther(amount)} ETH to chain ${chainId} via Direct...`);
  console.log(`   baseCost: ${baseCost.toString()}, amount: ${amount.toString()}`);

  const message = encodeDirectInteropRequest(request);
  const tx = await interopCenter.sendMessage(message.recipient, message.payload, message.attributes, {
    value: mintValue,
    gasLimit: 5_000_000,
  });
  const l1Receipt = await tx.wait();

  console.log(`   L1 tx: cast run ${tx.hash} -r ${l1RpcUrl}`);

  const txHashes = await extractAndRelayNewPriorityRequests(
    l1Receipt,
    {
      l1RpcUrl,
      bridgehubAddr: l1Addresses.bridgehub,
      chainId,
      chainRpcUrl: l2RpcUrl,
      gwRpcUrl: params.gwRpcUrl,
    },
    (line) => console.log(line)
  );
  const l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
    mintValue: baseCost.add(amount),
  };
}

/** Submits an ERC20 deposit and relays its priority requests through the Anvil fixture. */
export async function depositERC20ToL2(params: DepositERC20Params): Promise<DepositERC20Result> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, tokenAddress, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = createProvider(l1RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const {
    receipt: l1Receipt,
    mintValue,
    assetId,
  } = await submitERC20Deposit(l1Wallet, {
    bridgehubAddress: l1Addresses.bridgehub,
    chainId,
    tokenAddress,
    amount,
    l2GasLimit: ERC20_DEPOSIT_L2_GAS_LIMIT,
    recipient: params.recipient,
    gasPrice: ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  });

  console.log(`   Depositing ${ethers.utils.formatUnits(amount, 18)} ERC20 to chain ${chainId} via indirectCall...`);
  console.log(`   L1 tx: cast run ${l1Receipt.transactionHash} -r ${l1RpcUrl}`);

  const txHashes = await extractAndRelayNewPriorityRequests(
    l1Receipt,
    {
      l1RpcUrl,
      bridgehubAddr: l1Addresses.bridgehub,
      chainId,
      chainRpcUrl: l2RpcUrl,
      gwRpcUrl: params.gwRpcUrl,
    },
    (line) => console.log(line)
  );
  const l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;

  return {
    l1TxHash: l1Receipt.transactionHash,
    l2TxHash,
    amount,
    mintValue,
    assetId,
  };
}
