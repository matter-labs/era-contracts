import { expect } from "chai";
import { BigNumber, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain, buildMockInteropProof } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_RECIPIENT_ADDR,
  ANVIL_ACCOUNT2_PRIVATE_KEY,
  BundleStatus,
  CallStatus,
  FAILING_CALL_CALLDATA,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
} from "../../src/core/const";
import {
  sendInteropBundle,
  executeBundle,
  verifyBundle,
  unbundleBundle,
  getBundleStatus,
  getCallStatus,
  interopCallValueAttr,
  indirectCallAttr,
  executionAddressAttr,
  unbundlerAddressAttr,
  encodeEvmAddress,
  getTokenTransferData,
  getNativeBalance,
  getTokenBalance,
  approveAndReturnAmount,
  getTokenAddressForAsset,
  getInteropProtocolFee,
  deployRevertingContract,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-bundle-helper";
import type { CallStarter } from "../../src/helpers/interop-bundle-helper";

describe("09 - Interop Unbundle (failing calls)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  // Chain topology: source = gwSettledChainIds[0], destination = gwSettledChainIds[1]
  let sourceChainId: number;
  let destChainId: number;
  let sourceProvider: providers.JsonRpcProvider;
  let destProvider: providers.JsonRpcProvider;

  // Bundle A: explicit unbundlerAddress (destination chain unbundling)
  let bundleDataA: string;
  let bundleHashA: string;

  // Bundle B: no explicit unbundlerAddress (source chain unbundling)
  let bundleDataB: string;
  let bundleHashB: string;

  // Amounts used in calls
  const BASE_AMOUNT = ethers.utils.parseEther("0.01");
  const TOKEN_AMOUNT = ethers.utils.parseUnits("1", 18);

  // Token info
  let sourceTokenAddress: string;
  let assetId: string;
  let destTokenAddress: string;

  // Protocol fee
  let protocolFee: BigNumber;

  // DummyInteropRecipient on dest chain for direct calls
  let dummyRecipient: string;
  // Contract that always reverts (for failing call tests)
  let failingContract: string;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledChainIds.length < 2) {
      throw new Error("Need at least 2 GW-settled chains for unbundle tests");
    }

    sourceChainId = gwSettledChainIds[0];
    destChainId = gwSettledChainIds[1];

    const sourceChain = getL2Chain(state.chains, sourceChainId);
    const destChain = getL2Chain(state.chains, destChainId);
    sourceProvider = new providers.JsonRpcProvider(sourceChain.rpcUrl);
    destProvider = new providers.JsonRpcProvider(destChain.rpcUrl);

    sourceTokenAddress = state.testTokens[sourceChainId];
    assetId = encodeNtvAssetId(sourceChainId, sourceTokenAddress);

    // Deploy DummyInteropRecipient on destination chain for direct-call bundles
    dummyRecipient = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient: ${dummyRecipient}`);

    // Deploy a contract that always reverts (for failing call tests)
    failingContract = await deployRevertingContract(destProvider);
    console.log(`   Reverting contract: ${failingContract}`);
  });

  /**
   * Build the 3 call starters used for both bundle A and bundle B:
   *   Call 0: direct value transfer to dummyRecipient
   *   Call 1: call to non-existent contract (WILL FAIL)
   *   Call 2: indirect ERC20 token transfer via asset router
   */
  function buildCallStarters(): CallStarter[] {
    // Call 0: direct value transfer
    const call0: CallStarter = {
      to: encodeEvmAddress(dummyRecipient),
      data: "0x",
      callAttributes: [interopCallValueAttr(BASE_AMOUNT)],
    };

    // Call 1: call to contract that always reverts
    const call1: CallStarter = {
      to: encodeEvmAddress(failingContract),
      data: FAILING_CALL_CALLDATA,
      callAttributes: [interopCallValueAttr(BigNumber.from(0))],
    };

    // Call 2: indirect ERC20 token transfer
    const tokenTransferData = getTokenTransferData(assetId, TOKEN_AMOUNT, ANVIL_RECIPIENT_ADDR);
    const call2: CallStarter = {
      to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
      data: tokenTransferData,
      callAttributes: [indirectCallAttr(), interopCallValueAttr(BigNumber.from(0))],
    };

    return [call0, call1, call2];
  }

  it("Can send bundles that need unbundling", async () => {
    // Approve tokens for the indirect transfer
    await approveAndReturnAmount(sourceProvider, sourceTokenAddress, TOKEN_AMOUNT.mul(2));

    // Get protocol fee
    protocolFee = await getInteropProtocolFee(sourceProvider);

    const callStarters = buildCallStarters();

    // Compute total value: BASE_AMOUNT (for call 0's interopCallValue) + protocol fee * 3 calls
    const valuePerBundle = BASE_AMOUNT.add(protocolFee.mul(3));

    // ── Bundle A: explicit unbundlerAddress = ANVIL_DEFAULT_ACCOUNT_ADDR ──
    const bundleAttributesA = [
      executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR),
      unbundlerAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR),
    ];

    const resultA = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes: bundleAttributesA,
      value: valuePerBundle,
    });

    bundleDataA = resultA.bundleData;
    bundleHashA = resultA.bundleHash;
    console.log(`   Bundle A hash: ${bundleHashA}`);
    console.log(`   Bundle A source tx: ${resultA.txHash}`);

    expect(bundleHashA).to.not.equal(ethers.constants.HashZero);

    // ── Bundle B: no explicit unbundlerAddress (source chain unbundling) ──
    const bundleAttributesB = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    const resultB = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes: bundleAttributesB,
      value: valuePerBundle,
    });

    bundleDataB = resultB.bundleData;
    bundleHashB = resultB.bundleHash;
    console.log(`   Bundle B hash: ${bundleHashB}`);
    console.log(`   Bundle B source tx: ${resultB.txHash}`);

    expect(bundleHashB).to.not.equal(ethers.constants.HashZero);

    // Look up destination token address for later balance checks
    destTokenAddress = await getTokenAddressForAsset(destProvider, assetId);
  });

  it("Cannot unbundle a non-verified bundle", async () => {
    // Attempt to unbundle before verifyBundle - should revert
    const callStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];

    let reverted = false;
    try {
      await unbundleBundle(destProvider, bundleDataA, callStatuses);
    } catch {
      reverted = true;
    }
    expect(reverted, "Expected unbundleBundle to revert on non-verified bundle").to.equal(true);
  });

  it("Can verify a bundle", async () => {
    // First, try atomic executeBundle - should revert because call 1 will fail
    let executeReverted = false;
    try {
      await executeBundle(destProvider, bundleDataA, sourceChainId);
    } catch {
      executeReverted = true;
    }
    expect(executeReverted, "Expected executeBundle to revert due to failing call").to.equal(true);

    // Now call verifyBundle - should succeed
    const verifyReceipt = await verifyBundle(destProvider, bundleDataA, sourceChainId);
    console.log(`   verifyBundle tx: ${verifyReceipt.transactionHash}, status: ${verifyReceipt.status}`);
    expect(verifyReceipt.status, "verifyBundle tx should succeed").to.equal(1);

    // Check bundleStatus == BundleStatus.Verified (1)
    const status = await getBundleStatus(destProvider, bundleHashA);
    console.log(`   Bundle status after verify: ${status}`);
    expect(status, "Bundle should be in Verified status").to.equal(BundleStatus.Verified);
  });

  it("Cannot unbundle from the wrong unbundler address", async () => {
    // Use ANVIL_ACCOUNT2_PRIVATE_KEY as the wrong signer
    const callStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];

    let reverted = false;
    try {
      await unbundleBundle(destProvider, bundleDataA, callStatuses, ANVIL_ACCOUNT2_PRIVATE_KEY);
    } catch {
      reverted = true;
    }
    expect(reverted, "Expected unbundleBundle to revert with wrong unbundler").to.equal(true);
  });

  it("Cannot unbundle a failing call", async () => {
    // Trying to mark the failing call (index 1) as Executed should revert
    const callStatuses = [CallStatus.Unprocessed, CallStatus.Executed, CallStatus.Unprocessed];

    let reverted = false;
    try {
      await unbundleBundle(destProvider, bundleDataA, callStatuses);
    } catch {
      reverted = true;
    }
    expect(reverted, "Expected unbundleBundle to revert when executing a failing call").to.equal(true);
  });

  it("Can unbundle from the destination chain", async () => {
    // ── Round 1: [Unprocessed, Cancelled, Executed] ──
    // This executes call 2 (token transfer) and cancels call 1 (failing)
    const round1Statuses = [CallStatus.Unprocessed, CallStatus.Cancelled, CallStatus.Executed];

    // Capture token balance before round 1
    const tokenBalanceBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);

    await unbundleBundle(destProvider, bundleDataA, round1Statuses);

    // Re-resolve token address (NTV may have deployed bridged token during unbundle)
    destTokenAddress = await getTokenAddressForAsset(destProvider, assetId);

    // Check bundleStatus == BundleStatus.Unbundled (3)
    const statusAfterRound1 = await getBundleStatus(destProvider, bundleHashA);
    expect(statusAfterRound1, "Bundle should be in Unbundled status after round 1").to.equal(BundleStatus.Unbundled);

    // Check callStatus for all 3 calls after round 1
    const call0StatusR1 = await getCallStatus(destProvider, bundleHashA, 0);
    const call1StatusR1 = await getCallStatus(destProvider, bundleHashA, 1);
    const call2StatusR1 = await getCallStatus(destProvider, bundleHashA, 2);
    expect(call0StatusR1, "Call 0 should be Unprocessed after round 1").to.equal(CallStatus.Unprocessed);
    expect(call1StatusR1, "Call 1 should be Cancelled after round 1").to.equal(CallStatus.Cancelled);
    expect(call2StatusR1, "Call 2 should be Executed after round 1").to.equal(CallStatus.Executed);

    // Check token recipient got the token amount
    const tokenBalanceAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const tokenDelta = tokenBalanceAfter.sub(tokenBalanceBefore);
    expect(tokenDelta.eq(TOKEN_AMOUNT), `Token recipient should receive ${TOKEN_AMOUNT}, got ${tokenDelta}`).to.equal(
      true
    );

    // ── Round 2: [Executed, Unprocessed, Unprocessed] ──
    // This executes call 0 (direct value transfer). Already-processed calls are Unprocessed (skip).
    const round2Statuses = [CallStatus.Executed, CallStatus.Unprocessed, CallStatus.Unprocessed];

    // Capture base balance before round 2
    const baseBalanceBefore = await getNativeBalance(destProvider, dummyRecipient);

    await unbundleBundle(destProvider, bundleDataA, round2Statuses);

    // Check bundleStatus still == Unbundled
    const statusAfterRound2 = await getBundleStatus(destProvider, bundleHashA);
    expect(statusAfterRound2, "Bundle should remain in Unbundled status after round 2").to.equal(
      BundleStatus.Unbundled
    );

    // Check callStatus matches final: [Executed, Cancelled, Executed]
    const call0StatusR2 = await getCallStatus(destProvider, bundleHashA, 0);
    const call1StatusR2 = await getCallStatus(destProvider, bundleHashA, 1);
    const call2StatusR2 = await getCallStatus(destProvider, bundleHashA, 2);
    expect(call0StatusR2, "Call 0 should be Executed after round 2").to.equal(CallStatus.Executed);
    expect(call1StatusR2, "Call 1 should remain Cancelled after round 2").to.equal(CallStatus.Cancelled);
    expect(call2StatusR2, "Call 2 should remain Executed after round 2").to.equal(CallStatus.Executed);

    // Check base recipient got the base amount
    const baseBalanceAfter = await getNativeBalance(destProvider, dummyRecipient);
    const baseDelta = baseBalanceAfter.sub(baseBalanceBefore);
    expect(baseDelta.eq(BASE_AMOUNT), `Base recipient should receive ${BASE_AMOUNT}, got ${baseDelta}`).to.equal(true);
  });

  it("Cannot unbundle a processed call", async () => {
    // Trying to re-execute already-processed calls should revert
    // Call 0 and call 2 are already Executed
    const callStatuses = [CallStatus.Executed, CallStatus.Unprocessed, CallStatus.Executed];

    let reverted = false;
    try {
      await unbundleBundle(destProvider, bundleDataA, callStatuses);
    } catch {
      reverted = true;
    }
    expect(reverted, "Expected unbundleBundle to revert when re-executing processed calls").to.equal(true);
  });

  it("Cannot unbundle a cancelled call", async () => {
    // Trying to execute a cancelled call (index 1) should revert
    const callStatuses = [CallStatus.Unprocessed, CallStatus.Executed, CallStatus.Unprocessed];

    let reverted = false;
    try {
      await unbundleBundle(destProvider, bundleDataA, callStatuses);
    } catch {
      reverted = true;
    }
    expect(reverted, "Expected unbundleBundle to revert when executing a cancelled call").to.equal(true);
  });

  it("Can send an unbundling bundle from the source chain", async () => {
    // First verify bundle B on the destination chain
    // Try atomic executeBundle first - should revert (failing call)
    let executeReverted = false;
    try {
      await executeBundle(destProvider, bundleDataB, sourceChainId);
    } catch {
      executeReverted = true;
    }
    expect(executeReverted, "Expected executeBundle to revert for bundle B due to failing call").to.equal(true);

    // Build the final call statuses for bundle B
    // Execute calls 0 and 2, cancel call 1
    const finalCallStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];

    // Build mock proof for verification
    const mockProof = buildMockInteropProof(sourceChainId);

    // Create a NEW bundle from the source chain that contains 2 calls to L2_INTEROP_HANDLER_ADDR
    const interopHandlerIface = new ethers.utils.Interface(getAbi("InteropHandler"));

    // Call 1: verifyBundle(bundleData, proof)
    const verifyCalldata = interopHandlerIface.encodeFunctionData("verifyBundle", [bundleDataB, mockProof]);

    // Call 2: unbundleBundle(bundleData, finalCallStatuses)
    const unbundleCalldata = interopHandlerIface.encodeFunctionData("unbundleBundle", [bundleDataB, finalCallStatuses]);

    const metaCallStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(L2_INTEROP_HANDLER_ADDR),
        data: verifyCalldata,
        callAttributes: [interopCallValueAttr(BigNumber.from(0))],
      },
      {
        to: encodeEvmAddress(L2_INTEROP_HANDLER_ADDR),
        data: unbundleCalldata,
        callAttributes: [interopCallValueAttr(BigNumber.from(0))],
      },
    ];

    const metaBundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    // Capture balances before execution
    const baseBalanceBefore = await getNativeBalance(destProvider, dummyRecipient);
    const tokenBalanceBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);

    // Send the meta-bundle from source chain
    const metaResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters: metaCallStarters,
      bundleAttributes: metaBundleAttributes,
      value: protocolFee.mul(2),
    });

    console.log(`   Meta-bundle source tx: ${metaResult.txHash}`);

    // Execute the meta-bundle on the destination chain
    await executeBundle(destProvider, metaResult.bundleData, sourceChainId);

    // Check bundle B status after meta-bundle execution
    const statusB = await getBundleStatus(destProvider, bundleHashB);
    expect(statusB, "Bundle B should be in Unbundled status after meta-bundle").to.equal(BundleStatus.Unbundled);

    // Check balance deltas
    const baseBalanceAfter = await getNativeBalance(destProvider, dummyRecipient);
    const tokenBalanceAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);

    const baseDelta = baseBalanceAfter.sub(baseBalanceBefore);
    const tokenDelta = tokenBalanceAfter.sub(tokenBalanceBefore);

    expect(baseDelta.eq(BASE_AMOUNT), `Base recipient should receive ${BASE_AMOUNT}, got ${baseDelta}`).to.equal(true);
    expect(tokenDelta.eq(TOKEN_AMOUNT), `Token recipient should receive ${TOKEN_AMOUNT}, got ${tokenDelta}`).to.equal(
      true
    );

    // Check call statuses for bundle B
    const call0Status = await getCallStatus(destProvider, bundleHashB, 0);
    const call1Status = await getCallStatus(destProvider, bundleHashB, 1);
    const call2Status = await getCallStatus(destProvider, bundleHashB, 2);
    expect(call0Status, "Bundle B call 0 should be Executed").to.equal(CallStatus.Executed);
    expect(call1Status, "Bundle B call 1 should be Cancelled").to.equal(CallStatus.Cancelled);
    expect(call2Status, "Bundle B call 2 should be Executed").to.equal(CallStatus.Executed);
  });
});
