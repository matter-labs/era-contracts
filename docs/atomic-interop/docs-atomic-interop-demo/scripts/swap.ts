// Part 3: an atomic token swap. Alice sends ALICE tokens from chain A to Bob on chain B, and Bob sends
// BOB tokens from chain B to Alice on chain A. Both legs belong to one flow.
import { randomBytes } from "node:crypto";
import { concat, encodeAbiParameters, erc20Abi, formatEther, parseEther, toHex } from "viem";
import type { Address, Hex } from "viem";
import {
  L2_ASSET_ROUTER,
  L2_NATIVE_TOKEN_VAULT,
  abis,
  alice,
  attr,
  bob,
  buildFlow,
  chainA,
  chainB,
  commitValue,
  deploy,
  erc7930Address,
  erc7930Chain,
  ethereumTime,
  executeAtomicBundle,
  executor,
  insertionHint,
  interopFee,
  legCommittedProof,
  previewBundleHash,
  publicClient,
  sendBundle,
  waitForInteropRoot,
  walletClient,
} from "./common";
import type { Account, Chain } from "./common";

/** Registers the token with the chain's token vault if needed, approves the vault, returns the asset ID. */
async function prepareToken(chain: Chain, owner: Account, token: Address, amount: bigint): Promise<Hex> {
  const client = publicClient(chain);
  const wallet = walletClient(chain, owner);
  const assetId = () =>
    client.readContract({
      address: L2_NATIVE_TOKEN_VAULT,
      abi: abis.tokenVault,
      functionName: "assetId",
      args: [token],
    });
  if (BigInt(await assetId()) === 0n) {
    const tx = await wallet.writeContract({
      address: L2_NATIVE_TOKEN_VAULT,
      abi: abis.tokenVault,
      functionName: "registerToken",
      args: [token],
    });
    await client.waitForTransactionReceipt({ hash: tx });
  }
  const approveTx = await wallet.writeContract({
    address: token,
    abi: erc20Abi,
    functionName: "approve",
    args: [L2_NATIVE_TOKEN_VAULT, amount],
  });
  await client.waitForTransactionReceipt({ hash: approveTx });
  return assetId();
}

/** One call to the asset router: send `amount` of `token` to `receiver` on the destination chain. */
function tokenTransferCall(assetId: Hex, token: Address, amount: bigint, receiver: Address) {
  const transferData = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "address" }],
    [amount, receiver, token]
  );
  return {
    to: erc7930Address(L2_ASSET_ROUTER),
    data: concat(["0x01", encodeAbiParameters([{ type: "bytes32" }, { type: "bytes" }], [assetId, transferData])]),
    callAttributes: [attr.indirectCall()],
  };
}

export async function main() {
  const a = publicClient(chainA);
  const b = publicClient(chainB);
  const aliceAmount = parseEther("10");
  const bobAmount = parseEther("7");

  // 0. Alice deploys her token on chain A, Bob his on chain B. Each mints 1000 to its deployer.
  const aliceToken = await deploy(chainA, alice, "DemoToken", ["Alice Coin", "ALICE", parseEther("1000")]);
  const bobToken = await deploy(chainB, bob, "DemoToken", ["Bob Coin", "BOB", parseEther("1000")]);

  // 1. Prepare both tokens and describe both legs.
  const aliceAsset = await prepareToken(chainA, alice, aliceToken, aliceAmount);
  const bobAsset = await prepareToken(chainB, bob, bobToken, bobAmount);
  //    Each leg names its receiver as the unbundler, so the sender can't cancel delivery later.
  const leg1 = {
    destination: erc7930Chain(BigInt(chainB.id)),
    calls: [tokenTransferCall(aliceAsset, aliceToken, aliceAmount, bob.address)],
    attributes: [attr.salt(toHex(randomBytes(32))), attr.unbundler(BigInt(chainB.id), bob.address)],
  };
  const leg2 = {
    destination: erc7930Chain(BigInt(chainA.id)),
    calls: [tokenTransferCall(bobAsset, bobToken, bobAmount, alice.address)],
    attributes: [attr.salt(toHex(randomBytes(32))), attr.unbundler(BigInt(chainA.id), alice.address)],
  };

  // 2. Preview both legs, each from its sender's address on its own chain. Each party can run both
  //    previews: a matching hash shows that the other leg pays what was agreed.
  const leg1Hash = await previewBundleHash(chainA, alice.address, [leg1.destination, leg1.calls, leg1.attributes]);
  const leg2Hash = await previewBundleHash(chainB, bob.address, [leg2.destination, leg2.calls, leg2.attributes]);

  // 3. Both build the same flow.
  const deadline = (await ethereumTime()) + 3600n;
  const { flowId, preimage } = buildFlow(
    [
      { bundleHash: leg1Hash, sourceChainId: BigInt(chainA.id) },
      { bundleHash: leg2Hash, sourceChainId: BigInt(chainB.id) },
    ],
    deadline
  );
  console.log(`flow id: ${flowId} deadline: ${deadline} (in 1 hour)`);

  // 4. Each party sends its leg: the same inputs as its preview, plus the atomicBundle attribute. The
  //    interop fee is per call.
  const sendLeg = async (chain: Chain, sender: Account, leg: typeof leg1, legHash: Hex) => {
    const hint = await insertionHint(chain, commitValue(flowId, legHash));
    const attributes = [...leg.attributes, attr.atomicBundle(preimage, hint)];
    const fee = (await interopFee(chain)) * BigInt(leg.calls.length);
    return sendBundle(chain, sender, [leg.destination, leg.calls, attributes], fee);
  };
  const sent1 = await sendLeg(chainA, alice, leg1, leg1Hash);
  const sent2 = await sendLeg(chainB, bob, leg2, leg2Hash);
  console.log("both legs sent");

  // 5. Get a finality proof for each leg from its source chain, in the order of
  //    preimage.legBundleHashes, and wait until both chains have imported the interop roots they use.
  const proofs = {
    [leg1Hash]: await legCommittedProof(chainA, commitValue(flowId, leg1Hash), sent1.block),
    [leg2Hash]: await legCommittedProof(chainB, commitValue(flowId, leg2Hash), sent2.block),
  };
  for (const { settlementBlock } of Object.values(proofs)) {
    await waitForInteropRoot(chainA, settlementBlock);
    await waitForInteropRoot(chainB, settlementBlock);
  }
  const finality = { flow: { flowId, preimage }, proofs: preimage.legBundleHashes.map((h) => proofs[h].proof) };
  console.log("both legs are finalized");

  // 6. Execute leg 1 on chain B and leg 2 on chain A, with the same proofs.
  await executeAtomicBundle(chainB, executor, sent1.bundle, finality);
  await executeAtomicBundle(chainA, executor, sent2.bundle, finality);
  console.log("both legs executed");

  // 7. Check the balances. Each party now holds a bridged copy of the other party's token.
  const bridged = (client: typeof a, assetId: Hex) =>
    client.readContract({
      address: L2_NATIVE_TOKEN_VAULT,
      abi: abis.tokenVault,
      functionName: "tokenAddress",
      args: [assetId],
    });
  const balance = (client: typeof a, token: Address, owner: Address) =>
    client.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [owner] });
  console.log(
    "Bob on chain B holds",
    formatEther(await balance(b, await bridged(b, aliceAsset), bob.address)),
    "bridged ALICE"
  );
  console.log(
    "Alice on chain A holds",
    formatEther(await balance(a, await bridged(a, bobAsset), alice.address)),
    "bridged BOB"
  );
}

// Run on its own with `npm run <part>`; scripts/demo.ts runs all three parts.
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
