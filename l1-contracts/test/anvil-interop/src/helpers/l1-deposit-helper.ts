import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import type { CoreDeployedAddresses } from "../core/types";
import { extractAndRelayNewPriorityRequests } from "../core/utils";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY } from "../core/const";

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

/**
 * Deposit ETH from L1 to an L2 chain via Bridgehub.requestL2TransactionDirect.
 *
 * For ETH-base-token chains, the base token deposit goes through the direct path
 * (TwoBridges rejects base token deposits with AssetIdNotSupported).
 * The settlement route is resolved from L1 Bridgehub:
 * direct-settled chains relay L1 -> L2, gateway-settled chains relay L1 -> GW -> L2
 * through nested NewPriorityRequest events.
 */
export async function depositETHToL2(params: DepositETHParams): Promise<DepositETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);

  const l2GasLimit = 1_000_000;
  const l2GasPerPubdataByteLimit = 800;
  const gasPrice = 50_000_000_000n; // 50 gwei

  const baseCost = await bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
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

  const tx = await bridgehub.requestL2TransactionDirect(request, {
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
