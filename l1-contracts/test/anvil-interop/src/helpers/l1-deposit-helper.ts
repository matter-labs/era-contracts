import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import type { CoreDeployedAddresses } from "../core/types";
import { extractAndRelayNewPriorityRequests } from "../core/utils";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS, L1_CHAIN_ID } from "../core/const";
import { encodeAssetRouterBridgehubDepositData, encodeBridgeBurnData, encodeNtvAssetId } from "../core/data-encoding";

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

/**
 * Deposit an L1 ERC20 token to an L2 chain via Bridgehub.requestL2TransactionTwoBridges.
 *
 * This uses L1AssetRouter as the second bridge and relays the emitted priority requests
 * to the target chain (or L1 -> GW -> L2 for GW-settled chains).
 *
 * Only ETH-base-token chains are supported here, since mintValue is currently paid in ETH.
 */
export async function depositERC20ToL2(params: DepositERC20Params): Promise<DepositERC20Result> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, tokenAddress, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);
  const assetRouter = new Contract(l1Addresses.l1SharedBridge, getAbi("L1AssetRouter"), l1Wallet);
  const nativeTokenVault = new Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Wallet);
  const token = new Contract(tokenAddress, getAbi("TestnetERC20Token"), l1Wallet);

  const ethAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
  const chainBaseTokenAssetId: string = await bridgehub.baseTokenAssetId(chainId);
  if (chainBaseTokenAssetId !== ethAssetId) {
    throw new Error(
      `depositERC20ToL2 only supports ETH-base-token chains; chain ${chainId} uses ${chainBaseTokenAssetId}`
    );
  }

  let assetId: string = await nativeTokenVault.assetId(tokenAddress);
  if (assetId === ethers.constants.HashZero) {
    const registerTx = await nativeTokenVault.registerToken(tokenAddress, { gasLimit: 500_000 });
    await registerTx.wait();
    assetId = await nativeTokenVault.assetId(tokenAddress);
  }

  const currentAllowance = await token.allowance(l1Wallet.address, l1Addresses.l1SharedBridge);
  if (currentAllowance.lt(amount)) {
    const approveTx = await token.approve(l1Addresses.l1SharedBridge, amount);
    await approveTx.wait();
  }

  const l2GasLimit = 2_000_000;
  const l2GasPerPubdataByteLimit = 800;
  const gasPrice = 50_000_000_000n; // 50 gwei
  const mintValue = await bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);

  const secondBridgeCalldata = encodeAssetRouterBridgehubDepositData(
    assetId,
    encodeBridgeBurnData(amount, recipient, tokenAddress)
  );

  const tx = await bridgehub.requestL2TransactionTwoBridges(
    {
      chainId,
      mintValue,
      l2Value: 0,
      l2GasLimit,
      l2GasPerPubdataByteLimit,
      refundRecipient: recipient,
      secondBridgeAddress: assetRouter.address,
      secondBridgeValue: 0,
      secondBridgeCalldata,
    },
    {
      value: mintValue,
      gasLimit: 5_000_000,
    }
  );
  const l1Receipt = await tx.wait();

  console.log(`   Depositing ${ethers.utils.formatUnits(amount, 18)} ERC20 to chain ${chainId} via TwoBridges...`);
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
    mintValue,
    assetId,
  };
}
