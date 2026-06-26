/**
 * End-to-end test for the L1-free atomic-interop stack (bundle model).
 *
 * Topology (two GW-settled chains):
 *   Chain A: depositor (anvil acct #0) sends aAmount of testTokenA -> recipient on B.
 *   Chain B: depositor (anvil acct #0) sends bAmount of testTokenB -> recipient on A.
 *
 * The flow is L1-free and runs through the production interop contracts:
 *   SEND    `InteropCenter.sendBundle(dstChainId, [indirect AR call starter], [atomicBundle attr])`.
 *           The bridge transfer burns via the normal `initiateIndirectCall`; because the bundle carries
 *           the `atomicBundle(flowId, deadline, lowNullifierIndex)` attribute the InteropCenter does NOT
 *           publish it to L1 — it appends the leg's commit value to this chain's
 *           {L2InteropCommitmentTree} via {AtomicFlowManager.append}.
 *   RECEIVE `InteropHandler.executeAtomicBundle(bundleBytes, AtomicFinalityProof)`. The handler asks the
 *           {AtomicFlowManager} to prove EVERY leg of the flow was committed in its source chain's IMT
 *           before the deadline (one IMT inclusion proof per leg), then executes the bundle's calls
 *           (the destination mint), owning the double-execute guard via `bundleStatus`.
 *   TIMEOUT `AtomicFlowManager.authorizeRefund(...)` (single-root non-inclusion proof for the missing
 *           leg, settled past the deadline) then `claimRefund(flowId, bundleBytes)` recovers the burned
 *           source funds to the depositor via `L2AssetRouter.recoverAtomicBurn`.
 *
 * Ids (see contracts/atomic-interop + contracts/interop):
 *   - `bundleHash = keccak256(abi.encode(sourceChainId, abi.encode(InteropBundle)))`. The atomic send
 *     params (flowId, deadline, lowNullifierIndex) travel via the `atomicBundle` ERC-7786 attribute and
 *     are NOT part of the InteropBundle, so `bundleHash` is independent of `flowId`. We PREDICT each
 *     leg's bundleHash off-chain with a non-atomic `callStatic.sendBundle` (which returns the same
 *     bundleHash without needing a low-nullifier), then cross-check it against the `InteropBundleSent`
 *     event of the real atomic send and fail loudly on mismatch.
 *   - `flowId = keccak256(abi.encode(sortedBundleHashes, sortedChainIds, deadline))` (both ascending).
 *   - `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
 *
 * The deadline is a settlement-layer (SL) block number; {AtomicInteropProof} derives the leg's SL block
 * from the (real, not mocked) `MessageHashing._getProofData` parse of `messageProof`, so the off-chain
 * builders embed a CHOSEN SL block in format-valid multi-hop proof bytes ({buildSlProofBytes}). The
 * root-message authentication itself is mocked to `true` on the anvil harness by
 * {MockL2MessageVerification}. The off-chain IMT engine reproduces the on-chain root / Merkle paths from
 * the live leaf set and asserts the reconstructed root equals `tree.root()` before emitting a proof, so
 * a passing test also confirms the off-chain engine matches the on-chain one.
 *
 * Verifies:
 *   - HAPPY PATH: atomic send (source burn + IMT insert) on both legs -> executeAtomicBundle (every-leg
 *     inclusion proof, SL block <= deadline) on each destination. Recipients receive the bridged token;
 *     source legs stay terminal at Committed; both destination bundles end FullyExecuted.
 *   - TIMEOUT PATH: one leg commits, the other never does -> after the deadline, a single-root
 *     non-inclusion proof (SL block > deadline) authorizes a refund -> claimRefund recovers the
 *     depositor's tokens; the source leg ends Reverted.
 */

import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  BundleStatus,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  ATOMIC_SEND_BUNDLE_GAS_LIMIT,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_SEND_BUNDLE_GAS_LIMIT,
} from "../../src/core/const";
import { encodeEvmAddress, encodeEvmChain } from "../../src/core/data-encoding";
import {
  atomicBundleAttr,
  getInteropProtocolFee,
  getTokenTransferData,
  indirectCallAttr,
  sendInteropBundle,
} from "../../src/helpers/interop-helpers";
import type { AtomicStack } from "../../src/helpers/imt-atomic-deployer";
import { deployAtomicStack } from "../../src/helpers/imt-atomic-deployer";
import {
  atomicFinalityProofTuple,
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  computeFlowId,
  lowNullifierIndexFor,
  nonInclusionProofTuple,
  reconstructChainImt,
} from "../../src/helpers/imt-engine-lib";

const TEST_TOKEN_DECIMALS = 18;

/** Mirror of `LegState` in contracts/atomic-interop/IAtomicInterop.sol. */
enum LegState {
  Unset = 0,
  Committed = 1,
  Revertable = 2,
  Reverted = 3,
}

type ChainCtx = {
  chainId: number;
  rpcUrl: string;
  provider: ethers.providers.JsonRpcProvider;
  user: Wallet;
  testToken: Contract;
  stack: AtomicStack;
};

const NTV_TOKEN_ADDRESS_ABI = ["function tokenAddress(bytes32 assetId) view returns (address)"];
const ERC20_BALANCE_ABI = ["function balanceOf(address) view returns (uint256)"];

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

type ParsedManagerLog = { name: string; args: ethers.utils.Result } | undefined;

/** Parse an AtomicFlowManager event log, returning {name, args} or undefined for non-manager logs. */
function parseManagerLog(manager: Contract, log: ethers.providers.Log): ParsedManagerLog {
  if (log.address.toLowerCase() !== manager.address.toLowerCase()) return undefined;
  try {
    const parsed = manager.interface.parseLog(log);
    return { name: parsed.name, args: parsed.args };
  } catch {
    return undefined;
  }
}

describe("13 - IMT atomic swap A <-> B (L1-free, bundle model)", function () {
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
    const gwSettledIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledIds.length < 2) throw new Error("Need >=2 gwSettled chains");
    const [aId, bId] = gwSettledIds;

    const ctxs = await Promise.all(
      [aId, bId].map(async (chainId) => {
        const rpcUrl = getL2Chain(state.chains!, chainId).rpcUrl;
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        const user = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
        const tokenAddress = state.testTokens![chainId];
        if (!tokenAddress) throw new Error(`No test token registered for chain ${chainId}`);
        const testToken = new Contract(tokenAddress, getAbi("TestnetERC20Token"), user);
        const stack = await deployAtomicStack({ chainId, provider });
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
   * Predict a leg's bundleHash via a non-atomic callStatic on its source chain, targeting `dest`.
   * (Kept local so the `dest` chain id is explicit rather than threaded through a placeholder.)
   */
  async function predictLegBundleHash(
    source: ChainCtx,
    dest: ChainCtx,
    amount: BigNumber,
    recipient: string
  ): Promise<string> {
    const interopCenter = source.stack.interopCenter.connect(source.user);
    return interopCenter.callStatic.sendBundle(
      encodeEvmChain(dest.chainId),
      [bridgeCallStarter(source, amount, recipient)],
      [],
      { gasLimit: INTEROP_SEND_BUNDLE_GAS_LIMIT, value: fee }
    );
  }

  /**
   * Real atomic send of one leg: approve the source token, send the bundle with the `atomicBundle`
   * attribute, and assert the emitted bundleHash matches the prediction used to build `flowId`.
   */
  async function sendAtomicLeg(params: {
    source: ChainCtx;
    dest: ChainCtx;
    amount: BigNumber;
    recipient: string;
    flowId: string;
    deadline: number;
    predictedBundleHash: string;
  }): Promise<{ bundleData: string; bundleHash: string }> {
    const { source, dest, amount, recipient, flowId, deadline, predictedBundleHash } = params;

    await ensureNtvApproval(source, amount);

    const value = commitValue(flowId, predictedBundleHash);
    const lowNull = await lowNullifierIndexFor(source.stack.tree, value);

    const sendResult = await sendInteropBundle({
      sourceProvider: source.provider,
      destinationChainId: dest.chainId,
      callStarters: [bridgeCallStarter(source, amount, recipient)],
      bundleAttributes: [atomicBundleAttr(flowId, deadline, lowNull)],
      value: fee,
      // Atomic sends append to the IMT (~1.1M gas insert) on top of the burn; the plain-send default
      // (INTEROP_SEND_BUNDLE_GAS_LIMIT) is too small.
      gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT,
    });

    // Cross-check the predicted bundleHash against the actual one the InteropCenter emitted.
    expect(sendResult.bundleHash.toLowerCase(), "predicted bundleHash matches emitted").to.equal(
      predictedBundleHash.toLowerCase()
    );
    return { bundleData: sendResult.bundleData, bundleHash: sendResult.bundleHash };
  }

  it("happy path: atomic send -> executeAtomicBundle mints both legs and leaves source Committed", async () => {
    const user = chainA.user.address; // anvil acct #0, the depositor + recipient on both chains
    const now = Math.max(await chainNow(chainA.provider), await chainNow(chainB.provider));
    // The deadline is an SL block number; the harness picks SL block == deadline for inclusion proofs.
    const deadline = now + 3600;

    // ── Predict each leg's bundleHash (no state change), then derive flowId ──────────────────
    const hAB = await predictLegBundleHash(chainA, chainB, aAmount, user);
    const hBA = await predictLegBundleHash(chainB, chainA, bAmount, user);

    const legHashesAsc = BigNumber.from(hAB).lt(BigNumber.from(hBA)) ? [hAB, hBA] : [hBA, hAB];
    const chainIdsAsc = [chainA.chainId, chainB.chainId].sort((x, y) => x - y);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);

    // ── PHASE 1: atomic send on each source (burn + IMT insert) ──────────────────────────────
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const bBalanceBefore: BigNumber = await chainB.testToken.balanceOf(user);

    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aAmount,
      recipient: user,
      flowId,
      deadline,
      predictedBundleHash: hAB,
    });
    const ba = await sendAtomicLeg({
      source: chainB,
      dest: chainA,
      amount: bAmount,
      recipient: user,
      flowId,
      deadline,
      predictedBundleHash: hBA,
    });

    // Source legs are Committed; tokens left the depositor and were burned via AR/NTV.
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB committed on A");
    expect(await chainB.stack.manager.legState(flowId, hBA)).to.equal(LegState.Committed, "BA committed on B");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(aBalanceBefore.sub(aAmount).toString());
    expect((await chainB.testToken.balanceOf(user)).toString()).to.equal(bBalanceBefore.sub(bAmount).toString());

    // The commit values are now present in their source chains' IMTs (off-chain engine == on-chain).
    const abValue = commitValue(flowId, hAB);
    const baValue = commitValue(flowId, hBA);
    const imtA = await reconstructChainImt(chainA.stack.tree);
    const imtB = await reconstructChainImt(chainB.stack.tree);
    expect(
      imtA.leaves.some((leaf) => BigNumber.from(leaf.value).eq(abValue)),
      "AB value in A's IMT"
    ).to.be.true;
    expect(
      imtB.leaves.some((leaf) => BigNumber.from(leaf.value).eq(baValue)),
      "BA value in B's IMT"
    ).to.be.true;
    expect(imtA.root.toLowerCase()).to.equal((await chainA.stack.tree.root()).toLowerCase());
    expect(imtB.root.toLowerCase()).to.equal((await chainB.stack.tree.root()).toLowerCase());

    // ── PHASE 2: build the per-flow inclusion proofs (one per leg, in ascending bundleHash order) ─
    // executeAtomicBundle requires EVERY leg present in a root settled no later than the deadline,
    // so even the executing chain's own leg needs an inclusion proof.
    const abProof = await buildInclusionProof({
      l2Tree: chainA.stack.tree,
      chainId: chainA.chainId,
      value: abValue,
      slBlock: deadline,
    });
    const baProof = await buildInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      slBlock: deadline,
    });
    // proofs must be in legBundleHashes (ascending) order.
    const proofsAsc = BigNumber.from(hAB).lt(BigNumber.from(hBA)) ? [abProof, baProof] : [baProof, abProof];
    const finality = atomicFinalityProofTuple({
      flowId,
      deadline,
      legBundleHashes: legHashesAsc,
      chainIds: chainIdsAsc,
      proofs: proofsAsc,
    });

    // ── PHASE 3: execute each destination leg via executeAtomicBundle ─────────────────────────
    const handlerB = chainB.stack.interopHandler.connect(chainB.user);
    const handlerA = chainA.stack.interopHandler.connect(chainA.user);
    await (await handlerB.executeAtomicBundle(ab.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    await (await handlerA.executeAtomicBundle(ba.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();

    // Destination bundles are FullyExecuted; source legs remain Committed (terminal on the happy path).
    expect(await handlerB.bundleStatus(hAB)).to.equal(BundleStatus.FullyExecuted, "AB executed on B");
    expect(await handlerA.bundleStatus(hBA)).to.equal(BundleStatus.FullyExecuted, "BA executed on A");
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB stays Committed on A");
    expect(await chainB.stack.manager.legState(flowId, hBA)).to.equal(LegState.Committed, "BA stays Committed on B");

    // ── Destination mint assertions ──────────────────────────────────────────────────────────
    // B receives a freshly-deployed bridged shim for A's token (assetId of A.testToken on chain A).
    const abAssetId = ntvAssetId(chainA.chainId, chainA.testToken.address);
    const ntvOnB = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, NTV_TOKEN_ADDRESS_ABI, chainB.provider);
    const shimAonB = await ntvOnB.tokenAddress(abAssetId);
    expect(shimAonB).to.not.equal(ethers.constants.AddressZero, "shim for A's token deployed on B");
    const shimAonBBal = await new Contract(shimAonB, ERC20_BALANCE_ABI, chainB.provider).balanceOf(user);
    expect(shimAonBBal.toString()).to.equal(aAmount.toString(), "recipient on B received aAmount");

    // A receives a bridged shim for B's token.
    const baAssetId = ntvAssetId(chainB.chainId, chainB.testToken.address);
    const ntvOnA = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, NTV_TOKEN_ADDRESS_ABI, chainA.provider);
    const shimBonA = await ntvOnA.tokenAddress(baAssetId);
    expect(shimBonA).to.not.equal(ethers.constants.AddressZero, "shim for B's token deployed on A");
    const shimBonABal = await new Contract(shimBonA, ERC20_BALANCE_ABI, chainA.provider).balanceOf(user);
    expect(shimBonABal.toString()).to.equal(bAmount.toString(), "recipient on A received bAmount");
  });

  it("timeout path: one leg commits, peer never does -> authorizeRefund + claimRefund recovers depositor", async () => {
    const user = chainA.user.address;
    // The deadline is an SL block number; the missing leg's non-inclusion proof carries a post-deadline
    // SL block (deadline + 1). Both are arbitrary on the harness — only the deadline check is exercised.
    const deadline = 1_000;

    const refundRecipient = chainB.user.address; // irrelevant for refund; distinct dest recipient
    const aTimeoutAmount = ethers.utils.parseUnits("3", TEST_TOKEN_DECIMALS);
    const bTimeoutAmount = ethers.utils.parseUnits("5", TEST_TOKEN_DECIMALS);

    // ── Predict both legs' bundleHashes -> flowId (the BA leg is never sent). ─────────────────
    const hAB = await predictLegBundleHash(chainA, chainB, aTimeoutAmount, refundRecipient);
    const hBA = await predictLegBundleHash(chainB, chainA, bTimeoutAmount, refundRecipient);

    const legHashesAsc = BigNumber.from(hAB).lt(BigNumber.from(hBA)) ? [hAB, hBA] : [hBA, hAB];
    const chainIdsAsc = [chainA.chainId, chainB.chainId].sort((x, y) => x - y);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);

    // ── Commit only the AB leg on A. B never commits BA. ─────────────────────────────────────
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aTimeoutAmount,
      recipient: refundRecipient,
      flowId,
      deadline,
      predictedBundleHash: hAB,
    });

    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB committed on A");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(
      aBalanceBefore.sub(aTimeoutAmount).toString(),
      "AB depositor burned tokens at commit"
    );

    // ── Build a single-root non-inclusion proof for the missing BA leg against B's IMT, with an
    //    SL block strictly past the deadline. ──────────────────────────────────────────────────
    const baValue = commitValue(flowId, hBA);
    const nonIncl = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      slBlock: deadline + 1,
    });
    const missingIdx = legHashesAsc[0] === hBA ? 0 : 1;

    // ── authorizeRefund on A (A is AB's source) -> AB becomes Revertable. ────────────────────
    const managerA = chainA.stack.manager.connect(chainA.user);
    const refundAuth = await (
      await managerA.authorizeRefund(
        flowId,
        legHashesAsc,
        chainIdsAsc,
        deadline,
        missingIdx,
        nonInclusionProofTuple(nonIncl),
        { gasLimit: DEFAULT_TX_GAS_LIMIT }
      )
    ).wait();
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Revertable, "AB revertable on A");
    expect(
      refundAuth.logs
        .map((l: ethers.providers.Log) => parseManagerLog(chainA.stack.manager, l))
        .some((p: ParsedManagerLog) => p?.name === "FlowRefundAuthorized" && p.args.bundleHash === hAB),
      "FlowRefundAuthorized(hAB) on A"
    ).to.be.true;

    // ── claimRefund on A -> depositor recovers the burned tokens; state Reverted. ────────────
    const claim = await (await managerA.claimRefund(flowId, ab.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Reverted, "AB reverted on A");

    const aAfterRefund: BigNumber = await chainA.testToken.balanceOf(user);
    expect(aAfterRefund.toString()).to.equal(aBalanceBefore.toString(), "AB depositor fully recovered the burned tokens");

    expect(
      claim.logs
        .map((l: ethers.providers.Log) => parseManagerLog(chainA.stack.manager, l))
        .some((p: ParsedManagerLog) => p?.name === "FlowRefunded" && p.args.bundleHash === hAB),
      "FlowRefunded(hAB) on A"
    ).to.be.true;
  });
});
