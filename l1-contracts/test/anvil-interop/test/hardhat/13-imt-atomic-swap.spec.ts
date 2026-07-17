/**
 * End-to-end test for the atomic-interop stack (bundle model).
 *
 * Topology (two GW-settled chains):
 *   Chain A: depositor (anvil acct #0) sends aAmount of testTokenA -> recipient on B.
 *   Chain B: depositor (anvil acct #0) sends bAmount of testTokenB -> recipient on A.
 *
 * The flow runs through the production interop contracts:
 *   SEND    `InteropCenter.sendBundle(dstChainId, [indirect AR call starter], [atomicBundle attr])`.
 *           The bridge transfer burns via `initiateIndirectCall`; the `atomicBundle` attribute makes
 *           the InteropCenter append the leg's commit value to the L2InteropCommitmentTree instead of
 *           publishing to L1.
 *   RECEIVE `InteropHandler.executeAtomicBundle(bundleBytes, AtomicFinalityProof)`. Proves every leg
 *           was committed in its source chain's IMT before the deadline (one inclusion proof per leg),
 *           then executes the bundle's calls (the destination mint). `bundleStatus` guards double-execute.
 *   TIMEOUT `AtomicFlowManager.authorizeRefund(...)`: checked against a settlement interop root created
 *           strictly after the deadline (the timestamp in `interopRoots[slChainId][slBlock]` is
 *           `> deadline`, added on the harness via bootloader impersonation), proves the missing leg
 *           absent from the batch-begin IMT root of a late batch (`t > deadline`) — or, for a halted source
 *           chain, absent from the batch-end IMT root of the chain's LAST batch inside that settlement
 *           interop root (`t <= deadline`) — then `claimRefund(flowId, bundleBytes)` recovers the burned
 *           source funds to the depositor via L2AssetRouter's recoverAtomicCall. See the
 *           AtomicInteropProof.sol library header for the canonical protocol description.
 *
 * Ids:
 *   - `bundleHash = keccak256(abi.encode(sourceChainId, abi.encode(InteropBundle)))`. The atomic send
 *     params (the full flowId preimage + lowNullifierIndex) ride in the `atomicBundle` attribute and are
 *     not part of the InteropBundle, so `bundleHash` is independent of the preimage (whose leg hashes
 *     include the bundle's own hash). We predict each leg's bundleHash off-chain with a non-atomic
 *     `callStatic.sendBundle`, then cross-check it against the real send's `InteropBundleSent` event and
 *     fail loudly on mismatch. On-chain, the AtomicFlowManager additionally requires the sent bundle's
 *     hash to be one of the preimage's legs, so a stale prediction reverts the send.
 *   - `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`
 *     (bundle hashes ascending, source chain ids positionally aligned), recomputed on-chain from the
 *     attribute-supplied preimage rather than accepted from the sender.
 *   - `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
 *
 * The deadline is a settlement-layer timestamp, compared on-chain against each batch's settlement
 * timestamp `t` from the real `MessageHashing._getProofData` parse of `settlementProof`, so the
 * off-chain builders embed a chosen `t` in format-valid multi-hop proof bytes (including the exact
 * 3-hop chain-batch-root leaf path the verifier enforces). Chain-batch-root leaf authentication is
 * mocked to `true` on the anvil harness. The off-chain IMT engine reconstructs the root / Merkle paths
 * from the live leaf set and asserts it matches `tree.root()` before emitting a proof, so a passing
 * test also confirms the off-chain engine agrees with the on-chain one.
 *
 * Verifies:
 *   - HAPPY PATH: atomic send (source burn + IMT insert) on both legs -> executeAtomicBundle (every-leg
 *     inclusion proof, `t <= deadline` — exercised exactly AT the boundary) on each destination.
 *     Recipients receive the bridged token; source legs stay terminal at Committed; both destination
 *     bundles end FullyExecuted.
 *   - TIMEOUT PATH (late batch): one leg commits, the other never does -> a single absence proof
 *     (missing leg absent from the batch-begin IMT root of a batch with `t > deadline`, checked against
 *     a post-deadline settlement interop root) authorizes a refund -> claimRefund recovers the
 *     depositor's tokens; the source leg ends Reverted.
 *   - TIMEOUT PATH (halted chain): same setup, but the absence proof uses an in-time batch
 *     (`t <= deadline`, exercised exactly AT the boundary) that is the chain's LAST batch inside a
 *     post-deadline settlement interop root, checked against the batch-end IMT root.
 *   - TIMEOUT NEGATIVES: a settlement interop root not created strictly after the deadline is rejected
 *     (`ProofInteropRootNotAfterDeadline`, exercised exactly AT the boundary `T == deadline`), and an
 *     in-time batch that is NOT the last batch in the settlement interop root is rejected
 *     (`ProofNotLastBatchInRoot`).
 */

import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain, impersonateAndRun } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
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
  INTEROP_SEND_BUNDLE_GAS_LIMIT,
} from "../../src/core/const";
import { encodeEvmAddress, encodeEvmChain } from "../../src/core/data-encoding";
import { customError, expectRevert } from "../../src/helpers/balance-helpers";
import {
  atomicBundleAttr,
  interopBundleSaltAttr,
  getInteropProtocolFee,
  getTokenTransferData,
  indirectCallAttr,
  sendInteropBundle,
} from "../../src/helpers/interop-helpers";
import type { AtomicFlowPreimage } from "../../src/helpers/interop-helpers";
import {
  DEFAULT_SL_CHAIN_ID,
  atomicFinalityProofTuple,
  atomicFlowTuple,
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  computeFlowId,
  lowNullifierIndexFor,
  proofTuple,
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

/**
 * Handles to the atomic-interop built-ins on one L2 chain. These contracts are predeployed into the
 * ZKsync OS genesis (see `src/core/predeploys.ts`) and the {L2InteropCommitmentTree}'s IMT is seeded
 * by the harness's relayed v31 genesis upgrade (`_initializeV31Contracts` -> `tree.initL2()`), so
 * no install/seed step is needed here — we just bind contract objects to their canonical addresses.
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

/** Bind the predeployed, genesis-seeded atomic-interop built-ins to their canonical addresses. */
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
  });
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
        // Atomic-interop built-ins are predeployed in genesis and the tree is genesis-seeded
        // (leafCount=1), so just bind handles to their canonical addresses — no install/initialize.
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
   * Predict a leg's bundleHash via a non-atomic callStatic on its source chain, targeting `dest`.
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
    // The bundleHash now depends on the `interopBundleSalt` attribute (folded into the bundle), so the
    // prediction MUST carry the exact same salt the real atomic send will use — otherwise the predicted
    // hash (and the flowId derived from it) would not match the emitted one.
    return interopCenter.callStatic.sendBundle(
      encodeEvmChain(dest.chainId),
      [bridgeCallStarter(source, amount, recipient)],
      [interopBundleSaltAttr(salt)],
      { gasLimit: INTEROP_SEND_BUNDLE_GAS_LIMIT, value: fee }
    );
  }

  /** A fresh, deterministic-per-send bundle salt. Random keeps it unique per (sender, salt) — the
   *  uniqueness InteropCenter enforces — while staying known off-chain so the bundleHash is predictable. */
  function freshBundleSalt(): string {
    return ethers.utils.hexlify(ethers.utils.randomBytes(32));
  }

  /**
   * Build the `atomicBundle` attribute's flowId preimage from the ascending leg hashes and their
   * aligned source chain ids. The flowId itself is never sent: the AtomicFlowManager recomputes it
   * on-chain from exactly these fields (see `computeFlowId` for the mirrored hash).
   */
  function flowPreimageOf(legHashesAsc: string[], chainIdsAsc: number[], deadline: number): AtomicFlowPreimage {
    return {
      deadline,
      settlementLayerChainId: DEFAULT_SL_CHAIN_ID,
      legBundleHashes: legHashesAsc,
      legSourceChainIds: chainIdsAsc,
    };
  }

  /**
   * Real atomic send of one leg: approve the source token, send the bundle with the `atomicBundle`
   * attribute (carrying the full flowId preimage), and assert the emitted bundleHash matches the
   * prediction embedded in the preimage's leg hashes.
   */
  async function sendAtomicLeg(params: {
    source: ChainCtx;
    dest: ChainCtx;
    amount: BigNumber;
    recipient: string;
    flowPreimage: AtomicFlowPreimage;
    predictedBundleHash: string;
    salt: string;
  }): Promise<{ bundleData: string; bundleHash: string }> {
    const { source, dest, amount, recipient, flowPreimage, predictedBundleHash, salt } = params;

    await ensureNtvApproval(source, amount);

    // Derived, not sent: mirrors the on-chain recomputation from the attribute-supplied preimage.
    const flowId = computeFlowId(
      flowPreimage.legBundleHashes,
      flowPreimage.legSourceChainIds,
      flowPreimage.deadline,
      flowPreimage.settlementLayerChainId
    );
    const value = commitValue(flowId, predictedBundleHash);
    const lowNull = await lowNullifierIndexFor(source.stack.tree, value);

    const sendResult = await sendInteropBundle({
      sourceProvider: source.provider,
      destinationChainId: dest.chainId,
      callStarters: [bridgeCallStarter(source, amount, recipient)],
      // Same salt used to predict `predictedBundleHash`, so the emitted bundleHash matches the
      // preimage's leg hash (the AtomicFlowManager rejects the send otherwise).
      bundleAttributes: [atomicBundleAttr(flowPreimage, lowNull), interopBundleSaltAttr(salt)],
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
    // The deadline is an SL timestamp; the harness sets each leg's batch `l1Timestamp == deadline`,
    // pinning the inclusive `l1Timestamp <= deadline` finality bound exactly at the boundary.
    const deadline = now + 3600;

    // ── Predict each leg's bundleHash (no state change), then derive flowId ──────────────────
    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aAmount, user, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bAmount, user, saltBA);

    // Legs sorted by ascending bundleHash; each leg's source chain id stays positionally aligned:
    // chainIdsAsc[i] is the source chain of legHashesAsc[i]. Sorting the chain ids independently
    // would misalign them, which the on-chain source-chain binding rejects.
    const legs = [
      { hash: hAB, chainId: chainA.chainId },
      { hash: hBA, chainId: chainB.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    const legHashesAsc = legs.map((l) => l.hash);
    const chainIdsAsc = legs.map((l) => l.chainId);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);
    const flowPreimage = flowPreimageOf(legHashesAsc, chainIdsAsc, deadline);

    // ── PHASE 1: atomic send on each source (burn + IMT insert) ──────────────────────────────
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
      l1Timestamp: deadline,
    });
    const baProof = await buildInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      l1Timestamp: deadline,
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
    // Snapshot the recipient shim balances BEFORE execute. The coverage harness runs every spec on
    // one shared chain set, so `user` may already hold these bridged shims from earlier specs — so we
    // assert the DELTA credited by this swap, not the absolute balance (the source-side checks above
    // are delta-based for the same reason).
    const abAssetId = ntvAssetId(chainA.chainId, chainA.testToken.address);
    const baAssetId = ntvAssetId(chainB.chainId, chainB.testToken.address);
    const ntvOnB = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, NTV_TOKEN_ADDRESS_ABI, chainB.provider);
    const ntvOnA = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, NTV_TOKEN_ADDRESS_ABI, chainA.provider);
    const shimAonBAddrBefore: string = await ntvOnB.tokenAddress(abAssetId);
    const shimAonBBefore: BigNumber =
      shimAonBAddrBefore === ethers.constants.AddressZero
        ? BigNumber.from(0)
        : await new Contract(shimAonBAddrBefore, ERC20_BALANCE_ABI, chainB.provider).balanceOf(user);
    const shimBonAAddrBefore: string = await ntvOnA.tokenAddress(baAssetId);
    const shimBonABefore: BigNumber =
      shimBonAAddrBefore === ethers.constants.AddressZero
        ? BigNumber.from(0)
        : await new Contract(shimBonAAddrBefore, ERC20_BALANCE_ABI, chainA.provider).balanceOf(user);

    const handlerB = chainB.stack.interopHandler.connect(chainB.user);
    const handlerA = chainA.stack.interopHandler.connect(chainA.user);
    await (await handlerB.executeAtomicBundle(ab.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    await (await handlerA.executeAtomicBundle(ba.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();

    // Destination bundles are FullyExecuted; source legs remain Committed (terminal on the happy path).
    expect(await handlerB.bundleStatus(hAB)).to.equal(BundleStatus.FullyExecuted, "AB executed on B");
    expect(await handlerA.bundleStatus(hBA)).to.equal(BundleStatus.FullyExecuted, "BA executed on A");
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB stays Committed on A");
    expect(await chainB.stack.manager.legState(flowId, hBA)).to.equal(LegState.Committed, "BA stays Committed on B");

    // ── Destination mint assertions (delta — robust to pre-existing shim balance) ──────────────
    // B receives a bridged shim for A's token (assetId of A.testToken on chain A).
    const shimAonB = await ntvOnB.tokenAddress(abAssetId);
    expect(shimAonB).to.not.equal(ethers.constants.AddressZero, "shim for A's token deployed on B");
    const shimAonBAfter: BigNumber = await new Contract(shimAonB, ERC20_BALANCE_ABI, chainB.provider).balanceOf(user);
    expect(shimAonBAfter.sub(shimAonBBefore).toString()).to.equal(
      aAmount.toString(),
      "recipient on B received aAmount"
    );

    // A receives a bridged shim for B's token.
    const shimBonA = await ntvOnA.tokenAddress(baAssetId);
    expect(shimBonA).to.not.equal(ethers.constants.AddressZero, "shim for B's token deployed on A");
    const shimBonAAfter: BigNumber = await new Contract(shimBonA, ERC20_BALANCE_ABI, chainA.provider).balanceOf(user);
    expect(shimBonAAfter.sub(shimBonABefore).toString()).to.equal(
      bAmount.toString(),
      "recipient on A received bAmount"
    );
  });

  it("timeout path (late batch): one leg commits, peer never does -> authorizeRefund + claimRefund recovers depositor", async () => {
    const user = chainA.user.address;
    const deadline = 1_000;
    // The settlement interop root used by the absence proof must have been created after the deadline.
    // This fixed block is unique within the spec. The helper makes reruns against retained state idempotent.
    const settlementInteropRootBlock = 201;
    await ensureSettlementInteropRoot(chainA.provider, settlementInteropRootBlock, deadline + 5);

    const refundRecipient = chainB.user.address; // irrelevant for refund; distinct dest recipient
    const aTimeoutAmount = ethers.utils.parseUnits("3", TEST_TOKEN_DECIMALS);
    const bTimeoutAmount = ethers.utils.parseUnits("5", TEST_TOKEN_DECIMALS);

    // ── Predict both legs' bundleHashes -> flowId (the BA leg is never sent). ─────────────────
    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aTimeoutAmount, refundRecipient, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bTimeoutAmount, refundRecipient, saltBA);

    // Legs sorted by ascending bundleHash; each leg's source chain id stays positionally aligned:
    // chainIdsAsc[i] is the source chain of legHashesAsc[i]. Sorting the chain ids independently
    // would misalign them, which the on-chain source-chain binding rejects.
    const legs = [
      { hash: hAB, chainId: chainA.chainId },
      { hash: hBA, chainId: chainB.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    const legHashesAsc = legs.map((l) => l.hash);
    const chainIdsAsc = legs.map((l) => l.chainId);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);

    // ── Commit only the AB leg on A. B never commits BA. ─────────────────────────────────────
    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aTimeoutAmount,
      recipient: refundRecipient,
      flowPreimage: flowPreimageOf(legHashesAsc, chainIdsAsc, deadline),
      predictedBundleHash: hAB,
      salt: saltAB,
    });

    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB committed on A");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(
      aBalanceBefore.sub(aTimeoutAmount).toString(),
      "AB depositor burned tokens at commit"
    );

    // ── Build the timeout proof for the missing BA leg against B's IMT: non-inclusion against the
    //    batch-begin root of a late batch (`t > deadline`), checked against the post-deadline
    //    settlement interop root added above. The live tree root stands in for the begin-root snapshot
    //    (leaf 2 of the chain batch root) on the harness.
    const baValue = commitValue(flowId, hBA);
    const absence = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      l1Timestamp: deadline + 1, // t > deadline: the first late batch's begin root
      provesAgainstBeginRoot: true,
      batchNumber: 1,
      slBlock: settlementInteropRootBlock,
    });
    const missingIdx = legHashesAsc[0] === hBA ? 0 : 1;

    // ── authorizeRefund on A (A is AB's source) -> AB becomes Revertable. ────────────────────
    const managerA = chainA.stack.manager.connect(chainA.user);
    const refundAuth = await (
      await managerA.authorizeRefund(
        atomicFlowTuple({ flowId, deadline, legBundleHashes: legHashesAsc, chainIds: chainIdsAsc }),
        missingIdx,
        proofTuple(absence),
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
    expect(aAfterRefund.toString()).to.equal(
      aBalanceBefore.toString(),
      "AB depositor fully recovered the burned tokens"
    );

    expect(
      claim.logs
        .map((l: ethers.providers.Log) => parseManagerLog(chainA.stack.manager, l))
        .some((p: ParsedManagerLog) => p?.name === "FlowRefunded" && p.args.bundleHash === hAB),
      "FlowRefunded(hAB) on A"
    ).to.be.true;
  });

  /** A fabricated (never-sent) two-leg flow for proof-validation tests: authorizeRefund verifies the
   *  absence proof before touching any leg state, so no real sends are needed to exercise reverts. */
  function fabricatedFlow(deadline: number) {
    const legs = [
      { hash: ethers.utils.id("fabricated-leg-1"), chainId: chainA.chainId },
      { hash: ethers.utils.id("fabricated-leg-2"), chainId: chainB.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    const legHashesAsc = legs.map((l) => l.hash);
    const chainIdsAsc = legs.map((l) => l.chainId);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);
    // The "missing" leg is the one sourced on chain B (proofs below are against B's IMT).
    const missingIdx = chainIdsAsc.indexOf(chainB.chainId);
    return { flowId, legHashesAsc, chainIdsAsc, missingIdx };
  }

  it("timeout path (halted chain): in-time LAST batch + end-root absence authorizes the refund", async () => {
    const user = chainA.user.address;
    // Same shape as the late-batch timeout test, but the source chain "halted": its last batch inside
    // the post-deadline settlement interop root is still in time (`t <= deadline`, pinned exactly AT
    // the boundary). The proof then checks absence against the batch-END IMT root of that last batch
    // (the zero-length batch-leaf path of the single-leaf chain tree trivially satisfies the
    // last-batch check).
    const deadline = 1_000;
    const settlementInteropRootBlock = 202;
    await ensureSettlementInteropRoot(chainA.provider, settlementInteropRootBlock, deadline + 5);

    const refundRecipient = chainB.user.address;
    const aTimeoutAmount = ethers.utils.parseUnits("2", TEST_TOKEN_DECIMALS);
    const bTimeoutAmount = ethers.utils.parseUnits("4", TEST_TOKEN_DECIMALS);

    const saltAB = freshBundleSalt();
    const saltBA = freshBundleSalt();
    const hAB = await predictLegBundleHash(chainA, chainB, aTimeoutAmount, refundRecipient, saltAB);
    const hBA = await predictLegBundleHash(chainB, chainA, bTimeoutAmount, refundRecipient, saltBA);

    const legs = [
      { hash: hAB, chainId: chainA.chainId },
      { hash: hBA, chainId: chainB.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    const legHashesAsc = legs.map((l) => l.hash);
    const chainIdsAsc = legs.map((l) => l.chainId);
    const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);

    const aBalanceBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const ab = await sendAtomicLeg({
      source: chainA,
      dest: chainB,
      amount: aTimeoutAmount,
      recipient: refundRecipient,
      flowPreimage: flowPreimageOf(legHashesAsc, chainIdsAsc, deadline),
      predictedBundleHash: hAB,
      salt: saltAB,
    });
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Committed, "AB committed on A");

    // Halted-source absence proof: `t <= deadline` selects the END-root branch (t == deadline pins
    // the boundary), and the empty batch-leaf path marks the batch as the chain's last inside the
    // settlement interop root.
    const baValue = commitValue(flowId, hBA);
    const absence = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      l1Timestamp: deadline,
      provesAgainstBeginRoot: false,
      batchNumber: 1,
      slBlock: settlementInteropRootBlock,
    });
    const missingIdx = legHashesAsc[0] === hBA ? 0 : 1;

    const managerA = chainA.stack.manager.connect(chainA.user);
    await (
      await managerA.authorizeRefund(
        atomicFlowTuple({ flowId, deadline, legBundleHashes: legHashesAsc, chainIds: chainIdsAsc }),
        missingIdx,
        proofTuple(absence),
        { gasLimit: DEFAULT_TX_GAS_LIMIT }
      )
    ).wait();
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Revertable, "AB revertable on A");

    await (await managerA.claimRefund(flowId, ab.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
    expect(await chainA.stack.manager.legState(flowId, hAB)).to.equal(LegState.Reverted, "AB reverted on A");
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(
      aBalanceBefore.toString(),
      "AB depositor fully recovered the burned tokens"
    );
  });

  it("send-time coupling: an atomic send whose preimage does not contain the bundle is rejected", async () => {
    // Regression for the flowId footgun: before the attribute carried the full preimage, a sender could
    // commit a bundle under an arbitrary flowId whose preimage did not contain the bundle's hash (e.g.
    // built from a stale off-chain prediction), stranding the burned funds forever. Now the whole send
    // reverts before any burn: the AtomicFlowManager recomputes flowId from the preimage and requires
    // the sent bundle to be one of its legs, declared with the sending chain as its source.
    const user = chainA.user.address;
    const deadline = (await chainNow(chainA.provider)) + 3600;
    const amount = ethers.utils.parseUnits("1", TEST_TOKEN_DECIMALS);
    const salt = freshBundleSalt();
    const realHash = await predictLegBundleHash(chainA, chainB, amount, user, salt);
    const strayLeg = ethers.utils.id("stale predicted bundle hash");
    const interopCenter = chainA.stack.interopCenter.connect(chainA.user);

    const sendWithPreimage = (preimage: AtomicFlowPreimage) => () =>
      interopCenter.callStatic.sendBundle(
        encodeEvmChain(chainB.chainId),
        [bridgeCallStarter(chainA, amount, user)],
        [atomicBundleAttr(preimage, 0), interopBundleSaltAttr(salt)],
        { gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT, value: fee }
      );

    // 1. Preimage whose legs do NOT include the bundle actually being sent.
    await expectRevert(
      sendWithPreimage(flowPreimageOf([strayLeg], [chainA.chainId], deadline)),
      "atomic send with preimage missing the bundle",
      customError("AtomicFlowManager", "ManagerCommittedBundleNotInFlow(bytes32,bytes32)")
    );

    // 2. Preimage that contains the bundle, but declares the wrong source chain for it.
    const misdeclaredLegs = [
      { hash: realHash, chainId: chainB.chainId }, // wrong: this leg is sent from chain A
      { hash: strayLeg, chainId: chainA.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    await expectRevert(
      sendWithPreimage(
        flowPreimageOf(
          misdeclaredLegs.map((l) => l.hash),
          misdeclaredLegs.map((l) => l.chainId),
          deadline
        )
      ),
      "atomic send with wrong declared source chain",
      customError("AtomicFlowManager", "ManagerCommittedLegSourceChainMismatch(bytes32,uint256,uint256)")
    );

    // 3. The exact same bundle with a well-formed preimage still sends fine (control for 1/2: proves
    //    the reverts above came from the coupling checks, not from the send setup).
    const controlLegs = [
      { hash: realHash, chainId: chainA.chainId },
      { hash: strayLeg, chainId: chainB.chainId },
    ].sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
    const controlPreimage = flowPreimageOf(
      controlLegs.map((l) => l.hash),
      controlLegs.map((l) => l.chainId),
      deadline
    );
    const controlFlowId = computeFlowId(controlPreimage.legBundleHashes, controlPreimage.legSourceChainIds, deadline);
    const lowNull = await lowNullifierIndexFor(chainA.stack.tree, commitValue(controlFlowId, realHash));
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
    const { flowId, legHashesAsc, chainIdsAsc, missingIdx } = fabricatedFlow(deadline);
    const missingValue = commitValue(flowId, legHashesAsc[missingIdx]);
    const flow = atomicFlowTuple({ flowId, deadline, legBundleHashes: legHashesAsc, chainIds: chainIdsAsc });
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
      customError("AtomicFlowManager", "ProofInteropRootNotAfterDeadline(uint256,uint64)")
    );

    // 2. Settlement interop root is missing, so its unset timestamp reads as 0: rejected.
    const missingSettlementRootProof = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: missingValue,
      l1Timestamp: deadline + 1,
      provesAgainstBeginRoot: true,
      slBlock: 999_999,
    });
    await expectRevert(
      () => managerA.callStatic.authorizeRefund(flow, missingIdx, proofTuple(missingSettlementRootProof)),
      "missing settlement interop root",
      customError("AtomicFlowManager", "ProofSettlementLayerInteropRootNotImported(uint256,uint256)")
    );

    // 3. In-time batch that is NOT the chain's last inside the settlement interop root: the batch-leaf
    //    path has a populated (non-empty-subtree) right sibling at level 0, so the last-batch check
    //    rejects it.
    const validSettlementRootBlock = 204;
    await ensureSettlementInteropRoot(chainA.provider, validSettlementRootBlock, deadline + 5);
    const notLastBatch = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: missingValue,
      l1Timestamp: deadline - 1,
      provesAgainstBeginRoot: false,
      slBlock: validSettlementRootBlock,
      batchLeafSiblings: [ethers.utils.id("populated-right-subtree")],
      batchLeafMask: 0, // left child at level 0 -> the sibling above must be the empty-subtree hash
    });
    await expectRevert(
      () => managerA.callStatic.authorizeRefund(flow, missingIdx, proofTuple(notLastBatch)),
      "in-time batch not last in root",
      customError("AtomicFlowManager", "ProofNotLastBatchInRoot(uint256,bytes32)")
    );
  });
});
