import { BigNumber, Contract, providers, Wallet, ethers } from "ethers";
import type { CoreDeployedAddresses } from "./types";
import { impersonateAndRun, extractAndRelayNewPriorityRequests } from "./utils";
import { encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "./data-encoding";
import { l1BridgehubAbi, l2AssetRouterAbi, testnetERC20TokenAbi, l1NativeTokenVaultAbi } from "./contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L1_CHAIN_ID, L2_ASSET_ROUTER_ADDR } from "./const";

export interface DepositETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  recipient?: string;
  /** L1 diamond proxy that emits NewPriorityRequest (chain's own for direct, GW's for GW-settled) */
  l1DiamondProxy: string;
  /** For GW-settled chains: relay deposit through the GW chain */
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
  l1TokenAddress: string;
  amount: BigNumber;
  recipient?: string;
}

export interface DepositERC20Result {
  l1TxHash: string;
  l2TxHash: string | null;
  amount: BigNumber;
  assetId: string;
}

/**
 * Deposit ETH from L1 to an L2 chain via Bridgehub.requestL2TransactionDirect.
 *
 * For ETH-base-token chains, the base token deposit goes through the direct path
 * (TwoBridges rejects base token deposits with AssetIdNotSupported).
 * The Bridgehub emits a NewPriorityRequest that we relay to the target chain.
 */
export async function depositETHToL2(params: DepositETHParams): Promise<DepositETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount, l1DiamondProxy } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, l1BridgehubAbi(), l1Wallet);

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

  let l2TxHash: string | null;

  if (params.gwRpcUrl) {
    // GW-settled: relay L1 → GW → L2
    const gwProvider = new providers.JsonRpcProvider(params.gwRpcUrl);
    const txHashes = await extractAndRelayNewPriorityRequests(
      l1Receipt,
      [{
        diamondProxy: l1DiamondProxy,
        provider: gwProvider,
        relayChains: [{ provider: l2Provider }],
      }],
    );
    l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;
  } else {
    // Direct chain: relay L1 → L2
    const txHashes = await extractAndRelayNewPriorityRequests(
      l1Receipt,
      [{
        diamondProxy: l1DiamondProxy,
        provider: l2Provider,
      }],
    );
    l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;
  }

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
    mintValue: baseCost.add(amount),
  };
}

/**
 * Deposit ERC20 from L1 to L2 via Bridgehub.requestL2TransactionTwoBridges.
 */
export async function depositERC20ToL2(params: DepositERC20Params): Promise<DepositERC20Result> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, l1TokenAddress, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  // First approve the L1 shared bridge to spend the tokens
  const token = new Contract(l1TokenAddress, testnetERC20TokenAbi(), l1Wallet);

  console.log(`   Approving L1AssetRouter to spend ${amount.toString()} tokens...`);
  const approveTx = await token.approve(l1Addresses.l1SharedBridge, amount);
  await approveTx.wait();

  // Register the token in L1NativeTokenVault if needed
  const ntv = new Contract(l1Addresses.l1NativeTokenVault, l1NativeTokenVaultAbi(), l1Wallet);
  const registeredAssetId = await ntv.assetId(l1TokenAddress);
  if (registeredAssetId === ethers.constants.HashZero) {
    console.log(`   Registering token ${l1TokenAddress} in L1NativeTokenVault...`);
    const registerTx = await ntv.registerToken(l1TokenAddress);
    await registerTx.wait();
  }

  // Query the correct asset ID from the NTV (deployment-specific)
  const assetId = await ntv.assetId(l1TokenAddress);

  // Build the two-bridges request
  const bridgehubAbi = l1BridgehubAbi();
  const bridgehub = new Contract(l1Addresses.bridgehub, bridgehubAbi, l1Wallet);

  const l2GasLimit = 1_000_000;
  const l2GasPerPubdataByteLimit = 800;

  const transferData = encodeBridgeBurnData(amount, recipient, l1TokenAddress);
  const secondBridgeCalldata = encodeAssetRouterBridgehubDepositData(assetId, transferData);

  // We need to send ETH for L2 gas
  const baseCost = await bridgehub.l2TransactionBaseCost(chainId, 50_000_000_000n, l2GasLimit, l2GasPerPubdataByteLimit);
  const mintValue = baseCost.add(ethers.utils.parseEther("0.01")); // some margin

  const request = {
    chainId: chainId,
    mintValue: mintValue,
    l2Value: 0,
    l2GasLimit: l2GasLimit,
    l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    refundRecipient: recipient,
    secondBridgeAddress: l1Addresses.l1SharedBridge,
    secondBridgeValue: 0,
    secondBridgeCalldata: secondBridgeCalldata,
  };

  console.log(`   Depositing ERC20 to chain ${chainId} via two bridges...`);

  const tx = await bridgehub.requestL2TransactionTwoBridges(request, {
    value: mintValue,
    gasLimit: 5_000_000,
  });
  await tx.wait();

  console.log(`   L1 tx: cast run ${tx.hash} -r ${l1RpcUrl}`);

  // Finalize on L2
  const l2TxHash = await finalizeERC20DepositOnL2(l2Provider, chainId, l1TokenAddress, assetId, amount, recipient);

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
    assetId,
  };
}

/**
 * Finalize an ERC20 deposit on L2 by calling L2AssetRouter.finalizeDeposit.
 */
async function finalizeERC20DepositOnL2(
  l2Provider: providers.JsonRpcProvider,
  _chainId: number,
  l1TokenAddress: string,
  assetId: string,
  amount: BigNumber,
  recipient: string
): Promise<string | null> {
  const transferData = encodeBridgeBurnData(amount, recipient, l1TokenAddress);

  try {
    return await impersonateAndRun(l2Provider, L2_ASSET_ROUTER_ADDR, async (signer) => {
      const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi(), signer);

      const tx = await l2AssetRouter.finalizeDeposit(L1_CHAIN_ID, assetId, transferData, {
        gasLimit: 5_000_000,
      });
      await tx.wait();
      console.log(`   L2 finalizeDeposit tx: cast run ${tx.hash} -r ${l2Provider.connection.url}`);
      return tx.hash;
    });
  } catch (error: unknown) {
    console.error(`   Failed to finalize ERC20 deposit on L2: ${(error as Error).message}`);
    return null;
  }
}
