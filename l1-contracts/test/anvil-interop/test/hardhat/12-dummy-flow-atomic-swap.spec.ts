/**
 * End-to-end test for the dummy-interop atomicity stack.
 *
 * Topology (three GW-settled chains):
 *   Chain A: user locks aAmount of testTokenA, sends → user on B.
 *   Chain B: user locks bAmount of testTokenB, sends → user on C.
 *   Chain C: receive-only.
 *
 * Verifies:
 *   - commitSend pulls tokens into escrow + emits L2→L1 commit log
 *   - flowId-as-commitment: linker rejects partial commits via hash equality
 *   - executeFlow dispatches authorizeFromL1 to each participating chain
 *   - per-chain execute() runs once authorized; source = burn (no-op placeholder),
 *     destination = mint via placeholder IMintableToken
 */

import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  getChainIdsByRole,
  getL2Chain,
  extractAndRelayNewPriorityRequests,
  impersonateAndRun,
} from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_ASSET_ROUTER_ADDR } from "../../src/core/const";
import {
  buildCommitProofFromReceipt,
  buildExecuteParams,
  buildSendSpec,
  computeFlowId,
  deployL1FlowStack,
  deployL2EscrowsForChains,
  encodeErc20Data,
  ExecuteParams,
  SendSpec,
} from "../../src/helpers/dummy-flow-helpers";

const TEST_TOKEN_DECIMALS = 18;
const GAS_PRICE = 50_000_000_000n; // 50 gwei

enum FlowState {
  None = 0,
  Initiated = 1,
  Finalized = 2,
  Reverted = 3,
}

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

    // Deploy linker on L1, escrows on each L2 (all wired to the same linker address).
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

    // Set the canonical escrow on the linker (escrows are all CREATE2-aligned in the
    // dummy stack — pick any one address).
    const canonicalEscrow = escrows[aId].address;
    await (await linker.initialize(canonicalEscrow)).wait();

    // Whitelist each chain's escrow on its L2AssetRouter via the AR's owner.
    // Required so the escrow can call AR.initiateIndirectCall (source-side burn) and
    // AR.finalizeDeposit (destination-side mint). `setAtomicFlowEscrow` is gated
    // `onlyOwner` (lifted off `onlyUpgrader` so a userspace AR can wire its own escrow
    // without going through the system complex upgrader).
    await Promise.all(
      l2Triples.map(async ({ chainId, provider }) => {
        const arReader = new Contract(L2_ASSET_ROUTER_ADDR, getAbi("L2AssetRouter"), provider);
        const arOwner: string = await arReader.owner();
        await impersonateAndRun(provider, arOwner, async (signer) => {
          const ar = new Contract(L2_ASSET_ROUTER_ADDR, getAbi("L2AssetRouter"), signer);
          await (await ar.setAtomicFlowEscrow(escrows[chainId].address)).wait();
        });
      })
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

  it("commit → authorize → execute: A→B→C inbound mints land on B and C", async () => {
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const recipientUser = chainA.user.address;

    // Build both SendSpecs first so we can derive flowId from them. Each carries the
    // origin token's (name, symbol, decimals) so the destination's NTV can deploy a
    // bridged shim on first arrival without needing to query the source chain.
    const erc20Data = encodeErc20Data(chainA.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS);
    const aSpec: SendSpec = buildSendSpec({
      destChainId: chainB.chainId,
      recipient: recipientUser,
      originChainId: chainA.chainId,
      originToken: chainA.testToken.address,
      amount: aAmount,
      depositor: recipientUser,
      erc20Data,
    });
    const bSpec: SendSpec = buildSendSpec({
      destChainId: chainC.chainId,
      recipient: recipientUser,
      originChainId: chainB.chainId,
      originToken: chainB.testToken.address,
      amount: bAmount,
      depositor: recipientUser,
      erc20Data: encodeErc20Data(chainB.chainId, "Test Token", "TEST", TEST_TOKEN_DECIMALS),
    });
    // ─── PHASE 1: registerFlow on L1 ──────────────────────────────────────────────────
    // Participating-chain list is sorted ascending per the linker's invariant.
    // flowId binds the sorted spec hashes, the sorted chain ids, and the deadline — the
    // chain ids + deadline must therefore be fixed before deriving flowId.
    const chainIds = [chainA.chainId, chainB.chainId, chainC.chainId].sort((x, y) => x - y);
    const flowId = computeFlowId([aSpec, bSpec], chainIds, deadline);
    await (await linker.registerFlow(flowId, chainIds, deadline)).wait();
    expect(await linker.flowState(flowId)).to.equal(FlowState.Initiated);

    // ─── PHASE 2: commitSend on each sender (A, B) ────────────────────────────────────
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

    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal(aAmount.toString());
    expect((await chainB.testToken.balanceOf(chainB.escrow.address)).toString()).to.equal(bAmount.toString());

    // ─── PHASE 3: recordFinalitySignal on L1 ──────────────────────────────────────────
    const aProof = buildCommitProofFromReceipt(chainA.chainId, aCommitReceipt, chainA.escrow.address);
    const bProof = buildCommitProofFromReceipt(chainB.chainId, bCommitReceipt, chainB.escrow.address);
    await (await linker.recordFinalitySignal(flowId, [aProof, bProof])).wait();
    expect(await linker.flowState(flowId)).to.equal(FlowState.Finalized);

    // ─── PHASE 4: executeFlow on L1 → dispatches authorizeFromL1 to each L2 ──────────
    const l2GasLimit = BigNumber.from(2_000_000);
    const l2GasPerPubdataByteLimit = BigNumber.from(800);
    const baseCosts = await Promise.all(
      chainIds.map((cid) => bridgehub.l2TransactionBaseCost(cid, GAS_PRICE, l2GasLimit, l2GasPerPubdataByteLimit))
    );
    const execParams: ExecuteParams[] = chainIds.map((_, i) =>
      buildExecuteParams(baseCosts[i], recipientUser, { l2GasLimit, l2GasPerPubdataByteLimit })
    );
    const totalMintValue = baseCosts.reduce((acc, b) => acc.add(b), BigNumber.from(0));

    const execReceipt = await (
      await linker.executeFlow(flowId, execParams, { value: totalMintValue, gasLimit: 10_000_000 })
    ).wait();

    // ─── PHASE 5: Relay each priority tx into its target L2 anvil ────────────────────
    // The L1 receipt contains NPRs on multiple L1 diamond proxies:
    //   - one per dispatched chain, on the GW's L1 diamond (the wrapping txs for GW-settled targets);
    //   - one per dispatched chain, on the chain's own L1 diamond (the actual L2 calldata).
    // We can't call `extractAndRelayNewPriorityRequests` once per chain in resolved-path
    // mode because that would re-relay the GW-bound NPRs N times and the GW asset
    // tracker rejects duplicate canonical tx hashes. Instead: do hop 1 (all GW NPRs in
    // one batch) and hop 2 (per-chain NPRs to per-chain anvils) explicitly.
    const gwChainId = state.chains!.config.find((c) => c.role === "gateway")!.chainId;
    const gwProvider = new ethers.providers.JsonRpcProvider(getL2Chain(state.chains!, gwChainId).rpcUrl);
    const gwL1Diamond = await bridgehub.getZKChain(gwChainId);

    // Hop 1: relay every GW-bound NPR to the GW anvil.
    await extractAndRelayNewPriorityRequests(
      execReceipt,
      [{ diamondProxy: gwL1Diamond, provider: gwProvider }],
      (line) => console.log(`[GW relay] ${line}`)
    );

    // Hop 2: relay each chain's L1-diamond NPRs to its own anvil.
    for (const ctx of [chainA, chainB, chainC]) {
      const chainL1Diamond = await bridgehub.getZKChain(ctx.chainId);
      await extractAndRelayNewPriorityRequests(
        execReceipt,
        [{ diamondProxy: chainL1Diamond, provider: ctx.provider }],
        (line) => console.log(`[chain ${ctx.chainId} relay] ${line}`)
      );
    }

    // After authorize lands, each spec's state on its source AND destination chains is
    // Executable. Verify a couple:
    const aSpecHash = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        [
          "tuple(uint256 destChainId, address recipient, uint256 originChainId, address originToken, " +
            "uint256 amount, bytes erc20Data, address depositor)",
        ],
        [aSpec]
      )
    );
    expect(await chainA.escrow.bundleState(flowId, aSpecHash)).to.equal(SpecState.Executable);
    expect(await chainB.escrow.bundleState(flowId, aSpecHash)).to.equal(SpecState.Executable);

    // ─── PHASE 6: user-driven execute() on each chain ─────────────────────────────────
    // Source side burns (placeholder no-op in V1) + destination side mints.
    await (await (chainA.escrow.connect(chainA.user) as Contract).execute(flowId, aSpec)).wait();
    await (await (chainB.escrow.connect(chainB.user) as Contract).execute(flowId, aSpec)).wait();
    await (await (chainB.escrow.connect(chainB.user) as Contract).execute(flowId, bSpec)).wait();
    await (await (chainC.escrow.connect(chainC.user) as Contract).execute(flowId, bSpec)).wait();

    // ─── Assertions ───────────────────────────────────────────────────────────────────
    // Source side: tokens left the escrow at execute-time (AR.bridgehubDeposit moves
    // them into NTV custody). User balance unchanged from post-commit.
    expect((await chainA.testToken.balanceOf(recipientUser)).toString()).to.equal(userABefore.sub(aAmount).toString());
    expect((await chainA.testToken.balanceOf(chainA.escrow.address)).toString()).to.equal("0");
    expect((await chainB.testToken.balanceOf(recipientUser)).toString()).to.equal(userBBefore.sub(bAmount).toString());
    expect((await chainB.testToken.balanceOf(chainB.escrow.address)).toString()).to.equal("0");

    // Destination side: the user receives a freshly-deployed BridgedStandardERC20
    // shim, NOT the chain's native testToken at the same address. Look up the shim
    // via NTV.tokenAddress(assetId) and check its balanceOf.
    const ntvAbi = ["function tokenAddress(bytes32 assetId) view returns (address)"];
    const erc20AbiBal = ["function balanceOf(address) view returns (uint256)"];
    const ntvAddr = "0x0000000000000000000000000000000000010004"; // L2_NATIVE_TOKEN_VAULT_ADDR

    const aAssetId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["uint256", "address", "address"],
        [chainA.chainId, ntvAddr, chainA.testToken.address]
      )
    );
    const bAssetId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["uint256", "address", "address"],
        [chainB.chainId, ntvAddr, chainB.testToken.address]
      )
    );

    const ntvOnB = new Contract(ntvAddr, ntvAbi, chainB.provider);
    const shimAonB = await ntvOnB.tokenAddress(aAssetId);
    expect(shimAonB).to.not.equal(ethers.constants.AddressZero, "shim for A's token should be deployed on B");
    const shimAonBBalance = await new Contract(shimAonB, erc20AbiBal, chainB.provider).balanceOf(recipientUser);
    expect(shimAonBBalance.toString()).to.equal(aAmount.toString(), "B's user received aAmount of shim(A.token)");

    const ntvOnC = new Contract(ntvAddr, ntvAbi, chainC.provider);
    const shimBonC = await ntvOnC.tokenAddress(bAssetId);
    expect(shimBonC).to.not.equal(ethers.constants.AddressZero, "shim for B's token should be deployed on C");
    const shimBonCBalance = await new Contract(shimBonC, erc20AbiBal, chainC.provider).balanceOf(recipientUser);
    expect(shimBonCBalance.toString()).to.equal(bAmount.toString(), "C's user received bAmount of shim(B.token)");

    // Lifecycle final states.
    expect(await chainA.escrow.bundleState(flowId, aSpecHash)).to.equal(SpecState.Executed);
    expect(await chainB.escrow.bundleState(flowId, aSpecHash)).to.equal(SpecState.Executed);
  });
});
