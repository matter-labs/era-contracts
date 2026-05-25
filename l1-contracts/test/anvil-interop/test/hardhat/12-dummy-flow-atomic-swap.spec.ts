/**
 * End-to-end test for the dummy-interop atomicity stack. Mirrors the prior generic
 * Simulator test but uses the lock-and-send-on-finality model: each L2 emits one L2→L1
 * commit log carrying its declarative `SendSpec`, the L1 linker collects them and finalizes
 * the flow, and `executeFlow` dispatches one `Bridgehub.requestL2TransactionDirect` per
 * participating L2 that lands as `executeFromL1(flowId, inboundSpecs[])` on the chain's
 * escrow.
 *
 * Topology (three GW-settled chains):
 *   Chain A: user locks aAmount of testTokenA, dispatches → B (recipient = user on B).
 *   Chain B: user locks bAmount of testTokenB, dispatches → C (recipient = user on C).
 *   Chain C: receive-only.
 *
 * The "swap pool" abstraction is dropped here — both legs are bridge transfers initiated by
 * the same user. Verifies the basic A→B→C flow lifecycle plumbing; the atomic-on-arrival
 * pool callback can be layered on top later via SendSpec.followupTo.
 */

import { expect } from "chai";
import { BigNumber, Contract, ContractFactory, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain, extractAndRelayNewPriorityRequests } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY } from "../../src/core/const";
import {
  buildCommitProofFromReceipt,
  buildExecuteParams,
  buildSendSpec,
  deployL1FlowStack,
  deployL2EscrowsForChains,
  ExecuteParams,
  Participant,
} from "../../src/helpers/dummy-flow-helpers";

const TEST_TOKEN_DECIMALS = 18;
const GAS_PRICE = 50_000_000_000n; // 50 gwei

enum FlowState {
  None = 0,
  Initiated = 1,
  Finalized = 2,
  Reverted = 3,
}

type ChainCtx = {
  chainId: number;
  rpcUrl: string;
  provider: ethers.providers.JsonRpcProvider;
  user: Wallet;
  testToken: Contract;
  escrow: Contract;
};

describe("12 - Dummy Flow atomic A → B → C", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let chainA: ChainCtx;
  let chainB: ChainCtx;
  let chainC: ChainCtx;
  let linker: Contract;
  let l1Provider: ethers.providers.JsonRpcProvider;
  let l1Wallet: Wallet;
  let bridgehub: Contract;

  // Amounts:
  // - A → B: aAmount of A's test token, bridged to user on B.
  // - B → C: bAmount of B's test token, bridged to user on C.
  const aAmount = ethers.utils.parseUnits("10", TEST_TOKEN_DECIMALS);
  const bAmount = ethers.utils.parseUnits("7", TEST_TOKEN_DECIMALS);

  before(async () => {
    state = runner.loadState();
    if (!state.chains?.l1 || !state.chainAddresses || !state.l1Addresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const gwSettledIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledIds.length < 3) throw new Error("Need ≥3 gwSettled chains");
    const [aId, bId, cId] = gwSettledIds;

    l1Provider = new ethers.providers.JsonRpcProvider(state.chains.l1.rpcUrl);
    l1Wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    bridgehub = new Contract(state.l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);

    // Deploy linker on L1, escrows on each L2 chain (all wired to the same linker address).
    const deployed = await deployL1FlowStack(l1Provider, state.l1Addresses.bridgehub);
    linker = deployed.linker;

    const l2Triples = await Promise.all(
      [aId, bId, cId].map(async (chainId) => {
        const rpcUrl = getL2Chain(state.chains!, chainId).rpcUrl;
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        return { chainId, rpcUrl, provider };
      })
    );
    const escrows = await deployL2EscrowsForChains(
      l2Triples.map(({ chainId, provider }) => ({ chainId, provider })),
      linker.address
    );

    const ctxs = await Promise.all(
      l2Triples.map(async ({ chainId, rpcUrl, provider }) => {
        const user = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
        const tokenAddress = state.testTokens![chainId];
        if (!tokenAddress) throw new Error(`No test token registered for chain ${chainId}`);
        const testToken = new Contract(tokenAddress, getAbi("TestnetERC20Token"), user);
        return { chainId, rpcUrl, provider, user, testToken, escrow: escrows[chainId] };
      })
    );
    [chainA, chainB, chainC] = ctxs;
  });

  it("lock → record finality → executeFlow lands inbound mints on B and C", async () => {
    const flowId = ethers.utils.id(`dummy.flow.${Date.now()}`);
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const recipientUser = chainA.user.address; // same default Anvil account on every chain

    // ─── PHASE 1: registerFlow on L1 ──────────────────────────────────────────────────
    // Anyone can register; we use the same user wallet. Participating set is all three
    // chains; their escrow addresses are bound to the flow up-front so commit logs from
    // other addresses can't be smuggled in later.
    const participants: Participant[] = [
      { chainId: BigNumber.from(chainA.chainId), escrow: chainA.escrow.address },
      { chainId: BigNumber.from(chainB.chainId), escrow: chainB.escrow.address },
      { chainId: BigNumber.from(chainC.chainId), escrow: chainC.escrow.address },
    ];
    await (await linker.registerFlow(flowId, participants, deadline)).wait();
    expect(await linker.flowState(flowId)).to.equal(FlowState.Initiated);

    // ─── PHASE 2: commitSend on each sender (A and B) ─────────────────────────────────
    // Receive-only chains (C here) skip this step; the L1 linker will dispatch to them
    // anyway via executeFromL1 with their inbound list.
    const aSpec = buildSendSpec({
      destChainId: chainB.chainId,
      recipient: recipientUser,
      token: chainA.testToken.address,
      amount: aAmount,
    });
    const bSpec = buildSendSpec({
      destChainId: chainC.chainId,
      recipient: recipientUser,
      token: chainB.testToken.address,
      amount: bAmount,
    });

    const userABefore: BigNumber = await chainA.testToken.balanceOf(recipientUser);
    const userBBefore: BigNumber = await chainB.testToken.balanceOf(recipientUser);
    const userCBefore: BigNumber = await chainC.testToken.balanceOf(recipientUser);

    await (await chainA.testToken.connect(chainA.user).approve(chainA.escrow.address, aAmount)).wait();
    await (await chainB.testToken.connect(chainB.user).approve(chainB.escrow.address, bAmount)).wait();

    const aCommitReceipt = await (
      await (chainA.escrow.connect(chainA.user) as Contract).commitSend(flowId, aSpec)
    ).wait();
    const bCommitReceipt = await (
      await (chainB.escrow.connect(chainB.user) as Contract).commitSend(flowId, bSpec)
    ).wait();

    // Lock landed: A and B escrows now hold the user's tokens; user balance reduced.
    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal(aAmount.toString());
    expect((await chainB.testToken.balanceOf(chainB.escrow.address)).toString()).to.equal(bAmount.toString());
    expect((await chainA.testToken.balanceOf(recipientUser)).toString()).to.equal(userABefore.sub(aAmount).toString());
    expect((await chainB.testToken.balanceOf(recipientUser)).toString()).to.equal(userBBefore.sub(bAmount).toString());

    // ─── PHASE 3: recordFinalitySignal on L1 ──────────────────────────────────────────
    // Pull L2→L1 commit logs out of each commitSend receipt and submit them with mock
    // inclusion proofs (the L1 MockL2MessageVerification accepts anything). C didn't
    // commit, so it has no proof to submit.
    const aProof = buildCommitProofFromReceipt(chainA.chainId, aCommitReceipt, chainA.escrow.address);
    const bProof = buildCommitProofFromReceipt(chainB.chainId, bCommitReceipt, chainB.escrow.address);
    await (await linker.recordFinalitySignal(flowId, [aProof, bProof])).wait();
    expect(await linker.flowState(flowId)).to.equal(FlowState.Finalized);

    // ─── PHASE 4: executeFlow on L1 → dispatches to each L2 ───────────────────────────
    // ExecuteParams must align with participants in the order registerFlow recorded them.
    // For each chain, msg.value pays the L2 base-token mintValue (= baseCost). l2GasLimit
    // / pubdata defaults come from buildExecuteParams.
    const l2GasLimit = BigNumber.from(2_000_000);
    const l2GasPerPubdataByteLimit = BigNumber.from(800);
    const baseCosts = await Promise.all(
      participants.map((p) =>
        bridgehub.l2TransactionBaseCost(p.chainId, GAS_PRICE, l2GasLimit, l2GasPerPubdataByteLimit)
      )
    );
    const execParams: ExecuteParams[] = participants.map((_, i) =>
      buildExecuteParams(baseCosts[i], recipientUser, { l2GasLimit, l2GasPerPubdataByteLimit })
    );
    const totalMintValue = baseCosts.reduce((acc, b) => acc.add(b), BigNumber.from(0));

    const execReceipt = await (
      await linker.executeFlow(flowId, execParams, {
        value: totalMintValue,
        gasLimit: 10_000_000,
      })
    ).wait();

    // ─── PHASE 5: Relay each priority tx into its target L2 anvil ─────────────────────
    // The L1 receipt contains NewPriorityRequest events for the GW (per chain) and the
    // nested L2 diamonds. We iterate the participating set and let the resolved-path
    // helper handle the two-hop GW relay per chain.
    const gwChainId = state.chains!.config.find((c) => c.role === "gateway")!.chainId;
    const gwRpcUrl = getL2Chain(state.chains!, gwChainId).rpcUrl;
    for (const ctx of [chainA, chainB, chainC]) {
      await extractAndRelayNewPriorityRequests(
        execReceipt,
        {
          l1RpcUrl: state.chains!.l1!.rpcUrl,
          bridgehubAddr: state.l1Addresses!.bridgehub,
          chainId: ctx.chainId,
          chainRpcUrl: ctx.rpcUrl,
          gwRpcUrl,
        },
        (line) => console.log(line)
      );
    }

    // ─── Assertions: inbound transfers landed where expected ──────────────────────────
    //
    // NOTE on cross-chain token addresses: the SendSpec carries a single `token` address
    // that the destination escrow uses as the mint target. The dummy stack has no asset
    // registry — it relies on the deploy-test-tokens script using the same wallet at the
    // same nonce on every chain, so `testTokens[A] == testTokens[B] == testTokens[C]`.
    // A real bridge would resolve a chain-independent `assetId` to a per-chain token
    // address; that's the integration the user can layer on later.
    expect(chainA.testToken.address).to.equal(chainB.testToken.address);
    expect(chainB.testToken.address).to.equal(chainC.testToken.address);

    // A is a sender-only (no inbound) — its user balance stays at userABefore - aAmount,
    // and the escrow still holds aAmount (bridge custody, no burn in the dummy stack).
    expect((await chainA.testToken.balanceOf(recipientUser)).toString()).to.equal(userABefore.sub(aAmount).toString());
    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal(aAmount.toString());

    // B receives aAmount on the token (newly minted by B's escrow) AND is still down
    // bAmount of the same token from its own commitSend lock.
    const userOnB: BigNumber = await chainB.testToken.balanceOf(recipientUser);
    expect(userOnB.toString()).to.equal(
      userBBefore.sub(bAmount).add(aAmount).toString(),
      "B's user balance = before - bAmount(locked) + aAmount(minted inbound)"
    );

    // C receives bAmount (minted by C's escrow). C is pure receive-only.
    const userOnC: BigNumber = await chainC.testToken.balanceOf(recipientUser);
    expect(userOnC.toString()).to.equal(
      userCBefore.add(bAmount).toString(),
      "C's user balance increases by bAmount"
    );
  });
});
