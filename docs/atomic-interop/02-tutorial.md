---
description: Run an atomic cross-chain call, a refund after a missed deadline and a token swap on two local ZKsync chains.
---

# Atomic interop on two local chains

One command starts two ZKsync chains on a local Ethereum node and runs three atomic flows on them:

1. a cross-chain call from chain A to a receiver on chain B;
2. a two-leg flow whose second leg is never sent: the sent leg can't be executed, and after the
   deadline it is refunded;
3. a token swap between the two chains.

After the demo, the tutorial walks through each flow's code, and you can run each flow on its own. The demo
takes about 1.5 minutes; the walkthrough about 15.

## Before you start

You need Docker with Docker Compose. For the walkthrough, you also need Node.js, and optionally Foundry's
`cast`. Tested on macOS (Apple silicon) with:

| Tool             | Version                               |
| ---------------- | ------------------------------------- |
| Docker Desktop   | 4.97.0 (Engine 29.9.2, Compose 5.6.1) |
| Node.js          | 24.22.1                               |
| npm              | 11.19.1                               |
| Foundry's `cast` | 1.5.1                                 |

Check your versions:

```bash
docker compose version && node --version && npm --version && cast --version | head -1
```

The ZKsync server image is built for x86-64 (`linux/amd64`). On Apple silicon, Docker Desktop runs it
under emulation; the tutorial was tested that way.

The sandbox listens on ports 8545, 3050 and 3051 of `127.0.0.1`. Check that they are free:

```bash
lsof -nP -iTCP:8545 -iTCP:3050-3051 -sTCP:LISTEN || echo "ports are free"
```

## 1. Run the demo

The demo is in the era-contracts repository. Clone it without downloading the rest of the repository:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/matter-labs/era-contracts.git
```

```bash
cd era-contracts && git sparse-checkout set docs/atomic-interop/docs-atomic-interop-demo && cd docs/atomic-interop/docs-atomic-interop-demo
```

Start it and run the three flows:

```bash
docker compose run --rm demo
```

The initial run downloads about 430 MB of Docker images. Then the command starts the chains, waits until
they are registered with each other, installs the example's dependencies in a container and runs the
flows. After Docker's progress lines, the output is:

```text
Installing the example's dependencies...

== Part 1: an atomic cross-chain call from chain A (506) to chain B (507)

receiver on chain B: 0x8464135c8f25da09e49bc8782676a84730c318bc
previewed bundle hash: 0x49754d702b12f9a42352623f902f564ac2e751fcf1c87f0d2df4b4c6a9a13bdc
flow id: 0x0e65ef10414b41677fcd0da482b76fc2290a08872e0267e84f5b071ee5814d76 deadline: 1793974520 (in 1 hour)
sent on chain A in block 9 - leg state: Committed
chain A batch 8 executed on Ethereum in block 293
chain B imported the interop root of Ethereum block 293
executed on chain B in tx 0x43844bd9a0d582e627b7f846184762da6fb5c4dc40439ceaf715c252811af91c
bundle status on chain B: FullyExecuted
receiver got "hello from chain A" from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 on chain 506
second execution reverts with: BundleAlreadyProcessed

== Part 2: a missed deadline and a refund (waits about 30 seconds for the deadline)

flow id: 0x01d75e50d6f11ca09f3d5785117fc02df5709b803cab56eb02e5a685e1e38457 deadline: 1793970964 (in 30 seconds)
leg 1 bundle hash: 0xbaf477341afa88a046d408b12bb97f1b399f7f1a106617c48be27c3282b71cdb
leg 1 sent on chain A - leg state: Committed
Alice's balance on chain A: 99.9998958267233594 -> 98.999840605305466 ETH
executing leg 1 on chain B reverts with: ManagerProofCountMismatch
Ethereum time is now 1793970965 - deadline passed
chain B batch 23 executed on Ethereum in block 542, after the deadline
refund authorized - leg 1 state: Revertable
refund claimed - leg 1 state: Reverted
Alice got back: 1 ETH

== Part 3: an atomic token swap between chain A and chain B

flow id: 0x47fc2481e6ffdf3fcbc458c0bf4f3c897eb8863e75dec7217d36241f798f850c deadline: 1793974575 (in 1 hour)
both legs sent
both legs are finalized
both legs executed
Bob on chain B holds 10 bridged ALICE
Alice on chain A holds 7 bridged BOB

All three flows completed. The chains keep running: try `npm run call`, or stop them with `docker compose down`.
```

Addresses, hashes, block numbers and the deadlines differ on every run. In part 1, the leg is finalized once
chain A's batch is executed on Ethereum, and chain B executes it with a proof from chain A's server. In
part 2, chain B refuses the leg because Bob's leg has no proof, and after the deadline a proof that
Bob's leg is missing refunds Alice. In part 3, both legs are executed with the same two proofs.

The chains keep running after the demo, for the walkthrough.

## How the sandbox works

| Node          | Runs                     | Chain ID | RPC                     |
| ------------- | ------------------------ | -------- | ----------------------- |
| Ethereum (L1) | Anvil                    | 31337    | `http://127.0.0.1:8545` |
| Chain A       | ZKsync OS server v0.24.5 | 506      | `http://127.0.0.1:3050` |
| Chain B       | ZKsync OS server v0.24.5 | 507      | `http://127.0.0.1:3051` |

Both chains run protocol version v33 and settle directly on the local Ethereum node. Each chain closes
a batch within a second, and the batch is executed on Ethereum a few seconds later. The provers are
simulated, and the local Ethereum node accepts their test proofs. The rest is what a v33 network runs:
the contracts, settlement on Ethereum, the import of interop roots, and the server methods that return
proofs.

When the chains start, the sandbox registers them with each other. Registration needs a batch of each
chain executed on Ethereum, so it takes a few seconds. Every start begins from the same saved Ethereum
state, with new chains; the demo folder's `README.md` explains how that state was made.

## 2. Run the flows yourself

The demo folder:

| Path                                      | Content                                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `scripts/common.ts`                       | Chains, accounts, addresses and ABIs, helpers for hints and proofs, and one function per contract call |
| `scripts/call.ts`, `refund.ts`, `swap.ts` | The three flows; `scripts/demo.ts` runs them in a row                                                  |
| `contracts/`                              | The receiver and the demo token; the scripts compile them with `solc`                                  |
| `docker-compose.yaml`, `docker/`          | The sandbox                                                                                            |

The scripts use three of Anvil's default test accounts, which the sandbox gives 100 ETH each on both
chains. Never use their keys on a real network.

| Name     | Anvil account | Address                                      |
| -------- | ------------- | -------------------------------------------- |
| Alice    | #1            | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| Bob      | #2            | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| Executor | #3            | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |

Install the dependencies on your machine:

```bash
npm install
```

npm 11 may report that it skipped `esbuild`'s install script; `tsx` works without it.

### Part 1: A cross-chain call

`scripts/call.ts` deploys a receiver on chain B, then follows the order every atomic send uses: pick a
salt, preview the bundle hash, build the flow definition, then send with the `atomicBundle` attribute:

```ts
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
```

The insertion hint comes from chain A's server. Then the leg needs a finality proof: chain A's server
returns it once the batch with the send is executed on Ethereum. The proof points to an Ethereum block,
and chain B can check it once it has imported that block's interop root:

```ts
// 5. Get the finality proof from chain A once the batch with the send is executed on Ethereum,
//    then wait until chain B has imported the interop root that the proof points to.
const { proof, settlementBlock } = await legCommittedProof(chainA, value, sent.block);
console.log(`chain A batch ${proof.batchNumber} executed on Ethereum in block ${settlementBlock}`);
await waitForInteropRoot(chainB, settlementBlock);
console.log(`chain B imported the interop root of Ethereum block ${settlementBlock}`);

// 6. Execute on chain B. Anyone can submit; here a separate executor account does it.
const finality = { flow: { flowId, preimage }, proofs: [proof] };
console.log("executed on chain B in tx", await executeAtomicBundle(chainB, executor, sent.bundle, finality));
```

`insertionHint`, `legCommittedProof` and `legMissingProof` in `scripts/common.ts` call the chain server's
`zks_getImtLowNullifierIndex`, `zks_getImtInclusionProof` and `zks_getImtNonInclusionProof`, and add the
source chain ID that the on-chain proof needs. The functions named after a contract call, such as
`sendMessage` and `executeAtomicBundle`, send that one call and throw if it reverts.

Run part 1 on its own:

```bash
npm run call
```

It prints the same lines as part 1 of the demo, with new values. Check the receiver on chain B, with the
address from the line `receiver on chain B` of your output:

```bash
cast call <receiver> "lastMessage()(string)" --rpc-url http://127.0.0.1:3051
```

```text
"hello from chain A"
```

### Part 2: A missed deadline and a refund

`scripts/refund.ts` plans two legs with a deadline 30 seconds away. Alice sends 1 ETH from chain A to
chain B; Bob should send a message back from chain B but never does. After the deadline, any account can
prove Bob's leg is missing and refund Alice's:

```ts
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
```

The timeout proof comes from a batch of chain B executed on Ethereum after the deadline.
`legMissingProof` starts from chain B's latest batch and moves forward until it finds one. Then
`claimRefund` returns the 1 ETH to Alice, whoever submits it.

Run part 2 on its own. It waits about half a minute for the deadline:

```bash
npm run refund
```

Check the leg's state on chain A, with the flow ID and leg 1 bundle hash from your output:

```bash
cast call 0x0000000000000000000000000000000000010014 "legState(bytes32,bytes32)(uint8)" <flow id> <leg 1 bundle hash> --rpc-url http://127.0.0.1:3050
```

```text
3
```

`3` is `Reverted`: the refund was claimed and can't be claimed again.

### Part 3: A token swap

`scripts/swap.ts` swaps 10 ALICE tokens on chain A for 7 BOB tokens on chain B. Each token transfer is
a call to the asset router, and each leg names its receiver as the unbundler, so neither sender can
cancel delivery:

```ts
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
```

Each leg gets its finality proof from its own source chain. Both legs are executed with the same two
proofs, in the order of the flow's bundle hashes, once both chains have imported the interop roots they
point to:

```ts
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
```

Run part 3 on its own:

```bash
npm run swap
```

Edit the scripts and run them again: the chains keep their state until you stop the sandbox.

## 3. Clean up

Stop the sandbox and delete its containers:

```bash
docker compose down
```

The next start begins with new chains from the same saved state.

## Moving to a v33 network

- Use ZKsync OS chains on v33 that settle directly on Ethereum and are
  [registered](03-reference.md#registering-chains) with each other.
- In `scripts/common.ts`, set the chain IDs and RPC URLs of your chains (or the `L1_RPC_URL`,
  `CHAIN_A_RPC_URL` and `CHAIN_B_RPC_URL` variables), `L1_CHAIN_ID` to your Ethereum network's chain ID,
  and your keys instead of the test keys. Every flow definition uses `L1_CHAIN_ID`; with the wrong value,
  every send reverts.
- The helpers for hints, proofs and interop roots call the same server methods on any v33 chain. Raise
  their two-minute retry limit: on a real network, a batch takes longer to be executed on Ethereum.
- Choose a deadline that leaves time for every source chain to settle a batch on Ethereum. A leg can't
  be sent once its source chain has imported an interop root from after the deadline.
- `deploy` in `scripts/common.ts` compiles with `solc` for the tutorial. Deploy your contracts with your
  usual tools.
- In a swap, check the other party's leg before you send yours. See [Atomic swap](01-flows.md#atomic-swap).
