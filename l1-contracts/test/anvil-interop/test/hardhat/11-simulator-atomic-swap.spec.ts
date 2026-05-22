/**
 * End-to-end Simulator test exercising real cross-chain asset movement gated by
 * flow finality, across three chains: A → B (swap) → C.
 *
 *   Chain A           Chain B (swap pool)              Chain C
 *   ───────           ───────────────────              ───────
 *   user has aTokens; pool has bTokens reserves;       recipient has nothing.
 *
 *   The atomic flow:
 *     A's user locks X aTokens, dispatches a bundle to B that bridges them to
 *     the pool's address on B. The pool simultaneously locks Y bTokens
 *     (Y = quote(X)) and dispatches a bundle to C that bridges them to the
 *     recipient on C. Both legs gate on the same flow id, so either both
 *     happen or neither.
 *
 *   ┌────────────────────────┐   ┌────────────────────────┐   ┌──────────────────────┐
 *   │      Chain A           │   │     Chain B (pool)     │   │      Chain C         │
 *   │ user: X aTokens        │   │ pool: Y bTokens        │   │ recipient: 0         │
 *   │ escrow.lock(           │   │ escrow.lock(           │   │ register flow        │
 *   │   X aTokens,           │   │   Y bTokens,           │   │                      │
 *   │   bridge→B[pool])      │   │   bridge→C[recipient]) │   │                      │
 *   │ registerFlow           │   │ registerFlow           │   │                      │
 *   └─────┬──────────────────┘   └────────────┬───────────┘   └────────┬─────────────┘
 *         │                                   │                        │
 *         ↓ (1) lock on all chains   ↓        ↓                        ↓
 *         ─── (2) callStatic.simulate everywhere → predicted hashes ───
 *         B attaches A's predicted hash, C attaches B's predicted hash
 *         ─── (3) on-chain simulate everywhere → durable sim logs ─────
 *         A.recordFinalitySignal (4) ──peer logs B,C── verifies linking,
 *         flips A→Finalized, fans L2→L1 finality dispatches to B and C.
 *         ─── (5) execute on all chains ───────────────────────────────
 *         A: dispatchToInteropCenter (real) → A's bundle leaves
 *         B: finalizeAndExecute (consume A's bundle) → aTokens land at pool
 *         B: dispatchToInteropCenter (real) → B's bundle leaves
 *         C: finalizeAndExecute (consume B's bundle) → bTokens land at recipient
 *
 * Coverage:
 *   - Three-chain flow with two outbound bundles (A→B and B→C) — exercises the
 *     "one bundle per chain" rule and graph closure across {A, B, C}.
 *   - Real cross-chain asset movement on both legs via AssetRouter indirect calls.
 *   - Atomicity gate on each receiving chain: bundle execution requires the
 *     local Simulator to have the bundle attached AND the flow finalized.
 *   - Off-chain dry-run via `callStatic.simulate` capturing predicted hashes.
 *   - `recordFinalitySignal` auto-finalizes the source and dispatches finality
 *     notifications to all peer chains in a single tx.
 */

import { expect } from "chai";
import { BigNumber, Contract, ContractFactory, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain, buildMockInteropProof } from "../../src/core/utils";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_FLOW_ASSET_ESCROW_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_SIMULATOR_ADDR,
} from "../../src/core/const";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import { encodeEvmAddress, encodeEvmChain } from "../../src/helpers/erc7930";
import { encodeNtvAssetId, encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "../../src/core/data-encoding";
import {
  executionAddressAttr,
  indirectCallAttr,
  interopCallValueAttr,
} from "../../src/helpers/interop-helpers";
import { deploySimulatorStack, factValue, findLowLeafIndex, loadProof } from "../../src/helpers/simulator-helpers";

const TEST_TOKEN_DECIMALS = 18;

enum FlowState {
  None = 0,
  Initiated = 1,
  Finalized = 2,
  Reverted = 3,
}

type Chain = {
  chainId: number;
  rpcUrl: string;
  provider: ethers.providers.JsonRpcProvider;
  user: Wallet;
  simulator: Contract;
  recorder: Contract;
  escrow: Contract;
  testToken: Contract;
  ntv: Contract;
};

type Dispatch = {
  destinationChainId: string;
  callStarters: Array<{ to: string; data: string; callAttributes: string[] }>;
  bundleAttributes: string[];
};

describe("11 - Simulator three-chain atomic flow A → B (swap) → C", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let chainA: Chain;
  let chainB: Chain;
  let chainC: Chain;

  let pool: Contract;
  let recipient: string;

  const aAmount = ethers.utils.parseUnits("100", TEST_TOKEN_DECIMALS);
  // The swap pool keeps a generous bToken reserve seeded once in `before`.
  const bAmount = aAmount; // 1:1 swap for simplicity

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const gwSettledIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledIds.length < 3) throw new Error("Need at least three gwSettled chains for A/B/C");
    const [aId, bId, cId] = gwSettledIds;
    [chainA, chainB, chainC] = await Promise.all([
      buildChain(state, aId),
      buildChain(state, bId),
      buildChain(state, cId),
    ]);

    recipient = Wallet.createRandom().address;

    // Register the source-side tokens in their NTV so the AssetRouter can resolve assetId
    // when bridging. NTV registration is one-time per token; idempotent.
    await ensureRegistered(chainA);
    await ensureRegistered(chainB);

    // Deploy the swap pool on chain B and seed it with bTokens.
    const factory = new ContractFactory(getAbi("AtomicFlowSwap"), getCreationBytecode("AtomicFlowSwap"), chainB.user);
    const deployed = await factory.deploy(chainB.testToken.address);
    await deployed.deployed();
    pool = new Contract(deployed.address, getAbi("AtomicFlowSwap"), chainB.user);
    await (await chainB.testToken.mint(pool.address, bAmount.mul(8))).wait();
  });

  it("five-phase A→B(swap)→C: lock → simulate offchain → simulate onchain → finalize source → execute everywhere", async () => {
    const flowId = ethers.utils.id(`flow.atomic.swap.${Date.now()}`);
    const deadline = Math.floor(Date.now() / 1000) + 3600;

    // ─── Build the per-chain bridge dispatches ─────────────────────────────────────────
    // A → B: bridges aAmount aTokens to the pool's address on B AND fires the pool's
    // ERC-7786 `receiveMessage` callback as the bundle's second call. The callback's
    // payload is the flow id; the pool then dispatches its own outbound bundle atomically
    // (same tx as the inbound bundle execution).
    const aAssetId = encodeNtvAssetId(chainA.chainId, chainA.testToken.address);
    const poolCallbackPayload = ethers.utils.defaultAbiCoder.encode(["bytes32"], [flowId]);
    const aDispatch: Dispatch = buildBridgeDispatch({
      destinationChainId: chainB.chainId,
      assetId: aAssetId,
      amount: aAmount,
      recipient: pool.address,
      sourceTokenAddress: chainA.testToken.address,
      followupCall: { to: pool.address, data: poolCallbackPayload },
    });
    // B → C: bridges bAmount bTokens to the test recipient on C. No followup — C is
    // receive-only and has no further outbound bundle.
    const bAssetId = encodeNtvAssetId(chainB.chainId, chainB.testToken.address);
    const bDispatch: Dispatch = buildBridgeDispatch({
      destinationChainId: chainC.chainId,
      assetId: bAssetId,
      amount: bAmount,
      recipient,
      sourceTokenAddress: chainB.testToken.address,
    });

    // ─── PHASE 1 ── lock on all chains ─────────────────────────────────────────────────
    // A: user locks aTokens with dispatch → B; user registers the flow on A's Simulator.
    // B: pool locks bTokens with dispatch → C; user registers the flow on B's Simulator.
    //    The pool only handles asset escrow; the user (same default Anvil address on every
    //    chain) is the registrar everywhere so it can call `simulate` later.
    // C: receive-only — user just registers the flow.
    await (await chainA.testToken.connect(chainA.user).approve(chainA.escrow.address, aAmount)).wait();

    const userABefore: BigNumber = await chainA.testToken.balanceOf(chainA.user.address);
    const poolBBefore: BigNumber = await chainB.testToken.balanceOf(pool.address);

    await Promise.all([
      (
        await (chainA.escrow.connect(chainA.user) as Contract).lock(
          flowId,
          [{ beneficiary: chainA.user.address, token: chainA.testToken.address, amount: aAmount }],
          aDispatch
        )
      ).wait(),
      (await (chainA.simulator.connect(chainA.user) as Contract).registerFlow(flowId, deadline)).wait(),
      (await (pool.connect(chainB.user) as Contract).commitSwap(flowId, bAmount, bDispatch)).wait(),
      (await (chainB.simulator.connect(chainB.user) as Contract).registerFlow(flowId, deadline)).wait(),
      (await (chainC.simulator.connect(chainC.user) as Contract).registerFlow(flowId, deadline)).wait(),
    ]);

    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal(aAmount.toString());
    expect((await chainB.testToken.balanceOf(chainB.escrow.address)).toString()).to.equal(bAmount.toString());
    expect((await chainA.simulator.flows(flowId)).state).to.equal(FlowState.Initiated);
    expect((await chainB.simulator.flows(flowId)).state).to.equal(FlowState.Initiated);
    expect((await chainC.simulator.flows(flowId)).state).to.equal(FlowState.Initiated);

    // ─── PHASE 2 ── simulate offchain on all chains (sequential) ───────────────────────
    // Chains are causally ordered: each downstream chain depends on the previous chain's
    // predicted bundle bytes (so its plan can mock-apply the inbound bundle as a step) AND
    // hash (so its atomicity gate resolves correctly when the bundle lands). Attach must
    // happen while the flow is `Initiated`, so we cascade A → B → C.
    const mockProof = buildMockInteropProof(chainA.chainId);
    const aPlanSteps = [
      {
        target: chainA.escrow.address,
        data: chainA.escrow.interface.encodeFunctionData("dispatchToInteropCenter", [flowId]),
      },
    ];

    // 2.A: A simulates offchain → captures A's bundle hash + bytes. A has no inbound
    // bundles (it's the source of the flow), so the attach list is empty.
    const [aPredictedHashes, aPredictedBytes] = await (chainA.simulator.connect(chainA.user) as Contract).callStatic.simulate(
      flowId,
      aPlanSteps,
      [],
      []
    );
    expect(aPredictedHashes.length).to.equal(1, "A should produce one outbound bundle hash");
    expect(aPredictedBytes.length).to.equal(1, "A should produce matching bundle bytes");
    const aBundleHash: string = aPredictedHashes[0];
    const aBundleBytes: string = aPredictedBytes[0];

    // 2.B: B simulates offchain. Its plan is a single step — `simulateApplyBundle` runs
    // A's bundle, whose second call invokes the pool's `receiveMessage`. The pool then
    // calls `escrow.dispatchToInteropCenter`, which emits B's outbound bundle (captured
    // via auto-record). All state changes inside runPlan are rolled back, so this is
    // purely predictive: aTokens-mint + bTokens-bridge are simulated atomically. The
    // `[aBundleHash]` attach binds A's bundle to this flow on B's Simulator (durable,
    // outside the runPlan revert) so destination-side `requireBundleFinalized` works.
    const bPlanSteps = [
      {
        target: chainB.escrow.address,
        data: chainB.escrow.interface.encodeFunctionData("simulateApplyBundle", [aBundleBytes, mockProof]),
      },
    ];
    const [bPredictedHashes, bPredictedBytes] = await (chainB.simulator.connect(chainB.user) as Contract).callStatic.simulate(
      flowId,
      bPlanSteps,
      [],
      [aBundleHash]
    );
    expect(bPredictedHashes.length).to.equal(1, "B should produce one outbound bundle hash");
    const bBundleHash: string = bPredictedHashes[0];
    const bBundleBytes: string = bPredictedBytes[0];

    // 2.C: C simulates offchain. Same pattern as B — single step mock-applies B's bundle
    // (no outbound dispatch, C is end of chain). Attach binds B's bundle to this flow.
    const cPlanSteps = [
      {
        target: chainC.escrow.address,
        data: chainC.escrow.interface.encodeFunctionData("simulateApplyBundle", [bBundleBytes, mockProof]),
      },
    ];
    const [cPredictedHashes] = await (chainC.simulator.connect(chainC.user) as Contract).callStatic.simulate(
      flowId,
      cPlanSteps,
      [],
      [bBundleHash]
    );
    expect(cPredictedHashes.length).to.equal(0, "C is receive-only — no outbound bundle");

    // ─── PHASE 3 ── simulate on chain ──────────────────────────────────────────────────
    // Same plans + inbound-attach lists as phase 2; the on-chain commit lands the sim
    // logs in storage and on L1, and persists the bundle→flow attachments (which were
    // computed-but-discarded during the callStatic dry-runs).
    await Promise.all([
      (await (chainA.simulator.connect(chainA.user) as Contract).simulate(flowId, aPlanSteps, [], [])).wait(),
      (
        await (chainB.simulator.connect(chainB.user) as Contract).simulate(flowId, bPlanSteps, [], [aBundleHash])
      ).wait(),
      (
        await (chainC.simulator.connect(chainC.user) as Contract).simulate(flowId, cPlanSteps, [], [bBundleHash])
      ).wait(),
    ]);

    expect((await chainA.simulator.simulatedBundleHashAt(flowId, 0))).to.equal(aBundleHash);
    expect((await chainB.simulator.simulatedBundleHashAt(flowId, 0))).to.equal(bBundleHash);

    // ─── PHASE 4 ── finalize on the source chain (emits the finality log) ──────────────
    // A is the source. Its `recordFinalitySignal` verifies linking against B's and C's
    // peer sim logs, records the IMT fact, flips A's flow to Finalized, and emits one
    // L2->L1 finality dispatch per peer.
    const peerLogs = [
      buildEmptyPeerSimLog(chainB.chainId, flowId, [bBundleHash], [chainC.chainId]),
      buildEmptyPeerSimLog(chainC.chainId, flowId, [], []),
    ];
    const factVal = factValue(L2_SIMULATOR_ADDR, flowId);
    const lowLeafIndex = await findLowLeafIndex(chainA.recorder, factVal);
    await (
      await (chainA.simulator.connect(chainA.user) as Contract).recordFinalitySignal(
        flowId,
        lowLeafIndex,
        peerLogs
      )
    ).wait();
    expect((await chainA.simulator.flows(flowId)).state).to.equal(FlowState.Finalized);

    // ─── PHASE 5 ── execute on all chains ──────────────────────────────────────────────
    // Snapshot the IMT proof now (it doesn't change after recordFinalitySignal).
    const aRoot: string = await chainA.recorder.imtRoot();
    const newLeafIndex = (await chainA.recorder.imtIndexOf(factVal)).toNumber();
    const { leaf, proof } = await loadProof(chainA.recorder, newLeafIndex);
    const interopCenterA = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), chainA.user);
    const interopCenterB = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), chainB.user);

    // Step 5a: A dispatches its real bundle (aTokens leave A's escrow → bridge to B).
    const aDispatchReceipt = await (
      await (chainA.escrow.connect(chainA.user) as Contract).dispatchToInteropCenter(flowId)
    ).wait();
    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal("0");
    expect((await chainA.testToken.balanceOf(chainA.user.address)).toString()).to.equal(
      userABefore.sub(aAmount).toString()
    );
    const aBundle = extractInteropBundle(aDispatchReceipt, interopCenterA);
    expect(aBundle.bundleHash).to.equal(aBundleHash);
    const aBundleData = ethers.utils.defaultAbiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [aBundle.interopBundle]);

    // Step 5b: B finalizes via A's IMT proof and atomically executes A's bundle in one
    // tx. A's bundle's first call is `AssetRouter.finalizeDeposit` (mints aTokens to the
    // pool); its second call is `pool.receiveMessage`, which immediately dispatches B's
    // outbound bundle through the escrow. So `finalizeAndExecute` triggers the entire B
    // leg — flip state to Finalized, mint inbound aTokens, fire pool callback, send
    // outbound bundle to C — atomically. There is no observable state where the pool has
    // parted with bTokens but hasn't yet received aTokens (or vice-versa).
    const bundleVaultB = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), chainB.provider);
    const aOnBBefore = await balanceOf(chainB.provider, await bundleVaultB.tokenAddress(aAssetId), pool.address);
    const bReceipt = await (
      await (chainB.escrow.connect(chainB.user) as Contract).finalizeAndExecute(
        flowId,
        aRoot,
        leaf,
        newLeafIndex,
        proof,
        aBundleData,
        mockProof
      )
    ).wait();
    expect((await chainB.simulator.flows(flowId)).state).to.equal(FlowState.Finalized);
    expect((await chainB.testToken.balanceOf(chainB.escrow.address)).toString()).to.equal("0");
    expect((await chainB.testToken.balanceOf(pool.address)).toString()).to.equal(
      poolBBefore.sub(bAmount).toString()
    );
    const aOnBAfter = await balanceOf(chainB.provider, await bundleVaultB.tokenAddress(aAssetId), pool.address);
    expect(aOnBAfter.sub(aOnBBefore).toString()).to.equal(
      aAmount.toString(),
      "pool on chain B should have received the bridged aTokens"
    );

    // The same tx emitted B's outbound bundle (via the pool callback → escrow dispatch).
    const bBundle = extractInteropBundle(bReceipt, interopCenterB);
    expect(bBundle.bundleHash).to.equal(bBundleHash);
    const bBundleData = ethers.utils.defaultAbiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [bBundle.interopBundle]);

    // Step 5d: C finalizes via A's IMT proof and atomically executes B's bundle. The
    // bundle's AssetRouter call mints the bridged bTokens to the recipient on C.
    const bundleVaultC = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), chainC.provider);
    const bOnCBefore = await balanceOf(chainC.provider, await bundleVaultC.tokenAddress(bAssetId), recipient);
    await (
      await (chainC.escrow.connect(chainC.user) as Contract).finalizeAndExecute(
        flowId,
        aRoot,
        leaf,
        newLeafIndex,
        proof,
        bBundleData,
        mockProof
      )
    ).wait();
    expect((await chainC.simulator.flows(flowId)).state).to.equal(FlowState.Finalized);
    const bOnCAfter = await balanceOf(chainC.provider, await bundleVaultC.tokenAddress(bAssetId), recipient);
    expect(bOnCAfter.sub(bOnCBefore).toString()).to.equal(
      bAmount.toString(),
      "recipient on chain C should have received the bridged bTokens from the swap pool"
    );
  });
});

function buildBridgeDispatch(args: {
  destinationChainId: number;
  assetId: string;
  amount: BigNumber;
  recipient: string;
  sourceTokenAddress: string;
  /** Optional second call appended to the bundle (e.g. a pool callback that triggers the
   *  destination chain's own outbound dispatch atomically with the inbound bundle). */
  followupCall?: { to: string; data: string };
}): Dispatch {
  const transferData = encodeBridgeBurnData(args.amount, args.recipient, args.sourceTokenAddress);
  const depositData = encodeAssetRouterBridgehubDepositData(args.assetId, transferData);
  const callStarters: Array<{ to: string; data: string; callAttributes: string[] }> = [
    {
      to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
      data: depositData,
      callAttributes: [indirectCallAttr(), interopCallValueAttr(BigNumber.from(0))],
    },
  ];
  if (args.followupCall) {
    callStarters.push({
      to: encodeEvmAddress(args.followupCall.to),
      data: args.followupCall.data,
      callAttributes: [interopCallValueAttr(BigNumber.from(0))],
    });
  }
  return {
    destinationChainId: encodeEvmChain(args.destinationChainId),
    callStarters,
    bundleAttributes: [executionAddressAttr(L2_FLOW_ASSET_ESCROW_ADDR)],
  };
}

async function ensureRegistered(c: Chain): Promise<void> {
  const registered = await c.ntv.assetId(c.testToken.address);
  if (registered === ethers.constants.HashZero) {
    await (await (c.ntv.connect(c.user) as Contract).registerToken(c.testToken.address)).wait();
  }
}

async function balanceOf(
  provider: ethers.providers.JsonRpcProvider,
  tokenAddr: string,
  who: string
): Promise<BigNumber> {
  if (tokenAddr === ethers.constants.AddressZero) return BigNumber.from(0);
  return new Contract(tokenAddr, getAbi("TestnetERC20Token"), provider).balanceOf(who);
}

function extractInteropBundle(
  receipt: ethers.providers.TransactionReceipt,
  interopCenter: Contract
): { interopBundle: unknown; bundleHash: string } {
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenter.interface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed.name === "InteropBundleSent") {
        return {
          interopBundle: parsed.args["interopBundle"],
          bundleHash: parsed.args["interopBundleHash"],
        };
      }
    } catch {
      // not an InteropCenter event
    }
  }
  throw new Error("InteropBundleSent event not found in dispatch receipt");
}

async function buildChain(state: ReturnType<DeploymentRunner["loadState"]>, chainId: number): Promise<Chain> {
  const l2Chain = getL2Chain(state.chains!, chainId);
  const provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
  const stack = await deploySimulatorStack(provider);
  const tokenAddress = state.testTokens![chainId];
  if (!tokenAddress) throw new Error(`No test token registered for chain ${chainId}`);
  const user = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
  const testToken = new Contract(tokenAddress, getAbi("TestnetERC20Token"), user);
  const ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), user);
  return {
    chainId,
    rpcUrl: l2Chain.rpcUrl,
    provider,
    user,
    simulator: stack.simulator,
    recorder: stack.recorder,
    escrow: stack.escrow,
    testToken,
    ntv,
  };
}

const SIMULATION_LOG_TAG = ethers.utils
  .keccak256(ethers.utils.toUtf8Bytes("Simulator.simulationLog.v1"))
  .slice(0, 10);

/// PeerSimLog matching what `peer.simulate(flowId, plan, [])` would emit. The framework
/// uses `MockL2MessageVerification` which accepts any inclusion proof, so we pass dummies.
function buildEmptyPeerSimLog(peerChainId: number, flowId: string, bundleHashes: string[], destChainIds: number[]) {
  const data = ethers.utils.defaultAbiCoder.encode(
    ["bytes4", "bytes32", "bytes32[]", "uint256[]"],
    [SIMULATION_LOG_TAG, flowId, bundleHashes, destChainIds]
  );
  return {
    chainId: peerChainId,
    blockOrBatchNumber: 1,
    message: {
      txNumberInBatch: 0,
      sender: L2_SIMULATOR_ADDR,
      data,
    },
    messageIndex: 0,
    merkleProof: [ethers.constants.HashZero],
  };
}
