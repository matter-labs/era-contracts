/**
 * End-to-end test for the L1-free atomic-interop stack (IMT engine B).
 *
 * Topology (two GW-settled chains):
 *   Chain A: depositor (anvil acct #0) sends aAmount of testTokenA -> recipient on B.
 *   Chain B: depositor (anvil acct #0) sends bAmount of testTokenB -> recipient on A.
 *
 * The flow is L1-free: each source `commitSend` burns/locks the depositor's tokens via the AR/NTV and
 * inserts the leg's commit value into the chain's {L2InteropCommitmentTree} (an Indexed Merkle Tree,
 * engine B). The destination authorizes by proving IMT inclusion of the remote leg against the
 * source chain's IMT root (authenticated cross-chain via the `(root, timestamp)` L2->L1 message;
 * that authentication is mocked to `true` on the anvil harness by {MockL2MessageVerification}, so the
 * IMT membership / low-nullifier layer and the `rootTimestamp` deadline check are what is exercised).
 *
 * The off-chain proof builders (src/helpers/imt-engine-lib.ts) reproduce the on-chain IMT root /
 * Merkle paths from the live leaf set; `buildInclusionProof` / `buildNonInclusionProof` assert the
 * reconstructed root equals `tree.root()` before emitting a proof, so a passing test also confirms
 * the off-chain engine matches the on-chain one.
 *
 * Verifies:
 *   - HAPPY PATH: commitSend (source burn + IMT insert) on both legs -> authorize (inclusion proof,
 *     rootTimestamp <= deadline) -> execute (destination mint). Recipients receive the bridged token;
 *     source legs stay terminal at Committed; destination legs end Executed.
 *   - TIMEOUT PATH: one leg commits, the other never does -> after the deadline, a single-root
 *     non-inclusion proof (rootTimestamp > deadline) authorizes a refund -> claimRefund recovers the
 *     depositor's tokens; the source leg ends Reverted.
 */

import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_NATIVE_TOKEN_VAULT_ADDR } from "../../src/core/const";
import type { AtomicStack } from "../../src/helpers/imt-atomic-deployer";
import { deployAtomicStack } from "../../src/helpers/imt-atomic-deployer";
import { encodeErc20Data } from "../../src/helpers/dummy-flow-helpers";
import type { SendSpec } from "../../src/helpers/imt-engine-lib";
import {
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  computeFlowId,
  inclusionProofTuple,
  lowNullifierIndexFor,
  nonInclusionProofTuple,
  reconstructChainImt,
  specHashOf,
  specTuple,
} from "../../src/helpers/imt-engine-lib";

const TEST_TOKEN_DECIMALS = 18;

enum SpecState {
  Unset = 0,
  Committed = 1,
  Executable = 2,
  Executed = 3,
  Revertable = 4,
  Reverted = 5,
}

type ChainCtx = {
  chainId: number;
  rpcUrl: string;
  provider: ethers.providers.JsonRpcProvider;
  user: Wallet;
  testToken: Contract;
  stack: AtomicStack;
};

// NTV.tokenAddress(assetId) — to resolve the bridged shim deployed on the destination.
const NTV_TOKEN_ADDRESS_ABI = ["function tokenAddress(bytes32 assetId) view returns (address)"];
const ERC20_BALANCE_ABI = ["function balanceOf(address) view returns (uint256)"];

type ParsedEscrowLog = { name: string; args: ethers.utils.Result } | undefined;

/** assetId = keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken)). */
function ntvAssetId(originChainId: number, originToken: string): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["uint256", "address", "address"],
      [originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken]
    )
  );
}

/** Sort two specs by specHash ascending and return (specs, specHashes) — matches escrow flowId order. */
function sortedSpecs(a: SendSpec, b: SendSpec): { specs: SendSpec[]; hashes: string[] } {
  const ha = specHashOf(a);
  const hb = specHashOf(b);
  if (BigNumber.from(ha).lt(BigNumber.from(hb))) {
    return { specs: [a, b], hashes: [ha, hb] };
  }
  return { specs: [b, a], hashes: [hb, ha] };
}

/** Current chain timestamp on a provider. */
async function chainNow(provider: ethers.providers.JsonRpcProvider): Promise<number> {
  return (await provider.getBlock("latest")).timestamp;
}

describe("13 - IMT atomic swap A <-> B (L1-free)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let chainA: ChainCtx;
  let chainB: ChainCtx;

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
    [chainA, chainB] = ctxs;
  });

  it("happy path: commit -> authorize -> execute mints both legs and leaves source Committed", async () => {
    const user = chainA.user.address; // anvil acct #0, the depositor on both chains
    const now = Math.max(await chainNow(chainA.provider), await chainNow(chainB.provider));
    const deadline = now + 3600;

    // AB: origin A, destination B. BA: origin B, destination A.
    // `erc20Data` carries the origin token's (chainId, name, symbol, decimals) so the destination NTV
    // can deploy a bridged shim on first arrival (the L1-free `execute` mint reads it directly).
    const ab: SendSpec = {
      destChainId: chainB.chainId,
      recipient: user,
      originChainId: chainA.chainId,
      originToken: chainA.testToken.address,
      amount: aAmount,
      erc20Data: encodeErc20Data(chainA.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS),
      depositor: user,
    };
    const ba: SendSpec = {
      destChainId: chainA.chainId,
      recipient: user,
      originChainId: chainB.chainId,
      originToken: chainB.testToken.address,
      amount: bAmount,
      erc20Data: encodeErc20Data(chainB.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS),
      depositor: user,
    };

    const { specs, hashes } = sortedSpecs(ab, ba);
    const chainIds = [chainA.chainId, chainB.chainId].sort((x, y) => x - y);
    const flowId = computeFlowId(hashes, chainIds, deadline);
    const hAB = specHashOf(ab);
    const hBA = specHashOf(ba);

    // ── PHASE 1: commitSend on each source ────────────────────────────────────────────────
    const aBefore: BigNumber = await chainA.testToken.balanceOf(user);
    const bBefore: BigNumber = await chainB.testToken.balanceOf(user);

    await (await chainA.testToken.connect(chainA.user).approve(chainA.stack.escrow.address, aAmount)).wait();
    await (await chainB.testToken.connect(chainB.user).approve(chainB.stack.escrow.address, bAmount)).wait();

    const abValue = commitValue(flowId, hAB);
    const baValue = commitValue(flowId, hBA);
    const abLowNull = await lowNullifierIndexFor(chainA.stack.tree, abValue);
    const baLowNull = await lowNullifierIndexFor(chainB.stack.tree, baValue);

    const abCommit = await (await chainA.stack.escrow.commitSend(flowId, specTuple(ab), abLowNull)).wait();
    const baCommit = await (await chainB.stack.escrow.commitSend(flowId, specTuple(ba), baLowNull)).wait();

    // Source legs are Committed; tokens left the depositor and were locked via AR/NTV.
    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Committed);
    expect(await chainB.stack.escrow.specState(flowId, hBA)).to.equal(SpecState.Committed);
    expect((await chainA.testToken.balanceOf(user)).toString()).to.equal(aBefore.sub(aAmount).toString());
    expect((await chainB.testToken.balanceOf(user)).toString()).to.equal(bBefore.sub(bAmount).toString());

    // FlowCommitted emitted with the assigned IMT leaf index.
    const abCommitted = abCommit.logs
      .map((l: ethers.providers.Log) => parseEscrowLog(chainA.stack.escrow, l))
      .find((p: ParsedEscrowLog) => p?.name === "FlowCommitted");
    expect(abCommitted, "FlowCommitted on A").to.not.be.undefined;
    expect(abCommitted!.args.flowId).to.equal(flowId);
    expect(abCommitted!.args.specHash).to.equal(hAB);
    expect(baCommit, "BA commit receipt").to.not.be.undefined;

    // The commit values are now present in their origin chains' IMTs.
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
    // Off-chain engine root must match the on-chain root (engine B fidelity check).
    expect(imtA.root.toLowerCase()).to.equal((await chainA.stack.tree.root()).toLowerCase());
    expect(imtB.root.toLowerCase()).to.equal((await chainB.stack.tree.root()).toLowerCase());

    // ── PHASE 2: authorize on each destination ────────────────────────────────────────────
    // Authorizing on B verifies BA via local state (B is its origin) and AB via an inclusion proof
    // built from A's tree (rootTimestamp <= deadline). Symmetric on A.
    const abProofForB = await buildInclusionProof({
      l2Tree: chainA.stack.tree,
      chainId: chainA.chainId,
      value: abValue,
      rootTimestamp: deadline,
    });
    const baProofForA = await buildInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      rootTimestamp: deadline,
    });

    const authB = await (
      await chainB.stack.escrow.authorize(flowId, specs.map(specTuple), chainIds, deadline, [
        inclusionProofTuple(abProofForB),
      ])
    ).wait();
    const authA = await (
      await chainA.stack.escrow.authorize(flowId, specs.map(specTuple), chainIds, deadline, [
        inclusionProofTuple(baProofForA),
      ])
    ).wait();

    // Destination legs now Executable; source legs still Committed.
    expect(await chainB.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Executable, "AB executable on B");
    expect(await chainA.stack.escrow.specState(flowId, hBA)).to.equal(SpecState.Executable, "BA executable on A");
    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Committed, "AB stays Committed on A");
    expect(await chainB.stack.escrow.specState(flowId, hBA)).to.equal(SpecState.Committed, "BA stays Committed on B");

    // FlowAuthorized emitted for each destination leg.
    expect(
      authB.logs
        .map((l: ethers.providers.Log) => parseEscrowLog(chainB.stack.escrow, l))
        .some((p: ParsedEscrowLog) => p?.name === "FlowAuthorized" && p.args.specHash === hAB),
      "FlowAuthorized(hAB) on B"
    ).to.be.true;
    expect(
      authA.logs
        .map((l: ethers.providers.Log) => parseEscrowLog(chainA.stack.escrow, l))
        .some((p: ParsedEscrowLog) => p?.name === "FlowAuthorized" && p.args.specHash === hBA),
      "FlowAuthorized(hBA) on A"
    ).to.be.true;

    // ── PHASE 3: execute the destination legs ──────────────────────────────────────────────
    await (await chainB.stack.escrow.execute(flowId, specTuple(ab))).wait();
    await (await chainA.stack.escrow.execute(flowId, specTuple(ba))).wait();

    expect(await chainB.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Executed, "AB executed on B");
    expect(await chainA.stack.escrow.specState(flowId, hBA)).to.equal(SpecState.Executed, "BA executed on A");
    // No source execute: source legs remain Committed (terminal on the happy path).
    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Committed, "no source execute on A");
    expect(await chainB.stack.escrow.specState(flowId, hBA)).to.equal(SpecState.Committed, "no source execute on B");

    // ── Destination mint assertions ────────────────────────────────────────────────────────
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
    // Use a short deadline relative to chain time; the missing leg's non-inclusion proof carries a
    // post-deadline root snapshot timestamp.
    const now = Math.max(await chainNow(chainA.provider), await chainNow(chainB.provider));
    const deadline = now + 60;

    // AB: origin A, dest B (this is the leg that DOES commit). BA: origin B, dest A (never commits).
    // Use distinct amounts/recipients from the happy-path flow so this is a fresh flowId.
    const refundRecipient = chainB.user.address; // distinct dest recipient, irrelevant for refund
    const ab: SendSpec = {
      destChainId: chainB.chainId,
      recipient: refundRecipient,
      originChainId: chainA.chainId,
      originToken: chainA.testToken.address,
      amount: ethers.utils.parseUnits("3", TEST_TOKEN_DECIMALS),
      erc20Data: encodeErc20Data(chainA.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS),
      depositor: user,
    };
    const ba: SendSpec = {
      destChainId: chainA.chainId,
      recipient: refundRecipient,
      originChainId: chainB.chainId,
      originToken: chainB.testToken.address,
      amount: ethers.utils.parseUnits("5", TEST_TOKEN_DECIMALS),
      erc20Data: encodeErc20Data(chainB.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS),
      depositor: user,
    };

    const { specs, hashes } = sortedSpecs(ab, ba);
    const chainIds = [chainA.chainId, chainB.chainId].sort((x, y) => x - y);
    const flowId = computeFlowId(hashes, chainIds, deadline);
    const hAB = specHashOf(ab);

    // ── Commit only the AB leg on A. B never commits BA. ─────────────────────────────────────
    const aBefore: BigNumber = await chainA.testToken.balanceOf(user);
    await (await chainA.testToken.connect(chainA.user).approve(chainA.stack.escrow.address, ab.amount)).wait();
    const abValue = commitValue(flowId, hAB);
    const abLowNull = await lowNullifierIndexFor(chainA.stack.tree, abValue);
    await (await chainA.stack.escrow.commitSend(flowId, specTuple(ab), abLowNull)).wait();

    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Committed, "AB committed on A");
    const aAfterCommit: BigNumber = await chainA.testToken.balanceOf(user);
    expect(aAfterCommit.toString()).to.equal(
      aBefore.sub(BigNumber.from(ab.amount)).toString(),
      "AB depositor locked tokens at commit"
    );

    // ── Advance past the deadline on both chains (timeout). ─────────────────────────────────
    for (const provider of [chainA.provider, chainB.provider]) {
      await provider.send("evm_setNextBlockTimestamp", [deadline + 120]);
      await provider.send("evm_mine", []);
    }

    // ── Build a single-root non-inclusion proof for the missing BA leg against B's IMT, with a
    //    post-deadline root timestamp (rootTimestamp > deadline). ─────────────────────────────
    const baValue = commitValue(flowId, specHashOf(ba));
    const nonIncl = await buildNonInclusionProof({
      l2Tree: chainB.stack.tree,
      chainId: chainB.chainId,
      value: baValue,
      rootTimestamp: deadline + 120,
    });
    const missingIdx = specs[0].originChainId === chainB.chainId ? 0 : 1;

    // ── authorizeRefund on A (A is AB's source) -> AB becomes Revertable. ───────────────────
    const refundAuth = await (
      await chainA.stack.escrow.authorizeRefund(
        flowId,
        specs.map(specTuple),
        chainIds,
        deadline,
        missingIdx,
        nonInclusionProofTuple(nonIncl)
      )
    ).wait();
    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Revertable, "AB revertable on A");
    expect(
      refundAuth.logs
        .map((l: ethers.providers.Log) => parseEscrowLog(chainA.stack.escrow, l))
        .some((p: ParsedEscrowLog) => p?.name === "FlowRefundAuthorized" && p.args.specHash === hAB),
      "FlowRefundAuthorized(hAB) on A"
    ).to.be.true;

    // ── claimRefund on A -> depositor recovers the locked tokens; state Reverted. ───────────
    const claim = await (await chainA.stack.escrow.claimRefund(flowId, specTuple(ab))).wait();
    expect(await chainA.stack.escrow.specState(flowId, hAB)).to.equal(SpecState.Reverted, "AB reverted on A");

    const aAfterRefund: BigNumber = await chainA.testToken.balanceOf(user);
    expect(aAfterRefund.toString()).to.equal(aBefore.toString(), "AB depositor fully recovered the locked tokens");

    expect(
      claim.logs
        .map((l: ethers.providers.Log) => parseEscrowLog(chainA.stack.escrow, l))
        .some(
          (p: ParsedEscrowLog) => p?.name === "FlowRefunded" && p.args.specHash === hAB && p.args.depositor === user
        ),
      "FlowRefunded(hAB, depositor) on A"
    ).to.be.true;
  });
});

/** Parse an escrow event log, returning {name, args} or undefined for non-escrow logs. */
function parseEscrowLog(escrow: Contract, log: ethers.providers.Log): ParsedEscrowLog {
  if (log.address.toLowerCase() !== escrow.address.toLowerCase()) return undefined;
  try {
    const parsed = escrow.interface.parseLog(log);
    return { name: parsed.name, args: parsed.args };
  } catch {
    return undefined;
  }
}
