// Part 1: an atomic cross-chain call from chain A to a receiver on chain B.
import { randomBytes } from "node:crypto";
import { encodeAbiParameters, parseAbi, toHex } from "viem";
import {
  alice,
  attr,
  buildFlow,
  bundleStatus,
  chainA,
  chainB,
  commitValue,
  deploy,
  erc7930,
  ethereumTime,
  executeAtomicBundle,
  executeAtomicBundleError,
  executor,
  insertionHint,
  interopFee,
  legCommittedProof,
  legState,
  previewMessageHash,
  publicClient,
  sendMessage,
  waitForInteropRoot,
} from "./common";

const receiverAbi = parseAbi([
  "function lastMessage() view returns (string)",
  "function lastSourceChainId() view returns (uint256)",
  "function lastSender() view returns (address)",
]);

export async function main() {
  const b = publicClient(chainB);

  // 0. Deploy the receiver on chain B.
  const receiver = await deploy(chainB, alice, "MessageReceiver");
  console.log("receiver on chain B:", receiver);

  // 1. Describe the call: a message to the receiver on chain B.
  const recipient = erc7930(BigInt(chainB.id), receiver);
  const payload = encodeAbiParameters([{ type: "string" }], ["hello from chain A"]);
  const salt = toHex(randomBytes(32));

  // 2. Preview the bundle hash. Nothing is sent yet.
  const bundleHash = await previewMessageHash(chainA, alice.address, [recipient, payload, [attr.salt(salt)]]);
  console.log("previewed bundle hash:", bundleHash);

  // 3. Build the flow: one leg, sent from chain A, with a deadline in Ethereum time.
  const deadline = (await ethereumTime()) + 3600n;
  const { flowId, preimage } = buildFlow([{ bundleHash, sourceChainId: BigInt(chainA.id) }], deadline);
  console.log(`flow id: ${flowId} deadline: ${deadline} (in 1 hour)`);

  // 4. Send the leg: the same inputs as the preview, plus the atomicBundle attribute with an insertion
  //    hint from chain A's server. A message is one call, so it pays one interop fee.
  const value = commitValue(flowId, bundleHash);
  const hint = await insertionHint(chainA, value);
  const attributes = [attr.salt(salt), attr.atomicBundle(preimage, hint)];
  const sent = await sendMessage(chainA, alice, [recipient, payload, attributes], await interopFee(chainA));
  if (sent.bundleHash !== bundleHash) throw new Error("sent bundle hash differs from the preview");
  console.log(`sent on chain A in block ${sent.block} - leg state: ${await legState(chainA, flowId, bundleHash)}`);

  // 5. Get the finality proof from chain A once the batch with the send is executed on Ethereum,
  //    then wait until chain B has imported the interop root that the proof points to.
  const { proof, settlementBlock } = await legCommittedProof(chainA, value, sent.block);
  console.log(`chain A batch ${proof.batchNumber} executed on Ethereum in block ${settlementBlock}`);
  await waitForInteropRoot(chainB, settlementBlock);
  console.log(`chain B imported the interop root of Ethereum block ${settlementBlock}`);

  // 6. Execute on chain B. Anyone can submit; here a separate executor account does it.
  const finality = { flow: { flowId, preimage }, proofs: [proof] };
  console.log("executed on chain B in tx", await executeAtomicBundle(chainB, executor, sent.bundle, finality));

  // 7. Check the result on chain B.
  const message = await b.readContract({ address: receiver, abi: receiverAbi, functionName: "lastMessage" });
  const fromChain = await b.readContract({ address: receiver, abi: receiverAbi, functionName: "lastSourceChainId" });
  const fromAccount = await b.readContract({ address: receiver, abi: receiverAbi, functionName: "lastSender" });
  console.log("bundle status on chain B:", await bundleStatus(chainB, bundleHash));
  console.log(`receiver got "${message}" from ${fromAccount} on chain ${fromChain}`);

  // 8. A bundle runs once. Simulating a second execution shows the revert.
  const error = await executeAtomicBundleError(chainB, executor, sent.bundle, finality);
  console.log("second execution reverts with:", error);
}

// Run on its own with `npm run <part>`; scripts/demo.ts runs all three parts.
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
