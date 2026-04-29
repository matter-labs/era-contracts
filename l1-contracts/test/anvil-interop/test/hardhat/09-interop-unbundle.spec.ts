import { expect } from "chai";
import { BigNumber, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  getInteropRecipientAddress,
  getInteropTestAddress,
  getInteropUnbundlerAddress,
  getInteropUnbundlerPrivateKey,
} from "../../src/core/accounts";
import {
  BundleStatus,
  CallStatus,
  DEFAULT_TX_GAS_LIMIT,
  FAILING_CALL_CALLDATA,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
} from "../../src/core/const";
import { encodeEvmAddress } from "../../src/helpers/erc7930";
import {
  sendInteropBundle,
  executeBundle,
  simulateUnbundleBundle,
  verifyBundle,
  unbundleBundle,
  getBundleStatus,
  getCallStatus,
  interopCallValueAttr,
  indirectCallAttr,
  executionAddressAttr,
  unbundlerAddressAttr,
  getTokenTransferData,
  getInteropProtocolFee,
  deployRevertingContract,
  deployDummyInteropRecipient,
  getInteropExecutionData,
} from "../../src/helpers/interop-helpers";
import type { CallStarter, InteropSendResult } from "../../src/helpers/interop-helpers";
import {
  getNativeBalance,
  getTokenBalance,
  approveTokenForNtv,
  getTokenAddressForAsset,
  expectBalanceDelta,
  expectRevert,
  customError,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

/**
 * 09 - Interop Unbundle (verifyBundle / unbundleBundle)
 *
 * Tests the non-atomic recovery flow for bundles that contain a failing call.
 * The suite verifies that bundles can be verified, selectively unbundled across
 * multiple rounds, and enforced by unbundlerAddress / call-status rules while
 * still delivering successful base-token and ERC20 transfers.
 *
 * Topology: gwSettledChainIds[0] = source, gwSettledChainIds[1] = destination
 */
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

  // Randomized per-test amount ranges
  const BASE_AMOUNT_MIN = ethers.utils.parseUnits("10", "gwei");
  const BASE_AMOUNT_MAX = ethers.utils.parseUnits("1000", "gwei");
  const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
  const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

  // Token info
  let sourceTokenAddress: string;
  let sourceAssetId: string;

  // Protocol fee
  let interopFee: BigNumber;

  // DummyInteropRecipient on dest chain for direct calls
  let dummyRecipient: string;
  // Contract that always reverts (for failing call tests)
  let failingContract: string;

  function getTestTokenAssetId(chainId: number, tokenAddress: string): string {
    return state.testTokenAssetIds?.[chainId] || encodeNtvAssetId(chainId, tokenAddress);
  }

  async function currentInteropFee(): Promise<BigNumber> {
    interopFee = await getInteropProtocolFee(sourceProvider);
    return interopFee;
  }

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
    sourceAssetId = getTestTokenAssetId(sourceChainId, sourceTokenAddress);

    if (getInteropTestAddress().toLowerCase() === getInteropUnbundlerAddress().toLowerCase()) {
      throw new Error("Unbundle tests require a distinct unbundler private key");
    }

    // Deploy DummyInteropRecipient on destination chain for direct-call bundles
    dummyRecipient = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient: ${dummyRecipient}`);

    // Deploy a contract that always reverts (for failing call tests)
    failingContract = await deployRevertingContract(destProvider);
    console.log(`   Reverting contract: ${failingContract}`);

    // Get protocol fee
    interopFee = await getInteropProtocolFee(sourceProvider);
    console.log(`   Interop protocol fee: ${interopFee.toString()}`);
  });

  /**
   * Build the 3 call starters used for bundles:
   *   Call 0: direct value transfer to dummyRecipient
   *   Call 1: call to contract that always reverts (WILL FAIL)
   *   Call 2: indirect ERC20 token transfer via asset router
   */
  function buildCallStarters(baseAmount: BigNumber, tokenAmount: BigNumber): CallStarter[] {
    const call0: CallStarter = {
      to: encodeEvmAddress(dummyRecipient),
      data: "0x",
      callAttributes: [interopCallValueAttr(baseAmount)],
    };

    const call1: CallStarter = {
      to: encodeEvmAddress(failingContract),
      data: FAILING_CALL_CALLDATA,
      callAttributes: [interopCallValueAttr(BigNumber.from(0))],
    };

    const tokenTransferData = getTokenTransferData(sourceAssetId, tokenAmount, getInteropRecipientAddress());
    const call2: CallStarter = {
      to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
      data: tokenTransferData,
      callAttributes: [indirectCallAttr(), interopCallValueAttr(BigNumber.from(0))],
    };

    return [call0, call1, call2];
  }

  /**
   * Send a fresh bundle with the 3 call starters and return its data.
   * Approves tokens, pays the protocol fee, and sends the bundle.
   */
  async function sendAndPrepareBundle(opts: { withUnbundlerAddress?: boolean }): Promise<{
    sendResult: InteropSendResult;
    bundleData: string;
    bundleHash: string;
    baseAmount: BigNumber;
    tokenAmount: BigNumber;
  }> {
    const baseAmount = randomBigNumber(BASE_AMOUNT_MIN, BASE_AMOUNT_MAX);
    const tokenAmount = randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX);
    await approveTokenForNtv(sourceProvider, sourceTokenAddress, tokenAmount);

    const callStarters = buildCallStarters(baseAmount, tokenAmount);
    const interopFee = await currentInteropFee();
    const valuePerBundle = baseAmount.add(interopFee.mul(callStarters.length));

    const bundleAttributes = [executionAddressAttr(getInteropTestAddress())];
    if (opts.withUnbundlerAddress) {
      bundleAttributes.push(unbundlerAddressAttr(getInteropUnbundlerAddress()));
    }

    const result = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: valuePerBundle,
    });

    expect(result.bundleHash).to.not.equal(ethers.constants.HashZero);

    return {
      sendResult: result,
      bundleData: result.bundleData,
      bundleHash: result.bundleHash,
      baseAmount,
      tokenAmount,
    };
  }

  async function expectCallStatuses(
    provider: providers.JsonRpcProvider,
    bundleHash: string,
    expectedStatuses: CallStatus[],
    context: string
  ): Promise<void> {
    const actualStatuses = await Promise.all(
      expectedStatuses.map((_, index) => getCallStatus(provider, bundleHash, index))
    );

    expectedStatuses.forEach((expectedStatus, index) => {
      expect(actualStatuses[index], `${context}: call ${index}`).to.equal(expectedStatus);
    });
  }

  it("Cannot unbundle a non-verified bundle", async () => {
    const { bundleData } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    const callStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];
    await expectRevert(
      () => simulateUnbundleBundle(destProvider, bundleData, callStatuses, getInteropUnbundlerPrivateKey()),
      "unbundle non-verified bundle",
      customError("InteropHandler", "CanNotUnbundle(bytes32)")
    );
  });

  it("Can verify a bundle", async () => {
    const { bundleData, bundleHash } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    // First, try atomic executeBundle - should revert because call 1 will fail
    await expectRevert(() => executeBundle(destProvider, bundleData, sourceChainId), "executeBundle with failing call");

    // Now call verifyBundle - should succeed
    const verifyReceipt = await verifyBundle(destProvider, bundleData, sourceChainId);
    console.log(`   verifyBundle tx: ${verifyReceipt.transactionHash}, status: ${verifyReceipt.status}`);
    expect(verifyReceipt.status, "verifyBundle tx should succeed").to.equal(1);

    // Check bundleStatus == BundleStatus.Verified (1)
    const status = await getBundleStatus(destProvider, bundleHash);
    console.log(`   Bundle status after verify: ${status}`);
    expect(status, "Bundle should be in Verified status").to.equal(BundleStatus.Verified);
  });

  it("Cannot unbundle from the wrong unbundler address", async () => {
    const { bundleData } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    // Verify the bundle first so we can attempt unbundle
    await verifyBundle(destProvider, bundleData, sourceChainId);

    // Use the default signer, not the designated unbundler.
    const callStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];
    await expectRevert(
      () => simulateUnbundleBundle(destProvider, bundleData, callStatuses),
      "unbundle from wrong address",
      customError("InteropHandler", "UnbundlingNotAllowed(bytes32,bytes,bytes)")
    );
  });

  it("Cannot unbundle a failing call", async () => {
    const { bundleData } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    // Verify the bundle first
    await verifyBundle(destProvider, bundleData, sourceChainId);

    // Trying to mark the failing call (index 1) as Executed should revert
    const callStatuses = [CallStatus.Unprocessed, CallStatus.Executed, CallStatus.Unprocessed];
    await expectRevert(
      () => unbundleBundle(destProvider, bundleData, callStatuses, getInteropUnbundlerPrivateKey()),
      "execute a failing call"
    );
  });

  it("Can unbundle from the destination chain", async () => {
    const { bundleData, bundleHash, baseAmount, tokenAmount } = await sendAndPrepareBundle({
      withUnbundlerAddress: true,
    });

    // Verify the bundle first
    await verifyBundle(destProvider, bundleData, sourceChainId);

    // Resolve destination token address
    let destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    // ── Round 1: [Unprocessed, Cancelled, Executed] ──
    // This executes call 2 (token transfer) and cancels call 1 (failing)
    const round1Statuses = [CallStatus.Unprocessed, CallStatus.Cancelled, CallStatus.Executed];

    // Capture token balance before round 1
    const tokenBalanceBefore = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());

    await unbundleBundle(destProvider, bundleData, round1Statuses, getInteropUnbundlerPrivateKey());

    // Re-resolve token address (NTV may have deployed bridged token during unbundle)
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    // Check bundleStatus == BundleStatus.Unbundled (3)
    const statusAfterRound1 = await getBundleStatus(destProvider, bundleHash);
    expect(statusAfterRound1, "Bundle should be in Unbundled status after round 1").to.equal(BundleStatus.Unbundled);

    await expectCallStatuses(destProvider, bundleHash, round1Statuses, "after round 1");

    // Check token recipient got the token amount
    const tokenBalanceAfter = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    expectBalanceDelta(tokenBalanceBefore, tokenBalanceAfter, tokenAmount, "round 1: recipient token");

    // ── Round 2: [Executed, Unprocessed, Unprocessed] ──
    // This executes call 0 (direct value transfer). Already-processed calls are Unprocessed (skip).
    const round2Statuses = [CallStatus.Executed, CallStatus.Unprocessed, CallStatus.Unprocessed];

    // Capture base balance before round 2
    const baseBalanceBefore = await getNativeBalance(destProvider, dummyRecipient);

    await unbundleBundle(destProvider, bundleData, round2Statuses, getInteropUnbundlerPrivateKey());

    // Check bundleStatus still == Unbundled
    const statusAfterRound2 = await getBundleStatus(destProvider, bundleHash);
    expect(statusAfterRound2, "Bundle should remain in Unbundled status after round 2").to.equal(
      BundleStatus.Unbundled
    );

    await expectCallStatuses(
      destProvider,
      bundleHash,
      [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed],
      "after round 2"
    );

    // Check base recipient got the base amount
    const baseBalanceAfter = await getNativeBalance(destProvider, dummyRecipient);
    expectBalanceDelta(baseBalanceBefore, baseBalanceAfter, baseAmount, "round 2: recipient native");
  });

  it("Cannot unbundle a processed call", async () => {
    // Send, verify, and fully unbundle a bundle, then try to re-execute
    const { bundleData, bundleHash } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    await verifyBundle(destProvider, bundleData, sourceChainId);

    // Unbundle round 1: execute calls 0 and 2, cancel call 1
    await unbundleBundle(
      destProvider,
      bundleData,
      [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed],
      getInteropUnbundlerPrivateKey()
    );

    await expectCallStatuses(
      destProvider,
      bundleHash,
      [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed],
      "after full unbundle"
    );

    // Trying to re-execute already-processed calls should revert
    const callStatuses = [CallStatus.Executed, CallStatus.Unprocessed, CallStatus.Executed];
    await expectRevert(
      () => simulateUnbundleBundle(destProvider, bundleData, callStatuses, getInteropUnbundlerPrivateKey()),
      "re-execute processed calls",
      customError("InteropHandler", "CallNotExecutable(bytes32,uint256)")
    );
  });

  it("Cannot unbundle a cancelled call", async () => {
    // Send, verify, and partially unbundle (cancel call 1), then try to execute it
    const { bundleData, bundleHash } = await sendAndPrepareBundle({ withUnbundlerAddress: true });

    await verifyBundle(destProvider, bundleData, sourceChainId);

    // Unbundle: cancel call 1, leave 0 and 2 unprocessed
    await unbundleBundle(
      destProvider,
      bundleData,
      [CallStatus.Unprocessed, CallStatus.Cancelled, CallStatus.Unprocessed],
      getInteropUnbundlerPrivateKey()
    );

    await expectCallStatuses(
      destProvider,
      bundleHash,
      [CallStatus.Unprocessed, CallStatus.Cancelled, CallStatus.Unprocessed],
      "after cancelling call 1"
    );

    // Trying to execute a cancelled call (index 1) should revert
    const callStatuses = [CallStatus.Unprocessed, CallStatus.Executed, CallStatus.Unprocessed];
    await expectRevert(
      () => simulateUnbundleBundle(destProvider, bundleData, callStatuses, getInteropUnbundlerPrivateKey()),
      "execute a cancelled call",
      customError("InteropHandler", "CallNotExecutable(bytes32,uint256)")
    );
  });

  it("Can send an unbundling bundle from the source chain", async () => {
    const { sendResult, bundleData, bundleHash, baseAmount, tokenAmount } = await sendAndPrepareBundle({});

    // Try atomic executeBundle first - should revert (failing call)
    await expectRevert(() => executeBundle(destProvider, bundleData, sourceChainId), "executeBundle with failing call");

    // Build the final call statuses: execute calls 0 and 2, cancel call 1
    const finalCallStatuses = [CallStatus.Executed, CallStatus.Cancelled, CallStatus.Executed];

    const executionData = await getInteropExecutionData(destProvider, sendResult, sourceChainId);

    // Create a NEW bundle from the source chain that contains 2 calls to L2_INTEROP_HANDLER_ADDR
    const interopHandlerIface = new ethers.utils.Interface(getAbi("InteropHandler"));

    // Call 1: verifyBundle(bundleData, proof)
    const verifyCalldata = interopHandlerIface.encodeFunctionData("verifyBundle", [
      executionData.bundleData,
      executionData.proof,
    ]);

    // Call 2: unbundleBundle(bundleData, finalCallStatuses)
    const unbundleCalldata = interopHandlerIface.encodeFunctionData("unbundleBundle", [
      executionData.bundleData,
      finalCallStatuses,
    ]);

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

    const metaBundleAttributes = [executionAddressAttr(getInteropTestAddress())];

    // Resolve destination token address
    let destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    // Capture balances before execution
    const baseBalanceBefore = await getNativeBalance(destProvider, dummyRecipient);
    const tokenBalanceBefore = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());

    // Send the meta-bundle from source chain
    const interopFee = await currentInteropFee();
    const metaResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters: metaCallStarters,
      bundleAttributes: metaBundleAttributes,
      value: interopFee.mul(2),
      gasLimit: DEFAULT_TX_GAS_LIMIT,
    });

    console.log(`   Meta-bundle source tx: ${metaResult.txHash}`);

    // Execute the meta-bundle on the destination chain
    await executeBundle(destProvider, metaResult.bundleData, sourceChainId);

    // Check bundle status after meta-bundle execution
    const statusB = await getBundleStatus(destProvider, bundleHash);
    expect(statusB, "Bundle should be in Unbundled status after meta-bundle").to.equal(BundleStatus.Unbundled);

    // Check balance deltas
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    expect(destTokenAddress, "bridged token should be deployed by the meta-bundle").to.not.equal(
      ethers.constants.AddressZero
    );
    const baseBalanceAfter = await getNativeBalance(destProvider, dummyRecipient);
    const tokenBalanceAfter = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());

    expectBalanceDelta(baseBalanceBefore, baseBalanceAfter, baseAmount, "meta-bundle: recipient native");
    expectBalanceDelta(tokenBalanceBefore, tokenBalanceAfter, tokenAmount, "meta-bundle: recipient token");

    await expectCallStatuses(destProvider, bundleHash, finalCallStatuses, "after meta-bundle");
  });
});
