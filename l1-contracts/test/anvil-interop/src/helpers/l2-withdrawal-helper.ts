import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import { buildWithdrawalMerkleProof, getSettlementLayerChainId } from "../core/utils";
import { encodeBridgeBurnData } from "../core/data-encoding";
import {
  iBaseTokenAbi,
  l1NativeTokenVaultAbi,
  testnetERC20TokenAbi,
  il2AssetRouterAbi,
  l1NullifierAbi,
} from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETH_TOKEN_ADDRESS,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_BASE_TOKEN_ADDR,
  FINALIZE_DEPOSIT_SIG,
} from "../core/const";
import type { CoreDeployedAddresses } from "../core/types";

export interface WithdrawETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  l1Recipient?: string;
}

export interface WithdrawETHResult {
  l2TxHash: string;
  l1TxHash: string | null;
  amount: BigNumber;
}

export interface WithdrawERC20Params {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  l2TokenAddress: string;
  assetId: string;
  amount: BigNumber;
  l1Recipient?: string;
}

export interface WithdrawERC20Result {
  l2TxHash: string;
  l1TxHash: string | null;
  amount: BigNumber;
  assetId: string;
}

/**
 * Initiate an ETH withdrawal from L2 to L1 via L2BaseToken.withdraw().
 *
 * L2BaseToken.withdraw(address) is payable — it burns msg.value from the caller's
 * balance and sends an L2→L1 message with the finalizeEthWithdrawal selector.
 * On L1, L1Nullifier recognizes this message format and mints ETH to the recipient.
 *
 * Finalization on L1 uses the real L1Nullifier (DummyL1MessageRoot bypasses proof checks).
 */
export async function withdrawETHFromL2(params: WithdrawETHParams): Promise<WithdrawETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // L1 uses asset ID from the deployed L1NTV contract
  const ntv = new Contract(l1Addresses.l1NativeTokenVault, l1NativeTokenVaultAbi(), l1Provider);
  const l1EthAssetId = await ntv.assetId(ETH_TOKEN_ADDRESS);

  // Call L2BaseToken.withdraw(l1Recipient) with value = amount
  const l2BaseToken = new Contract(L2_BASE_TOKEN_ADDR, iBaseTokenAbi(), l2Wallet);

  console.log(`   Initiating ETH withdrawal from chain ${chainId} via L2BaseToken.withdraw()...`);
  const l2Tx = await l2BaseToken.withdraw(l1Recipient, { value: amount, gasLimit: 5_000_000 });
  await l2Tx.wait();
  console.log(`   L2 withdraw tx: cast run ${l2Tx.hash} -r ${l2RpcUrl}`);

  // Finalize on L1 using proof bypass (uses L1 asset ID + L1 token address)
  const l1TxHash = await finalizeWithdrawalOnL1(
    l1Provider,
    chainId,
    l1Addresses,
    l1EthAssetId,
    amount,
    l1Recipient,
    ETH_TOKEN_ADDRESS,
    l2Wallet.address
  );

  return {
    l2TxHash: l2Tx.hash,
    l1TxHash,
    amount,
  };
}

/**
 * Initiate an ERC20 withdrawal from L2 to L1 via L2AssetRouter.withdraw.
 */
export async function withdrawERC20FromL2(params: WithdrawERC20Params): Promise<WithdrawERC20Result> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, l2TokenAddress, assetId, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // Approve L2NativeTokenVault to spend tokens
  const l2Token = new Contract(l2TokenAddress, testnetERC20TokenAbi(), l2Wallet);

  console.log("   Approving L2NativeTokenVault for withdrawal...");
  const approveTx = await l2Token.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);
  await approveTx.wait();

  // Encode withdrawal data: (amount, l1Recipient, l2TokenAddress)
  const withdrawalData = encodeBridgeBurnData(amount, l1Recipient, l2TokenAddress);

  // Use IL2AssetRouter interface (no overloaded withdraw) for cleaner call syntax
  const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, il2AssetRouterAbi(), l2Wallet);

  console.log(`   Initiating ERC20 withdrawal from chain ${chainId}...`);
  const l2Tx = await l2AssetRouter.withdraw(assetId, withdrawalData, {
    gasLimit: 5_000_000,
  });
  await l2Tx.wait();
  console.log(`   L2 withdrawal tx: cast run ${l2Tx.hash} -r ${l2RpcUrl}`);

  // Finalize on L1
  const l1TxHash = await finalizeWithdrawalOnL1(
    l1Provider,
    chainId,
    l1Addresses,
    assetId,
    amount,
    l1Recipient,
    l2TokenAddress,
    l2Wallet.address
  );

  return {
    l2TxHash: l2Tx.hash,
    l1TxHash,
    amount,
    assetId,
  };
}

// Counter to ensure unique (chainId, l2BatchNumber, l2MessageIndex) for each finalization.
// Start from a high value derived from process start time to avoid collisions when
// tests run multiple times against the same chains (--keep-chains).
let finalizationCounter = Math.floor(Date.now() / 1000);

/**
 * Finalize a withdrawal on L1 via the real L1Nullifier.
 *
 * Constructs the withdrawal message and a merkle proof that encodes the settlement
 * layer chain ID. The DummyL1MessageRoot bypasses proof verification (always returns
 * true), but the proof structure must be valid for getProofData() to extract the
 * settlement layer information (used by L1AssetTracker to update the correct chainBalance).
 *
 * For direct settlement (chain on L1): old format proof → settlementLayerChainId = 0
 * For gateway settlement: new format proof → settlementLayerChainId = GW chain ID
 */
async function finalizeWithdrawalOnL1(
  l1Provider: providers.JsonRpcProvider,
  chainId: number,
  l1Addresses: CoreDeployedAddresses,
  assetId: string,
  amount: BigNumber,
  recipient: string,
  tokenAddress: string,
  originalCaller: string
): Promise<string | null> {
  // 1. Query settlement layer from Bridgehub
  const settlementLayerChainId = await getSettlementLayerChainId(l1Provider, l1Addresses.bridgehub, chainId);

  // 2. Build the L2→L1 withdrawal message
  const isBaseToken = tokenAddress === ETH_TOKEN_ADDRESS;
  let message: string;
  let l2Sender: string;

  if (isBaseToken) {
    // Base token format: IMailboxLegacy.finalizeEthWithdrawal selector + packed(address, uint256)
    // The selector is from the full interface function (5 params), but the message body is just (address, uint256)
    const selector = ethers.utils.id("finalizeEthWithdrawal(uint256,uint256,uint16,bytes,bytes32[])").slice(0, 10);
    message = ethers.utils.solidityPack(["bytes4", "address", "uint256"], [selector, recipient, amount]);
    l2Sender = L2_BASE_TOKEN_ADDR; // 0x800a
  } else {
    // Asset router format: finalizeDeposit selector + packed(uint256, bytes32, bytes)
    const abiCoder = ethers.utils.defaultAbiCoder;
    const transferData = abiCoder.encode(
      ["address", "address", "address", "uint256", "bytes"],
      [originalCaller, recipient, tokenAddress, amount, "0x"]
    );
    const selector = ethers.utils.id(FINALIZE_DEPOSIT_SIG).slice(0, 10);
    message = ethers.utils.solidityPack(
      ["bytes4", "uint256", "bytes32", "bytes"],
      [selector, chainId, assetId, transferData]
    );
    l2Sender = L2_ASSET_ROUTER_ADDR;
  }

  // 3. Build the merkle proof (DummyL1MessageRoot bypasses verification,
  //    but getProofData() still parses it for settlementLayerChainId)
  const merkleProof = buildWithdrawalMerkleProof(settlementLayerChainId);

  // 4. Build FinalizeL1DepositParams and call L1Nullifier.finalizeDeposit
  const l2BatchNumber = ++finalizationCounter;
  const l1Wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  const l1Nullifier = new Contract(l1Addresses.l1NullifierProxy, l1NullifierAbi(), l1Wallet);

  console.log(
    `   Finalizing withdrawal on L1 via L1Nullifier (settlement layer: ${settlementLayerChainId || "direct"})...`
  );

  try {
    const tx = await l1Nullifier.finalizeDeposit([chainId, l2BatchNumber, 0, l2Sender, 0, message, merkleProof], {
      gasLimit: 5_000_000,
    });
    const receipt = await tx.wait();
    console.log(`   L1 finalize tx: cast run ${receipt.transactionHash} -r ${l1Provider.connection.url}`);
    return receipt.transactionHash;
  } catch (error: unknown) {
    console.error(`   Failed to finalize withdrawal on L1: ${(error as Error).message}`);
    return null;
  }
}
