import { BigNumber, Contract, providers, Wallet, ethers } from "ethers";
import type { CoreDeployedAddresses } from "./types";
import { encodeNtvAssetId, impersonateAndRun } from "./utils";
import { l1BridgehubAbi, l2AssetRouterAbi, testnetERC20TokenAbi, l1NativeTokenVaultAbi } from "./contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS, L1_CHAIN_ID, L2_ASSET_ROUTER_ADDR } from "./const";

export interface DepositETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  recipient?: string;
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
 * On a real chain, the L2 side would be executed by the sequencer. On Anvil, we
 * directly execute the L2 side by calling the L2AssetRouter.finalizeDeposit via
 * anvil_impersonateAccount (as the aliased L1AssetRouter address).
 */
export async function depositETHToL2(params: DepositETHParams): Promise<DepositETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  // Load ABIs
  const bridgehubAbi = l1BridgehubAbi();
  const bridgehub = new Contract(l1Addresses.bridgehub, bridgehubAbi, l1Wallet);

  // ETH deposit uses requestL2TransactionDirect
  const l2GasLimit = 1_000_000;
  const l2GasPerPubdataByteLimit = 800;
  const gasPrice = 50_000_000_000n; // 50 gwei

  // Calculate baseCost so mintValue >= baseCost + l2Value
  const baseCost = await bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
  const mintValue = baseCost.add(amount);

  const request = {
    chainId: chainId,
    mintValue: mintValue,
    l2Contract: recipient,
    l2Value: amount,
    l2Calldata: "0x",
    l2GasLimit: l2GasLimit,
    l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    factoryDeps: [],
    refundRecipient: recipient,
  };

  console.log(`   Depositing ${ethers.utils.formatEther(amount)} ETH to chain ${chainId}...`);
  console.log(`   baseCost: ${baseCost.toString()}, mintValue: ${mintValue.toString()}`);

  const tx = await bridgehub.requestL2TransactionDirect(request, {
    value: mintValue,
    gasLimit: 5_000_000,
  });
  await tx.wait();

  console.log(`   L1 tx: cast run ${tx.hash} -r ${l1RpcUrl}`);

  // L2 finalization uses the L2 asset ID (computed with L2NTV address, matching L2 genesis init)
  const l2EthAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

  // Finalize on L2 side: the L1→L2 relayer normally does this, but we can do it directly.
  // The L2AssetRouter.finalizeDeposit must be called by the aliased L1AssetRouter.
  // With Anvil auto-impersonate, we can call from any address.
  const l2TxHash = await finalizeETHDepositOnL2(l2Provider, chainId, l2EthAssetId, amount, recipient);

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
    mintValue,
  };
}

/**
 * Finalize an ETH deposit on L2 by calling L2AssetRouter.finalizeDeposit.
 * Uses anvil_impersonateAccount to act as the aliased L1AssetRouter.
 */
async function finalizeETHDepositOnL2(
  l2Provider: providers.JsonRpcProvider,
  _chainId: number,
  ethAssetId: string,
  amount: BigNumber,
  recipient: string
): Promise<string | null> {

  // The L2AssetRouter.finalizeDeposit expects to be called by the aliased counterpart
  // or by itself. On Anvil with auto-impersonate, we can call from any address.
  // Encode the transfer data: (amount, recipient, ETH_TOKEN_ADDRESS)
  const abiCoder = ethers.utils.defaultAbiCoder;
  const transferData = abiCoder.encode(
    ["uint256", "address", "address"],
    [amount, recipient, ETH_TOKEN_ADDRESS]
  );

  // We need to call from the L2AssetRouter itself (self-call) or from the aliased L1 address.
  // Use the L2AssetRouter address as sender via impersonation.
  try {
    return await impersonateAndRun(l2Provider, L2_ASSET_ROUTER_ADDR, async (signer) => {
      const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi(), signer);

      // originChainId = L1_CHAIN_ID (protocol chain ID = 1)
      const tx = await l2AssetRouter.finalizeDeposit(L1_CHAIN_ID, ethAssetId, transferData, {
        gasLimit: 5_000_000,
      });
      await tx.wait();
      console.log(`   L2 finalizeDeposit tx: cast run ${tx.hash} -r ${l2Provider.connection.url}`);
      return tx.hash;
    });
  } catch (error: unknown) {
    console.error(`   Failed to finalize deposit on L2: ${(error as Error).message}`);
    return null;
  }
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

  // Encode secondBridgeCalldata: assetId + transfer data
  const abiCoder = ethers.utils.defaultAbiCoder;
  const secondBridgeCalldata = abiCoder.encode(
    ["bytes32", "bytes"],
    [assetId, abiCoder.encode(["uint256", "address", "address"], [amount, recipient, l1TokenAddress])]
  );

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
  const l2AssetRouterAbiData = l2AssetRouterAbi();
  const abiCoder = ethers.utils.defaultAbiCoder;

  const transferData = abiCoder.encode(
    ["uint256", "address", "address"],
    [amount, recipient, l1TokenAddress]
  );

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
