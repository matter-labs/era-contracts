import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import { impersonateAndRun } from "./utils";
import { encodeNtvAssetId, encodeBridgeBurnData } from "./data-encoding";
import {
  l1NativeTokenVaultAbi,
  l2NativeTokenVaultAbi,
  testnetERC20TokenAbi,
  l2AssetRouterAbi,
  l1NullifierAbi,
  il1BridgehubAbi,
} from "./contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETH_TOKEN_ADDRESS,
  L1_CHAIN_ID,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_BASE_TOKEN_ADDR,
  FINALIZE_DEPOSIT_SIG,
} from "./const";
import type { CoreDeployedAddresses } from "./types";

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
 * Initiate an ETH withdrawal from L2 to L1.
 *
 * On ZKsync VM, L2AssetRouter.withdraw() can receive ETH value even though it's
 * not marked payable (ZKsync VM allows value on all calls). On Anvil (plain EVM),
 * the non-payable check rejects value, so we bypass L2AssetRouter and call
 * L2NTV.bridgeBurn directly by impersonating the L2AssetRouter. This executes
 * the real NTV withdrawal logic (balance tracking, burn, event emission).
 *
 * Then finalize on L1 via the real L1Nullifier (DummyL1MessageRoot bypasses proof checks).
 */
export async function withdrawETHFromL2(params: WithdrawETHParams): Promise<WithdrawETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // L2 uses asset ID computed with L2NTV address (matching L2 genesis init)
  const l2EthAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

  // L1 uses asset ID from the deployed L1NTV contract
  const ntv = new Contract(l1Addresses.l1NativeTokenVault, l1NativeTokenVaultAbi(), l1Provider);
  const l1EthAssetId = await ntv.assetId(ETH_TOKEN_ADDRESS);

  // On L2, ETH base token is registered at L2_BASE_TOKEN_ADDR (0x800a), not
  // ETH_TOKEN_ADDRESS (0x0001). The withdrawal data must use 0x800a so that
  // the L2NTV's _decodeBurnAndCheckAssetId finds the registered asset.
  const withdrawalData = encodeBridgeBurnData(amount, l1Recipient, L2_BASE_TOKEN_ADDR);

  // On Anvil, L2AssetRouter.withdraw(bytes32,bytes) is NOT payable (Solidity
  // enforces callvalue check). But the NTV's _getTokenAndBridgeToChain requires
  // msg.value == amount for the base token. We bypass L2AssetRouter by calling
  // L2NTV.bridgeBurn directly (which IS payable) via impersonation of the
  // L2AssetRouter address (required by onlyAssetRouter modifier).
  const l2Ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi(), l2Provider);

  console.log(`   Initiating ETH withdrawal from chain ${chainId} (via NTV bridgeBurn)...`);

  // Impersonate L2AssetRouter so we pass the onlyAssetRouter modifier
  const l2TxHash = await impersonateAndRun(l2Provider, L2_ASSET_ROUTER_ADDR, async (routerSigner) => {
    const l2NtvAsRouter = l2Ntv.connect(routerSigner);

    // bridgeBurn(chainId, l2MsgValue=0, assetId, originalCaller, data) with value=amount
    // The NTV checks require(_depositAmount == msg.value) for the base token
    const l2Tx = await l2NtvAsRouter.bridgeBurn(
      L1_CHAIN_ID, // destination: L1
      0, // l2MsgValue: must be 0 (requireZeroValue modifier)
      l2EthAssetId,
      l2Wallet.address, // originalCaller
      withdrawalData,
      { value: amount, gasLimit: 5_000_000 }
    );
    await l2Tx.wait();
    console.log(`   L2 bridgeBurn tx: cast run ${l2Tx.hash} -r ${l2RpcUrl}`);
    return l2Tx.hash;
  });

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
    l2TxHash: l2TxHash,
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

  // Call L2AssetRouter.withdraw on L2
  const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, l2AssetRouterAbi(), l2Wallet);

  console.log(`   Initiating ERC20 withdrawal from chain ${chainId}...`);
  // Use explicit function signature for ethers v5 (L2AssetRouter has overloaded withdraw)
  const l2Tx = await l2AssetRouter["withdraw(bytes32,bytes)"](assetId, withdrawalData, {
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
  const bridgehub = new Contract(l1Addresses.bridgehub, il1BridgehubAbi(), l1Provider);
  const slChainId = await bridgehub.settlementLayer(chainId);
  const slChainIdNum = slChainId.toNumber();
  const isGatewaySettled = slChainIdNum !== 0 && slChainIdNum !== L1_CHAIN_ID;
  const settlementLayerChainId = isGatewaySettled ? slChainIdNum : 0;

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

  // 3. Build the merkle proof
  //    DummyL1MessageRoot bypasses proof verification, but getProofData() still
  //    parses the proof to extract settlementLayerChainId for transient storage.
  let merkleProof: string[];

  if (settlementLayerChainId > 0) {
    // New format proof: metadata + logLeafSibling + batchLeafProofMask + packedBatchInfo + slChainId
    // Metadata: version=0x01, logLeafProofLen=1, batchLeafProofLen=0, finalProofNode=0
    merkleProof = [
      "0x0101000000000000000000000000000000000000000000000000000000000000",
      ethers.constants.HashZero, // log leaf merkle sibling (dummy)
      ethers.constants.HashZero, // batchLeafProofMask = 0
      ethers.constants.HashZero, // packed(settlementLayerBatchNumber=0, batchRootMask=0)
      ethers.utils.hexZeroPad(ethers.utils.hexlify(settlementLayerChainId), 32),
    ];
  } else {
    // Old format proof: single non-zero element → finalProofNode=true → settlementLayerChainId=0
    merkleProof = ["0x0000000100000001000000010000000100000001000000010000000100000001"];
  }

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
