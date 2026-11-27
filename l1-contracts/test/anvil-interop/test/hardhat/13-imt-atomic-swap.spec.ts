/**
 * End-to-end atomic-interop tests (bundle model) between two interop chains: A <-> B token swap
 * via atomic sends, destination acceptance + executeAtomicBundle, the late-batch and halted-destination
 * timeout/refund paths, the send-time flow/bundle coupling checks, and the timeout negatives. Every flow
 * is an accepted flow. Proofs are built off-chain by imt-engine-lib; on the harness the chain-batch-root
 * leaf authentication is mocked and settlement interop roots are added via bootloader impersonation. See
 * {protocol-docs/atomicity/flow.md} and {protocol-docs/atomicity/acceptance.md}.
 */

import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getInteropChainIds, getL2Chain, impersonateAndRun, createProvider } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { getInteropSourcePrivateKey } from "../../src/core/accounts";
import {
  ANVIL_RECIPIENT_ADDR,
  BundleStatus,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_BOOTLOADER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  ATOMIC_SEND_BUNDLE_GAS_LIMIT,
  DEFAULT_TX_GAS_LIMIT,
  LegState,
} from "../../src/core/const";
import { encodeEvmAddress, encodeEvmChain } from "../../src/core/data-encoding";
import {
  customError,
  expectRevert,
  expectEvent,
  captureBalance,
  expectNativeSpend,
  expectBalanceDelta,
} from "../../src/helpers/balance-helpers";
import {
  atomicBundleAttr,
  expectBundleEvent,
  interopBundleSaltAttr,
  getInteropProtocolFee,
  getTokenTransferData,
  indirectCallAttr,
  sendInteropBundle,
  staticPreviewHash,
} from "../../src/helpers/interop-helpers";
import type { AtomicFlowPreimage } from "../../src/helpers/interop-helpers";
import type { AtomicFlowLeg } from "../../src/helpers/imt-engine-lib";
import {
  DEFAULT_SL_CHAIN_ID,
  atomicFinalityProofTuple,
  atomicFlowTuple,
  buildFlowPreimage,
  buildInclusionProof,
  buildNonInclusionProof,
  computeFlowId,
  findValueIndex,
  flowPreimageTuple,
  lowNullifierIndexFor,
  participatingChains,
  participationValue,
  proofTuple,
  reconstructChainImt,
} from "../../src/helpers/imt-engine-lib";

const TEST_TOKEN_DECIMALS = 18;

/**
 * Handles to the atomic-interop built-ins on one L2 chain. They are predeployed and genesis-seeded
 * (see `src/core/predeploys.ts` and the relayed v31 genesis upgrade), so no install/seed step is
 * needed — the stack just binds contract objects to their canonical addresses.
 */
type AtomicStack = {
  chainId: number;
  provider: ethers.providers.JsonRpcProvider;
  /** {L2InteropCommitmentTree} at the canonical 0x10012. */
  tree: Contract;
  /** {AtomicFlowManager} at the canonical 0x10014. */
  manager: Contract;
  /** {InteropCenter} at the canonical 0x1000d (the atomic SEND entry point). */
  interopCenter: Contract;
  /** {L2InteropHandler} at the canonical 0x1000e (the atomic RECEIVE entry point). */
  interopHandler: Contract;
};

function atomicStack(chainId: number, provider: ethers.providers.JsonRpcProvider, wallet: Wallet): AtomicStack {
  return {
    chainId,
    provider,
    tree: new Contract(L2_INTEROP_COMMITMENT_TREE_ADDR, getAbi("L2InteropCommitmentTree"), wallet),
    manager: new Contract(L2_ATOMIC_FLOW_MANAGER_ADDR, getAbi("AtomicFlowManager"), wallet),
    interopCenter: new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet),
    interopHandler: new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet),
  };
}

type ChainCtx = {
  chainId: number;
  rpcUrl: string;
  provider: ethers.providers.JsonRpcProvider;
  user: Wallet;
  testToken: Contract;
  stack: AtomicStack;
};

/** Number of `eventName` logs the AtomicFlowManager emitted in `receipt`. */
function managerEventCount(receipt: ethers.providers.TransactionReceipt, eventName: string): number {
  const topic = new ethers.utils.Interface(getAbi("AtomicFlowManager")).getEventTopic(eventName);
  return receipt.logs.filter(
    (log) => log.address.toLowerCase() === L2_ATOMIC_FLOW_MANAGER_ADDR.toLowerCase() && log.topics[0] === topic
  ).length;
}

/** assetId = keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken)). */
function ntvAssetId(originChainId: number, originToken: string): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["uint256", "address", "address"],
      [originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken]
    )
  );
}

/** Register `token` with the chain's L2NativeTokenVault if it is not already (so the burn can resolve
 *  an assetId). Idempotent. */
async function ensureTokenRegistered(ctx: ChainCtx): Promise<void> {
  const vault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), ctx.user);
  const registered: string = await vault.assetId(ctx.testToken.address);
  if (registered === ethers.constants.HashZero) {
    await (await vault.registerToken(ctx.testToken.address)).wait();
    expect(await vault.assetId(ctx.testToken.address)).to.equal(ntvAssetId(ctx.chainId, ctx.testToken.address));
  }
}

/**
 * Approve the NTV for a generous allowance so BOTH the off-chain `callStatic.sendBundle` prediction
 * (which simulates the burn and therefore needs the allowance) and the real atomic send succeed. The
 * approval is a real tx (persists), so the later real send reuses it.
 */
async function ensureNtvApproval(ctx: ChainCtx, amount: BigNumber): Promise<void> {
  const current: BigNumber = await ctx.testToken.allowance(ctx.user.address, L2_NATIVE_TOKEN_VAULT_ADDR);
  if (current.lt(amount)) {
    await (await ctx.testToken.connect(ctx.user).approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount)).wait();
    expect((await ctx.testToken.allowance(ctx.user.address, L2_NATIVE_TOKEN_VAULT_ADDR)).toString()).to.equal(
      amount.toString()
    );
  }
}

/** The single indirect-call starter that bridges `amount` of the source token to `recipient` on dest. */
function bridgeCallStarter(source: ChainCtx, amount: BigNumber, recipient: string) {
  const assetId = ntvAssetId(source.chainId, source.testToken.address);
  return {
    to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
    data: getTokenTransferData(assetId, amount, recipient),
    callAttributes: [indirectCallAttr()],
  };
}

/** Current chain timestamp on a provider (used only for logging / human-readable deadlines). */
async function chainNow(provider: ethers.providers.JsonRpcProvider): Promise<number> {
  return (await provider.getBlock("latest")).timestamp;
}

/**
 * Ensures the settlement interop root for `settlementBlock` exists with the requested timestamp.
 * If an entry already exists with that timestamp, the helper leaves it unchanged. A different
 * timestamp is an error because settlement interop roots are write-once.
 */
async function ensureSettlementInteropRoot(
  provider: ethers.providers.JsonRpcProvider,
  settlementBlock: number,
  timestamp: number
): Promise<void> {
  const storage = new Contract(L2_INTEROP_ROOT_STORAGE_ADDR, getAbi("L2InteropRootStorage"), provider);
  const existing: { root: string; timestamp: BigNumber } = await storage.interopRoots(
    DEFAULT_SL_CHAIN_ID,
    settlementBlock
  );
  if (existing.root !== ethers.constants.HashZero) {
    const storedTs: BigNumber = existing.timestamp;
    if (!storedTs.eq(timestamp)) {
      throw new Error(
        `settlement interop root (${DEFAULT_SL_CHAIN_ID}, ${settlementBlock}) already has timestamp ${storedTs}, wanted ${timestamp}`
      );
    }
    return;
  }
  await impersonateAndRun(provider, L2_BOOTLOADER_ADDR, async (signer) => {
    await (
      await storage.connect(signer).addSingleInteropRoot({
        chainId: DEFAULT_SL_CHAIN_ID,
        blockOrBatchNumber: settlementBlock,
        timestamp,
        sides: [ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`settlement-interop-root-${settlementBlock}`))],
      })
    ).wait();
    expect((await storage.interopRoots(DEFAULT_SL_CHAIN_ID, settlementBlock)).timestamp.toNumber()).to.equal(timestamp);
  });
}

describe("13 - IMT atomic swap A <-> B (bundle model)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let chainA: ChainCtx;
  let chainB: ChainCtx;
  let fee: BigNumber;

  const aAmount = ethers.utils.parseUnits("10", TEST_TOKEN_DECIMALS);
  const bAmount = ethers.utils.parseUnits("7", TEST_TOKEN_DECIMALS);

  before(async () => {
    state = runner.loadState();
    if (!state.chains?.l1 || !state.chainAddresses || !state.l1Addresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const interopChainIds = getInteropChainIds(state.chains.config);
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop chains");
    }
    const [aId, bId] = interopChainIds;

    const ctxs = await Promise.all(
      [aId, bId].map(async (chainId) => {
        const rpcUrl = getL2Chain(state.chains!, chainId).rpcUrl;
        const provider = createProvider(rpcUrl);
        const user = new Wallet(getInteropSourcePrivateKey(), provider);
        const tokenAddress = state.testTokens![chainId];
        if (!tokenAddress) throw new Error(`No test token registered for chain ${chainId}`);
        const testToken = new Contract(tokenAddress, getAbi("TestnetERC20Token"), user);
        const stack = atomicStack(chainId, provider, user);
        return { chainId, rpcUrl, provider, user, testToken, stack };
      })
    );
    [chainA, chainB] = ctxs as ChainCtx[];

    // Register both test tokens with their NTVs so the source burn can resolve an assetId, and
    // pre-approve a generous NTV allowance so the off-chain bundleHash prediction (a callStatic that
    // simulates the burn) and the real sends both succeed.
    await ensureTokenRegistered(chainA);
    await ensureTokenRegistered(chainB);
    const generousAllowance = ethers.utils.parseUnits("1000000", TEST_TOKEN_DECIMALS);
    await ensureNtvApproval(chainA, generousAllowance);
    await ensureNtvApproval(chainB, generousAllowance);

    // Single dynamic per-call fee (one call per leg). Same on both chains in the harness.
    fee = await getInteropProtocolFee(chainA.provider);
  });

  /**
   * Predict a leg's bundleHash via the static `previewBundleHash` on its source chain, targeting `dest`.
   * (Kept local so the `dest` chain id is explicit rather than threaded through a placeholder.)
   */
  async function predictLegBundleHash(
    source: ChainCtx,
    dest: ChainCtx,
    amount: BigNumber,
    recipient: string,
    salt: string
  ): Promise<string> {
    const interopCenter = source.stack.interopCenter.connect(source.user);
    // `sendBundle` now requires the mandatory `atomicBundle` attribute (interop is atomic-only), which needs
    // the very flowId we are trying to derive — a circular dependency. `previewBundleHash` breaks it: it runs
    // the identical bundle assembly (including the simulated, discarded indirect-call burn) without the atomic
    // append, returning the exact bundleHash the real send will emit. The prediction MUST carry the same salt
    // the real send uses, since the bundleHash commits to the `interopBundleSalt` attribute.
    return staticPreviewHash(interopCenter, source.provider, source.user.address, "previewBundleHash", [
      encodeEvmChain(dest.chainId),
      [bridgeCallStarter(source, amount, recipient)],
      [interopBundleSaltAttr(salt)],
    ]);
  }

  /** A fresh, deterministic-per-send bundle salt. Random keeps it unique per (sender, salt) — the
   *  uniqueness InteropCenter enforces — while staying known off-chain so the bundleHash is predictable. */
  function freshBundleSalt(): string {
    return ethers.utils.hexlify(ethers.utils.randomBytes(32));
  }

  /**
   * Real atomic send of one leg: approve the source token, send the bundle with the `atomicBundle`
   * attribute (carrying the full flowId preimage), and assert the leg was committed under the
   * predicted bundleHash embedded in the preimage's leg hashes. Returns the receipt for the caller's
   * participation checks.
   */
  async function sendAtomicLeg(params: {
    source: ChainCtx;
    dest: ChainCtx;
    amount: BigNumber;
    recipient: string;
    flowPreimage: AtomicFlowPreimage;
    predictedBundleHash: string;
    salt: string;
  }): Promise<{ bundleData: string; bundleHash: string; receipt: ethers.providers.TransactionReceipt }> {
    const { source, dest, amount, recipient, flowPreimage, predictedBundleHash, salt } = params;

    await ensureNtvApproval(source, amount);

    // Derived, not sent: mirrors the on-chain recomputation from the attribute-supplied preimage.
    const flowId = computeFlowId(flowPreimage);
    const lowNull = await lowNullifierIndexFor(source.stack.tree, participationValue(flowId, source.chainId));

    const senderBefore = await captureBalance(source.provider, source.testToken.address);
    const sendResult = await sendInteropBundle({
      sourceProvider: source.provider,
      destinationChainId: dest.chainId,
      callStarters: [bridgeCallStarter(source, amount, recipient)],
      // Same salt used to predict `predictedBundleHash`, so the emitted bundleHash matches the
      // preimage's leg hash (the AtomicFlowManager rejects the send otherwise).
      bundleAttributes: [atomicBundleAttr(flowPreimage, lowNull), interopBundleSaltAttr(salt)],
      value: fee,
      // Atomic sends append to the IMT (~1.1M gas insert) on top of the burn, so they need the larger cap.
      gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT,
    });

    const senderAfter = await captureBalance(source.provider, source.testToken.address);
    expectNativeSpend(senderBefore, senderAfter, fee, sendResult.receipt, "atomic leg sender");
    expectBalanceDelta(senderBefore.token!, senderAfter.token!, amount.mul(-1), "atomic leg source token");

    // Cross-check the predicted bundleHash against the actual one the InteropCenter emitted.
    expect(sendResult.bundleHash.toLowerCase(), "predicted bundleHash matches emitted").to.equal(
      predictedBundleHash.toLowerCase()
    );
    const committed = expectEvent(
      sendResult.receipt,
      "AtomicFlowManager",
      L2_ATOMIC_FLOW_MANAGER_ADDR,
      "FlowLegCommitted"
    );
    expect(committed.flowId, "committed flow").to.equal(flowId);
    expect(committed.bundleHash, "committed leg").to.equal(sendResult.bundleHash);
    expect(await source.stack.manager.legState(flowId, sendResult.bundleHash)).to.equal(
      LegState.Committed,
      "leg committed on its source"
    );
    return { bundleData: sendResult.bundleData, bundleHash: sendResult.bundleHash, receipt: sendResult.receipt };
  }

  /**
   * Accept a sent leg on `dest` via `acceptAtomicBundle`, passing the low-nullifier hint for `dest`'s
   * participation value, and assert the acceptance. Returns the receipt for the caller's participation checks.
   */
  async function acceptLeg(
    dest: ChainCtx,
    leg: { bundleData: string; bundleHash: string },
    flowPreimage: AtomicFlowPreimage
  ): Promise<ethers.providers.TransactionReceipt> {
    const flowId = computeFlowId(flowPreimage);
    const lowNull = await lowNullifierIndexFor(dest.stack.tree, participationValue(flowId, dest.chainId));
    const receipt = await (
      await dest.stack.interopHandler.acceptAtomicBundle(leg.bundleData, flowPreimageTuple(flowPreimage), lowNull, {
        gasLimit: DEFAULT_TX_GAS_LIMIT,
      })
    ).wait();

    const accepted = expectEvent(receipt, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowAccepted");
    expect(accepted.flowId, "accepted flow").to.equal(flowId);
    expect(accepted.bundleHash, "accepted leg").to.equal(leg.bundleHash);
    expect(await dest.stack.manager.legState(flowId, leg.bundleHash)).to.equal(
      LegState.Accepted,
      "leg accepted on its destination"
    );
    expect(await dest.stack.interopHandler.bundleStatus(leg.bundleHash)).to.equal(
      BundleStatus.Unreceived,
      "acceptance leaves the bundle unreceived"
    );
    return receipt;
  }

  /** Asserts `receipt` inserted `chain`'s participation value for `flowId`, at the leaf its IMT now holds. */
  async function expectParticipated(
    receipt: ethers.providers.TransactionReceipt,
    chain: ChainCtx,
    flowId: string
  ): Promise<void> {
    const participated = expectEvent(receipt, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowParticipated");
    expect(participated.flowId, "participating flow").to.equal(flowId);
    const imt = await reconstructChainImt(chain.stack.tree);
    expect(imt.root.toLowerCase(), "off-chain IMT matches on-chain").to.equal(
      (await chain.stack.tree.root()).toLowerCase()
    );
    expect(participated.leafIndex.toNumber(), `participation leaf on chain ${chain.chainId}`).to.equal(
      findValueIndex(imt.leaves, participationValue(flowId, chain.chainId))
    );
  }

  it("happy path: atomic send -> accept -> executeBundle mints both legs and leaves source Committed", async () => {
    const user = chainA.user.address; // the interop source account, the depositor + recipient on both chains
    const now = Math.max(await chainNow(chainA.provider), await chainNow(chainB.provider));
    // The deadline is an SL timestamp; the harness sets each leg's batch `l1Timestamp == deadline`,
    // pinning the inclusive `l1Timestamp <= deadline` finality bound exactly at the boundary.
    const deadline = now + 3600;

    // ── Predict each leg's bundleHash (no state change), then derive flowId ──────────────────
    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aAmount, user, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bAmount, user, saltBA);

    const flowPreimage = buildFlowPreimage(
      [
        { hash: hAB, source: chainA.chainId, dest: chainB.chainId },
        { hash: hBA, source: chainB.chainId, dest: chainA.chainId },
      ],
      deadline
    );
    const flowId = computeFlowId(flowPreimage);

    // ── PHASE 1: atomic send on each source (burn + commit) ──────────────────────────────────
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const bBalanceBefore: BigNumber = await chainB.testToken.balanceOf(user);

    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aAmount,
      recipient: user,
      flowPreimage,
      predictedBundleHash: hAB,
      salt: saltAB,
    });
    const ba = await sendAtomicLeg({
      source: chainB,
      dest: chainA,
      amount: bAmount,
      recipient: user,
      flowPreimage,
      predictedBundleHash: hBA,
      salt: saltBA,
    });

    // Tokens left the depositor and were burned via AR/NTV. Each chain still has its incoming leg to accept,
    // so neither send inserts a participation value yet.
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(aBalanceBefore.sub(aAmount).toString());
    expect((await chainB.testToken.balanceOf(user)).toString()).to.equal(bBalanceBefore.sub(bAmount).toString());
    expect(managerEventCount(ab.receipt, "FlowParticipated"), "AB send participates").to.equal(0);
    expect(managerEventCount(ba.receipt, "FlowParticipated"), "BA send participates").to.equal(0);

    // ── PHASE 2: each destination accepts its incoming leg; that is each chain's last step, so it participates ─
    await expectParticipated(await acceptLeg(chainB, ab, flowPreimage), chainB, flowId);
    await expectParticipated(await acceptLeg(chainA, ba, flowPreimage), chainA, flowId);

    // ── PHASE 3: build the finality proof: one participation inclusion proof per participating chain ─
    // Even the executing chain's own participation needs an inclusion proof.
    const proofs = await Promise.all(
      participatingChains(flowPreimage).map((chainId) =>
        buildInclusionProof({
          l2Tree: [chainA, chainB].find((c) => c.chainId.toString() === chainId)!.stack.tree,
          chainId,
          value: participationValue(flowId, chainId),
          l1Timestamp: deadline,
        })
      )
    );
    const finality = atomicFinalityProofTuple({ flowId, preimage: flowPreimage, proofs });

    // ── PHASE 4: execute each destination leg via executeBundle ─────────────────────────
    // Snapshot the recipient shim balances BEFORE execute. The coverage harness runs every spec on
    // one shared chain set, so `user` may already hold these bridged shims from earlier specs — so we
    // assert the DELTA credited by this swap, not the absolute balance (the source-side checks above
    // are delta-based for the same reason).
    const abAssetId = ntvAssetId(chainA.chainId, chainA.testToken.address);
    const baAssetId = ntvAssetId(chainB.chainId, chainB.testToken.address);
    const ntvOnB = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), chainB.provider);
    const ntvOnA = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), chainA.provider);
    const shimAonBAddrBefore: string = await ntvOnB.tokenAddress(abAssetId);
    const shimAonBBefore: BigNumber =
      shimAonBAddrBefore === ethers.constants.AddressZero
        ? BigNumber.from(0)
        : await new Contract(shimAonBAddrBefore, getAbi("TestnetERC20Token"), chainB.provider).balanceOf(user);
    const shimBonAAddrBefore: string = await ntvOnA.tokenAddress(baAssetId);
    const shimBonABefore: BigNumber =
      shimBonAAddrBefore === ethers.constants.AddressZero
        ? BigNumber.from(0)
        : await new Contract(shimBonAAddrBefore, getAbi("TestnetERC20Token"), chainA.provider).balanceOf(user);

    const handlerB = chainB.stack.interopHandler.connect(chainB.user);
    const handlerA = chainA.stack.interopHandler.connect(chainA.user);
    const receiptB = await (
      await handlerB.executeAtomicBundle(ab.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })
    ).wait();
    const receiptA = await (
      await handlerA.executeAtomicBundle(ba.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })
    ).wait();
    expectBundleEvent(receiptB, "BundleExecuted", hAB);
    expectBundleEvent(receiptA, "BundleExecuted", hBA);

    // Destination bundles are FullyExecuted; legs remain Committed on their sources (terminal on the happy
    // path) and Accepted on their destinations.
    expect(await handlerB.bundleStatus(hAB)).to.equal(BundleStatus.FullyExecuted, "AB executed on B");
    expect(await handlerA.bundleStatus(hBA)).to.equal(BundleStatus.FullyExecuted, "BA executed on A");
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB stays Committed on A");
    expect(await chainB.stack.manager.legState(flowId, hBA)).to.equal(LegState.Committed, "BA stays Committed on B");
    expect(await chainB.stack.manager.legState(flowId, hAB)).to.equal(LegState.Accepted, "AB stays Accepted on B");
    expect(await chainA.stack.manager.legState(flowId, hBA)).to.equal(LegState.Accepted, "BA stays Accepted on A");

    // ── Destination mint assertions (delta — robust to pre-existing shim balance) ──────────────
    // B receives a bridged shim for A's token (assetId of A.testToken on chain A).
    const shimAonB = await ntvOnB.tokenAddress(abAssetId);
    expect(shimAonB).to.not.equal(ethers.constants.AddressZero, "shim for A's token deployed on B");
    const shimAonBAfter: BigNumber = await new Contract(
      shimAonB,
      getAbi("TestnetERC20Token"),
      chainB.provider
    ).balanceOf(user);
    expect(shimAonBAfter.sub(shimAonBBefore).toString()).to.equal(
      aAmount.toString(),
      "recipient on B received aAmount"
    );

    // A receives a bridged shim for B's token.
    const shimBonA = await ntvOnA.tokenAddress(baAssetId);
    expect(shimBonA).to.not.equal(ethers.constants.AddressZero, "shim for B's token deployed on A");
    const shimBonAAfter: BigNumber = await new Contract(
      shimBonA,
      getAbi("TestnetERC20Token"),
      chainA.provider
    ).balanceOf(user);
    expect(shimBonAAfter.sub(shimBonABefore).toString()).to.equal(
      bAmount.toString(),
      "recipient on A received bAmount"
    );
  });

  it("timeout path (late batch): one leg commits, peer never takes part -> authorizeRefund + claimRefund recovers depositor", async () => {
    const user = chainA.user.address;
    const deadline = 1_000;
    // The settlement interop root used by the absence proof must have been created after the deadline.
    // This fixed block is unique within the spec. The helper makes reruns against retained state idempotent.
    // NOTE: it is imported only AFTER the send below — `AtomicFlowManager.append` (and `accept`) reject a step
    // once a root created after the flow's deadline has been imported (the flow could already be timed out).
    const settlementInteropRootBlock = 201;

    const refundRecipient = ANVIL_RECIPIENT_ADDR;
    const aTimeoutAmount = ethers.utils.parseUnits("3", TEST_TOKEN_DECIMALS);
    const bTimeoutAmount = ethers.utils.parseUnits("5", TEST_TOKEN_DECIMALS);

    // ── Predict both legs' bundleHashes -> flowId (the BA leg is never sent). ─────────────────
    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aTimeoutAmount, refundRecipient, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bTimeoutAmount, refundRecipient, saltBA);

    const flowPreimage = buildFlowPreimage(
      [
        { hash: hAB, source: chainA.chainId, dest: chainB.chainId },
        { hash: hBA, source: chainB.chainId, dest: chainA.chainId },
      ],
      deadline
    );
    const flowId = computeFlowId(flowPreimage);

    // ── Commit only the AB leg on A. B neither commits BA nor accepts AB. ─────────────────────
    const recipientBefore: BigNumber = await chainA.testToken.balanceOf(refundRecipient);
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aTimeoutAmount,
      recipient: refundRecipient,
      flowPreimage,
      predictedBundleHash: hAB,
      salt: saltAB,
    });

    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB committed on A");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(
      aBalanceBefore.sub(aTimeoutAmount).toString(),
      "AB depositor burned tokens at commit"
    );

    // Now that the leg is committed, import the post-deadline settlement interop root the absence
    // proof anchors on (importing it earlier would make `append` reject the send: deadline passed).
    await ensureSettlementInteropRoot(chainA.provider, settlementInteropRootBlock, deadline + 5);

    // ── Absence proof for B's participation: batch-begin root of a late batch (`t > deadline`),
    //    checked against the post-deadline settlement interop root added above. ─────────────────
    const absence = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: participationValue(flowId, chainB.chainId),
      l1Timestamp: deadline + 1, // t > deadline: the first late batch's begin root
      provesAgainstBeginRoot: true,
      batchNumber: 1,
      slBlock: settlementInteropRootBlock,
    });
    // BA's source slot: B never sent its leg.
    const missingIdx = flowPreimage.legBundleHashes.indexOf(hBA);

    // ── authorizeRefund on A (A is AB's source) -> AB becomes Revertable. ────────────────────
    const managerA = chainA.stack.manager.connect(chainA.user);
    const refundAuth = await (
      await managerA.authorizeRefund(
        atomicFlowTuple({ flowId, preimage: flowPreimage }),
        missingIdx,
        proofTuple(absence),
        { gasLimit: DEFAULT_TX_GAS_LIMIT }
      )
    ).wait();
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Revertable, "AB revertable on A");
    expect(
      expectEvent(refundAuth, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowRefundAuthorized").bundleHash
    ).to.equal(hAB);

    // ── claimRefund on A -> depositor recovers the burned tokens; state Reverted. ────────────
    const claim = await (await managerA.claimRefund(flowId, ab.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    expectBalanceDelta(
      recipientBefore,
      await chainA.testToken.balanceOf(refundRecipient),
      ethers.constants.Zero,
      "refund must return to depositor, not destination recipient"
    );
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Reverted, "AB reverted on A");

    const aAfterRefund: BigNumber = await chainA.testToken.balanceOf(user);
    expect(aAfterRefund.toString()).to.equal(
      aBalanceBefore.toString(),
      "AB depositor fully recovered the burned tokens"
    );

    expect(expectEvent(claim, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowRefunded").bundleHash).to.equal(
      hAB
    );
  });

  /** A fabricated (never-sent) two-leg flow for proof-validation tests: authorizeRefund verifies the
   *  absence proof before touching any leg state, so no real sends are needed to exercise reverts. */
  function fabricatedFlow(deadline: number) {
    const flowPreimage = buildFlowPreimage(
      [
        { hash: ethers.utils.id("fabricated-leg-1"), source: chainA.chainId, dest: chainB.chainId },
        { hash: ethers.utils.id("fabricated-leg-2"), source: chainB.chainId, dest: chainA.chainId },
      ],
      deadline
    );
    const flowId = computeFlowId(flowPreimage);
    // The "missing" commitment is chain B's participation (proofs below are against B's IMT).
    const missingIdx = flowPreimage.legChainIds.indexOf(chainB.chainId);
    return { flowId, flowPreimage, missingIdx };
  }

  it("timeout path (halted destination): B commits but never accepts; end-root absence of its participation authorizes A's refund", async () => {
    const user = chainA.user.address;
    // Both legs are committed, so only B's missing acceptance keeps the flow from finalizing. B "halted"
    // before accepting AB: the absence proof uses the batch-END root of its last in-time batch
    // (`t <= deadline`, pinned exactly AT the boundary). See {protocol-docs/atomicity/acceptance.md#liveness}.
    // Deadline strictly above the late-batch test's imported root timestamp (1005): tests share chain
    // state, and `append` and `accept` reject a flow whose deadline predates an already-imported root. The
    // anchor root is imported after A's steps, as above.
    const deadline = 2_000;
    const settlementInteropRootBlock = 202;

    const refundRecipient = ANVIL_RECIPIENT_ADDR;
    const aTimeoutAmount = ethers.utils.parseUnits("2", TEST_TOKEN_DECIMALS);
    const bTimeoutAmount = ethers.utils.parseUnits("4", TEST_TOKEN_DECIMALS);

    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aTimeoutAmount, refundRecipient, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bTimeoutAmount, refundRecipient, saltBA);

    const flowPreimage = buildFlowPreimage(
      [
        { hash: hAB, source: chainA.chainId, dest: chainB.chainId },
        { hash: hBA, source: chainB.chainId, dest: chainA.chainId },
      ],
      deadline
    );
    const flowId = computeFlowId(flowPreimage);

    const recipientBefore: BigNumber = await chainA.testToken.balanceOf(refundRecipient);
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aTimeoutAmount,
      recipient: refundRecipient,
      flowPreimage,
      predictedBundleHash: hAB,
      salt: saltAB,
    });
    const ba = await sendAtomicLeg({
      source: chainB,
      dest: chainA,
      amount: bTimeoutAmount,
      recipient: refundRecipient,
      flowPreimage,
      predictedBundleHash: hBA,
      salt: saltBA,
    });

    // A completes its steps and participates; B halts without accepting AB, so it never does. (B's own BA
    // leg stays refundable on B by the same absence once B resumes; not exercised here.)
    await expectParticipated(await acceptLeg(chainA, ba, flowPreimage), chainA, flowId);
    expect(await chainB.stack.manager.legState(flowId, hAB)).to.equal(LegState.Unset, "AB never accepted on B");

    await ensureSettlementInteropRoot(chainA.provider, settlementInteropRootBlock, deadline + 5);

    // Halted-chain absence proof: `t <= deadline` selects the END-root branch (t == deadline pins
    // the boundary), and the empty batch-leaf path marks the batch as the chain's last inside the
    // settlement interop root.
    const absence = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: participationValue(flowId, chainB.chainId),
      l1Timestamp: deadline,
      provesAgainstBeginRoot: false,
      batchNumber: 1,
      slBlock: settlementInteropRootBlock,
    });
    // AB's leg: B, its destination, never accepted it.
    const missingIdx = flowPreimage.legBundleHashes.indexOf(hAB);

    const managerA = chainA.stack.manager.connect(chainA.user);
    const refundAuth = await (
      await managerA.authorizeRefund(
        atomicFlowTuple({ flowId, preimage: flowPreimage }),
        missingIdx,
        proofTuple(absence),
        { gasLimit: DEFAULT_TX_GAS_LIMIT }
      )
    ).wait();
    expect(
      expectEvent(refundAuth, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowRefundAuthorized").bundleHash
    ).to.equal(hAB);
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Revertable, "AB revertable on A");
    expect(await chainA.stack.manager.legState(flowId, hBA)).to.equal(LegState.Accepted, "BA stays Accepted on A");

    const claim = await (await managerA.claimRefund(flowId, ab.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    expect(expectEvent(claim, "AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR, "FlowRefunded").bundleHash).to.equal(
      hAB
    );
    expectBalanceDelta(
      recipientBefore,
      await chainA.testToken.balanceOf(refundRecipient),
      ethers.constants.Zero,
      "refund must return to depositor, not destination recipient"
    );
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Reverted, "AB reverted on A");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(
      aBalanceBefore.toString(),
      "AB depositor fully recovered the burned tokens"
    );
  });

  it("send-time coupling: an atomic send whose preimage does not contain the bundle is rejected", async () => {
    // Regression: committing a bundle under a flow whose preimage does not contain it would strand
    // the burned funds; the send must revert before any burn. See {protocol-docs/atomicity/flow.md#1-atomic-send-append}.
    const user = chainA.user.address;
    const deadline = (await chainNow(chainA.provider)) + 3600;
    const amount = ethers.utils.parseUnits("1", TEST_TOKEN_DECIMALS);
    const salt = freshBundleSalt();
    const realHash = await predictLegBundleHash(chainA, chainB, amount, user, salt);
    const strayLeg = ethers.utils.id("stale predicted bundle hash");
    const interopCenter = chainA.stack.interopCenter.connect(chainA.user);
    const [, , otherPeerChainId] = getInteropChainIds(state.chains!.config);
    if (otherPeerChainId === undefined) {
      throw new Error("Need a third interop chain for the source and destination mismatch checks");
    }

    const sendWithPreimage = (preimage: AtomicFlowPreimage) => () =>
      interopCenter.callStatic.sendBundle(
        encodeEvmChain(chainB.chainId),
        [bridgeCallStarter(chainA, amount, user)],
        [atomicBundleAttr(preimage, 0), interopBundleSaltAttr(salt)],
        { gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT, value: fee }
      );

    // Cases 2-4 each change one field of the control flow in case 5: the sent leg A -> B plus a stray leg B -> A.
    const sentLeg: AtomicFlowLeg = { hash: realHash, source: chainA.chainId, dest: chainB.chainId };
    const coLeg: AtomicFlowLeg = { hash: strayLeg, source: chainB.chainId, dest: chainA.chainId };

    // 1. Preimage whose legs do NOT include the bundle actually being sent.
    const strayPreimage = buildFlowPreimage(
      [{ hash: strayLeg, source: chainA.chainId, dest: chainB.chainId }],
      deadline
    );
    await expectRevert(
      sendWithPreimage(strayPreimage),
      "atomic send with preimage missing the bundle",
      customError("AtomicFlowManager", "ManagerBundleNotInFlow(bytes32,bytes32)", [
        computeFlowId(strayPreimage),
        realHash,
      ])
    );

    // 2. A third allowed peer lets the wrong source reach the source check without declaring a self-leg.
    const wrongSourcePreimage = buildFlowPreimage([{ ...sentLeg, source: otherPeerChainId }, coLeg], deadline);
    await expectRevert(
      sendWithPreimage(wrongSourcePreimage),
      "atomic send with wrong declared source chain",
      customError("AtomicFlowManager", "ManagerCommittedLegSourceChainMismatch(bytes32,uint256,uint256)", [
        computeFlowId(wrongSourcePreimage),
        chainA.chainId,
        otherPeerChainId,
      ])
    );

    // 3. Preimage that contains the bundle, but declares the wrong destination chain for it.
    const wrongDestPreimage = buildFlowPreimage([{ ...sentLeg, dest: otherPeerChainId }, coLeg], deadline);
    await expectRevert(
      sendWithPreimage(wrongDestPreimage),
      "atomic send with wrong declared destination chain",
      customError("AtomicFlowManager", "ManagerCommittedLegDestinationChainMismatch(bytes32,uint256,uint256)", [
        computeFlowId(wrongDestPreimage),
        chainB.chainId,
        otherPeerChainId,
      ])
    );

    // 4. Preimage whose co-leg declares a source chain this chain's receive filter rejects (its participation
    //    could never be proven here, present OR absent).
    const phantomChainId = 999_999;
    await expectRevert(
      sendWithPreimage(buildFlowPreimage([sentLeg, { ...coLeg, source: phantomChainId }], deadline)),
      "atomic send with a co-leg source chain the receive filter rejects",
      customError("AtomicFlowManager", "ManagerLegChainNotAllowed(uint256)", [phantomChainId])
    );

    // 5. The exact same bundle with a well-formed preimage still sends fine (control for 1-4: proves
    //    the reverts above came from the coupling and receive-filter checks, not from the send setup).
    const controlPreimage = buildFlowPreimage([sentLeg, coLeg], deadline);
    const controlFlowId = computeFlowId(controlPreimage);
    const lowNull = await lowNullifierIndexFor(chainA.stack.tree, participationValue(controlFlowId, chainA.chainId));
    const controlHash = await interopCenter.callStatic.sendBundle(
      encodeEvmChain(chainB.chainId),
      [bridgeCallStarter(chainA, amount, user)],
      [atomicBundleAttr(controlPreimage, lowNull), interopBundleSaltAttr(salt)],
      { gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT, value: fee }
    );
    expect(controlHash.toLowerCase()).to.equal(realHash.toLowerCase(), "well-formed preimage sends the same bundle");
  });

  it("timeout negatives: stale/missing settlement roots and non-last in-time batches are rejected", async () => {
    const deadline = 1_000;
    const { flowId, flowPreimage, missingIdx } = fabricatedFlow(deadline);
    const missingValue = participationValue(flowId, chainB.chainId);
    const flow = atomicFlowTuple({ flowId, preimage: flowPreimage });
    const managerA = chainA.stack.manager.connect(chainA.user);

    // 1. Settlement interop root NOT created strictly after the deadline (added exactly AT
    //    `T == deadline` to pin the strict bound): rejected even though the batch itself is in time
    //    and the absence itself would hold (a stale snapshot proves nothing about the deadline moment).
    const staleSettlementRootBlock = 203;
    await ensureSettlementInteropRoot(chainA.provider, staleSettlementRootBlock, deadline);
    const staleSettlementRootProof = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: missingValue,
      l1Timestamp: deadline - 1,
      provesAgainstBeginRoot: false,
      slBlock: staleSettlementRootBlock,
    });
    await expectRevert(
      () => managerA.callStatic.authorizeRefund(flow, missingIdx, proofTuple(staleSettlementRootProof)),
      "stale settlement interop root",
      customError("AtomicFlowManager", "ProofInteropRootNotAfterDeadline(uint256,uint64)", [deadline, deadline])
    );

    // 2. Settlement interop root is missing, so its unset timestamp reads as 0: rejected.
    const missingSettlementRootBlock = 999_999;
    const missingSettlementRootProof = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: missingValue,
      l1Timestamp: deadline + 1,
      provesAgainstBeginRoot: true,
      slBlock: missingSettlementRootBlock,
    });
    await expectRevert(
      () => managerA.callStatic.authorizeRefund(flow, missingIdx, proofTuple(missingSettlementRootProof)),
      "missing settlement interop root",
      customError("AtomicFlowManager", "ProofSettlementLayerInteropRootNotImported(uint256,uint256)", [
        DEFAULT_SL_CHAIN_ID,
        missingSettlementRootBlock,
      ])
    );

    // 3. In-time batch that is NOT the chain's last inside the settlement interop root: the batch-leaf
    //    path has a populated (non-empty-subtree) right sibling at level 0, so the last-batch check
    //    rejects it.
    const validSettlementRootBlock = 204;
    await ensureSettlementInteropRoot(chainA.provider, validSettlementRootBlock, deadline + 5);
    const populatedRightSibling = ethers.utils.id("populated-right-subtree");
    const notLastBatch = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: missingValue,
      l1Timestamp: deadline - 1,
      provesAgainstBeginRoot: false,
      slBlock: validSettlementRootBlock,
      batchLeafSiblings: [populatedRightSibling],
      batchLeafMask: 0, // left child at level 0 -> the sibling above must be the empty-subtree hash
    });
    await expectRevert(
      () => managerA.callStatic.authorizeRefund(flow, missingIdx, proofTuple(notLastBatch)),
      "in-time batch not last in root",
      customError("AtomicFlowManager", "ProofNotLastBatchInRoot(uint256,bytes32)", [0, populatedRightSibling])
    );
  });
});
