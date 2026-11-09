// Part 2: a two-leg flow where one leg is never sent. After the deadline, the committed leg is refunded.
import { randomBytes } from "node:crypto";
import { encodeAbiParameters, formatEther, parseEther, toHex } from "viem";
import {
  alice,
  attr,
  authorizeRefund,
  bob,
  buildFlow,
  chainA,
  chainB,
  claimRefund,
  commitValue,
  deploy,
  erc7930,
  ethereumTime,
  executeAtomicBundleError,
  executor,
  insertionHint,
  interopFee,
  legCommittedProof,
  legMissingProof,
  legState,
  previewMessageHash,
  publicClient,
  sendMessage,
  sleep,
  waitForInteropRoot,
} from "./common";

export async function main() {
  const a = publicClient(chainA);

  // 0. Deploy a receiver on each chain.
  const receiverA = await deploy(chainA, alice, "MessageReceiver");
  const receiverB = await deploy(chainB, alice, "MessageReceiver");

  // 1. Plan two legs.
  //    Leg 1: Alice, chain A -> chain B, sends 1 ETH with a message.
  //    Leg 2: Bob, chain B -> chain A, sends a message back. Bob never sends it.
  const amount = parseEther("1");
  const leg1 = {
    recipient: erc7930(BigInt(chainB.id), receiverB),
    payload: encodeAbiParameters([{ type: "string" }], ["Alice pays 1 ETH"]),
    attributes: [attr.salt(toHex(randomBytes(32))), attr.callValue(amount)],
  };
  const leg2 = {
    recipient: erc7930(BigInt(chainA.id), receiverA),
    payload: encodeAbiParameters([{ type: "string" }], ["Bob confirms"]),
    attributes: [attr.salt(toHex(randomBytes(32)))],
  };

  // 2. Preview both bundle hashes, each on its own source chain and as its own sender.
  const leg1Hash = await previewMessageHash(chainA, alice.address, [leg1.recipient, leg1.payload, leg1.attributes]);
  const leg2Hash = await previewMessageHash(chainB, bob.address, [leg2.recipient, leg2.payload, leg2.attributes]);

  // 3. One flow for both legs, with a short deadline: 30 seconds of Ethereum time.
  const deadline = (await ethereumTime()) + 30n;
  const { flowId, preimage } = buildFlow(
    [
      { bundleHash: leg1Hash, sourceChainId: BigInt(chainA.id) },
      { bundleHash: leg2Hash, sourceChainId: BigInt(chainB.id) },
    ],
    deadline
  );
  console.log(`flow id: ${flowId} deadline: ${deadline} (in 30 seconds)`);
  console.log("leg 1 bundle hash:", leg1Hash);

  // 4. Alice sends leg 1, paying the 1 ETH call value plus one interop fee. The 1 ETH leaves her account.
  const balanceBefore = await a.getBalance({ address: alice.address });
  const hint = await insertionHint(chainA, commitValue(flowId, leg1Hash));
  const attributes = [...leg1.attributes, attr.atomicBundle(preimage, hint)];
  const msgValue = amount + (await interopFee(chainA));
  const leg1Sent = await sendMessage(chainA, alice, [leg1.recipient, leg1.payload, attributes], msgValue);
  const balanceAfterSend = await a.getBalance({ address: alice.address });
  console.log("leg 1 sent on chain A - leg state:", await legState(chainA, flowId, leg1Hash));
  console.log("Alice's balance on chain A:", formatEther(balanceBefore), "->", formatEther(balanceAfterSend), "ETH");

  // 5. Leg 1 can't be executed on chain B. Execution needs a proof for every leg, and leg 2 has none
  //    because Bob never sent it. With leg 1's proof alone, chain B reverts.
  const leg1Proof = await legCommittedProof(chainA, commitValue(flowId, leg1Hash), leg1Sent.block);
  await waitForInteropRoot(chainB, leg1Proof.settlementBlock);
  const finality = { flow: { flowId, preimage }, proofs: [leg1Proof.proof] };
  const error = await executeAtomicBundleError(chainB, executor, leg1Sent.bundle, finality);
  console.log("executing leg 1 on chain B reverts with:", error);

  // 6. Bob never sends leg 2. Wait until Ethereum time passes the deadline.
  while ((await ethereumTime()) <= deadline) await sleep(1000);
  console.log(`Ethereum time is now ${await ethereumTime()} - deadline passed`);

  // 7. Prove leg 2 is missing: it is not in chain B's commitment tree at the start of a batch that
  //    was executed on Ethereum after the deadline. Chain B's server returns the proof. Chain A must
  //    have imported the interop root the proof points to.
  const missing = await legMissingProof(chainB, commitValue(flowId, leg2Hash), deadline);
  console.log(
    `chain B batch ${missing.proof.batchNumber} executed on Ethereum in block ${missing.settlementBlock}, after the deadline`
  );
  await waitForInteropRoot(chainA, missing.settlementBlock);

  // 8. Authorize the refund on chain A. Anyone can submit it; here the executor account does.
  const leg2Index = BigInt(preimage.legBundleHashes.indexOf(leg2Hash));
  await authorizeRefund(chainA, executor, { flowId, preimage }, leg2Index, missing.proof);
  console.log("refund authorized - leg 1 state:", await legState(chainA, flowId, leg1Hash));

  // 9. Claim the refund for leg 1. The ETH goes back to Alice, whoever submits the claim.
  await claimRefund(chainA, executor, flowId, leg1Sent.bundle);
  const balanceAfterRefund = await a.getBalance({ address: alice.address });
  console.log("refund claimed - leg 1 state:", await legState(chainA, flowId, leg1Hash));
  console.log("Alice got back:", formatEther(balanceAfterRefund - balanceAfterSend), "ETH");
}

// Run on its own with `npm run <part>`; scripts/demo.ts runs all three parts.
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
