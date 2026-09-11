/**
 * Finalizes a `SampleWithdrawer` withdrawal on L1 against a real ZK chain (e.g. Sepolia + a testnet chain).
 *
 * Waits until the chain's server has published the message-inclusion proof for the withdrawal's L2 -> L1
 * message, then executes the interop bundle through the ecosystem's `L1InteropHandler`.
 *
 * Environment:
 *   L1_RPC_URL, L2_RPC_URL      RPC endpoints of L1 and the ZK chain
 *   PRIVATE_KEY                 L1 account paying for the finalization (anyone may finalize)
 *   BRIDGEHUB                   the ecosystem's L1 Bridgehub
 *   L2_WITHDRAWAL_TX_HASH       the L2 transaction that called `SampleWithdrawer.withdraw` (`WithdrawToL1.s.sol`)
 *   PROOF_TIMEOUT_MS            optional, how long to wait for the proof (default 60 min)
 *
 * Run from `l1-contracts/`:
 *   yarn ts-node examples/sample-depositor/scripts/finalize-withdrawal.ts
 */

import { Contract, ethers, Wallet } from "ethers";
import { BundleStatus, DEFAULT_TX_GAS_LIMIT } from "../../../test/anvil-interop/src/core/const";
import { getAbi } from "../../../test/anvil-interop/src/core/contracts";
import { createProvider } from "../../../test/anvil-interop/src/core/utils";
import { waitForLiveFinalizeWithdrawalParams } from "../../../test/anvil-interop/src/helpers/temp-sdk";

const DEFAULT_PROOF_TIMEOUT_MS = 60 * 60 * 1000;
/** Every L2 -> L1 interop bundle message starts with this byte (`BUNDLE_IDENTIFIER`). */
const BUNDLE_IDENTIFIER = "0x01";

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

async function main(): Promise<void> {
  const l1Provider = createProvider(requiredEnv("L1_RPC_URL"));
  const l2Provider = createProvider(requiredEnv("L2_RPC_URL"));
  const l1Wallet = new Wallet(requiredEnv("PRIVATE_KEY"), l1Provider);
  const bridgehubAddress = requiredEnv("BRIDGEHUB");
  const withdrawalTxHash = requiredEnv("L2_WITHDRAWAL_TX_HASH");
  const timeoutMs = Number(process.env.PROOF_TIMEOUT_MS ?? DEFAULT_PROOF_TIMEOUT_MS);

  const l2ChainId = (await l2Provider.getNetwork()).chainId;
  console.log(`Waiting for the inclusion proof of ${withdrawalTxHash} (chain ${l2ChainId})...`);
  const params = await waitForLiveFinalizeWithdrawalParams(l2Provider, withdrawalTxHash, l2ChainId, 0, timeoutMs);

  const message = ethers.utils.hexlify(params.message);
  if (ethers.utils.hexDataSlice(message, 0, 1) !== BUNDLE_IDENTIFIER) {
    throw new Error("The L2 -> L1 message is not an interop bundle");
  }
  const bundle = ethers.utils.hexDataSlice(message, 1);
  const proof = {
    chainId: l2ChainId,
    l1BatchNumber: params.l2BatchNumber,
    l2MessageIndex: params.l2MessageIndex,
    message: { txNumberInBatch: params.l2TxNumberInBatch, sender: params.l2Sender, data: message },
    proof: params.merkleProof,
  };

  // Bridgehub -> L1AssetRouter -> L1Nullifier -> L1InteropHandler: the bundle executor.
  const bridgehub = new Contract(bridgehubAddress, getAbi("IL1Bridgehub"), l1Provider);
  const assetRouter = new Contract(await bridgehub.assetRouter(), getAbi("L1AssetRouter"), l1Provider);
  const nullifier = new Contract(await assetRouter.L1_NULLIFIER(), getAbi("L1Nullifier"), l1Provider);
  const interopHandler = new Contract(await nullifier.l1InteropHandler(), getAbi("L1InteropHandler"), l1Wallet);

  const bundleHash = ethers.utils.keccak256(bundle);
  const statusBefore: number = await interopHandler.bundleStatus(bundleHash);
  if (statusBefore === BundleStatus.FullyExecuted) {
    console.log(`Bundle ${bundleHash} is already executed on L1`);
    return;
  }

  await interopHandler.callStatic.executeBundle(bundle, proof, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  const tx = await interopHandler.executeBundle(bundle, proof, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  console.log(`L1 finalization tx: ${tx.hash}`);
  await tx.wait();

  const status: number = await interopHandler.bundleStatus(bundleHash);
  if (status !== BundleStatus.FullyExecuted) {
    throw new Error(`Unexpected bundle status ${status} after finalization`);
  }
  console.log(`Bundle ${bundleHash} executed on L1`);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
