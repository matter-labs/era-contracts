import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import type { MultiChainTokenTransferResult } from "../../src/core/types";
import {
  buildInteropBundleLog,
  buildInteropCallExecutedLogs,
  callProcessLogsAndMessages,
  getGWChainBalance,
  getGWPendingInteropBalance,
} from "../../src/helpers/process-logs-helper";
import { extractInteropBundle, getChainIdByRole, getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { encodeNtvAssetId } from "../../src/core/data-encoding";

describe("06 - Gateway Interop (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwChainId: number;
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwChainId = getChainIdByRole(state.chains.config, "gateway");
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
  });

  /**
   * Helper: execute a token transfer and then process the interop bundle log
   * via processLogsAndMessages on the gateway, verifying GW tracker accounting.
   */
  async function transferAndProcessLogs(params: {
    sourceChainId: number;
    targetChainId: number;
    amount: string;
    sourceTokenAddress?: string;
  }): Promise<MultiChainTokenTransferResult> {
    const { sourceChainId, targetChainId, amount } = params;
    const gwChain = getL2Chain(state.chains!, gwChainId);
    const gwProvider = new ethers.providers.JsonRpcProvider(gwChain.rpcUrl);

    const sourceToken = params.sourceTokenAddress || state.testTokens![sourceChainId];
    const assetId = encodeNtvAssetId(sourceChainId, sourceToken);

    const result = await executeTokenTransfer({
      sourceChainId,
      targetChainId,
      amount,
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });

    expect(result.sourceTxHash).to.not.be.null;
    expect(result.targetTxHash).to.not.be.null;

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);

    const interopBundle = await extractInteropBundle(result.sourceRpcUrl, result.sourceTxHash);

    const { log: interopLog, message } = buildInteropBundleLog({
      txNumberInBatch: 0,
      interopBundle,
    });

    // TBM is done at setup stage; source chain should already have sufficient GW balance

    const srcGwBalanceBefore = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    const dstGwBalanceBefore = await getGWChainBalance(gwProvider, targetChainId, assetId);
    const dstPendingInteropBefore = await getGWPendingInteropBalance(gwProvider, targetChainId, assetId);

    console.log(`   GWAssetTracker.chainBalance[${sourceChainId}][assetId] before: ${srcGwBalanceBefore}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] before: ${dstGwBalanceBefore}`);
    console.log(
      `   GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] before: ${dstPendingInteropBefore}`
    );

    const processResult = await callProcessLogsAndMessages({
      gwProvider,
      gwRpcUrl: gwChain.rpcUrl,
      chainId: sourceChainId,
      logs: [interopLog],
      messages: [message],
      logger: (line) => console.log(line),
    });

    expect(processResult.txHash).to.not.be.null;

    const srcGwBalanceAfter = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    const dstGwBalanceAfter = await getGWChainBalance(gwProvider, targetChainId, assetId);
    const dstPendingInteropAfter = await getGWPendingInteropBalance(gwProvider, targetChainId, assetId);

    console.log(`   GWAssetTracker.chainBalance[${sourceChainId}][assetId] after: ${srcGwBalanceAfter}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] after: ${dstGwBalanceAfter}`);
    console.log(`   GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] after: ${dstPendingInteropAfter}`);

    const amountWei = BigNumber.from(result.amountWei);

    const srcDelta = srcGwBalanceBefore.sub(srcGwBalanceAfter);
    expect(
      srcDelta.eq(amountWei),
      `GWAssetTracker.chainBalance[${sourceChainId}][assetId] should decrease by ${amountWei}, got ${srcDelta}`
    ).to.equal(true);

    const dstChainBalanceDelta = dstGwBalanceAfter.sub(dstGwBalanceBefore);
    const dstPendingInteropDelta = dstPendingInteropAfter.sub(dstPendingInteropBefore);
    expect(
      dstChainBalanceDelta.isZero(),
      `GWAssetTracker.chainBalance[${targetChainId}][assetId] should not change before execution confirmation, got ${dstChainBalanceDelta}`
    ).to.equal(true);
    expect(
      dstPendingInteropDelta.eq(amountWei),
      `GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] should increase by ${amountWei}, got ${dstPendingInteropDelta}`
    ).to.equal(true);

    // ── Step 2: Process execution confirmation from the destination chain ──
    // When executeBundle ran on the destination chain, InteropHandler sent L2→L1
    // messages (one per call) confirming execution. Processing these on the GW
    // converts pendingInteropBalance → chainBalance for the destination chain.

    const { logs: executedLogs, messages: executedMessages } = buildInteropCallExecutedLogs({
      startTxNumberInBatch: 0,
      interopBundle,
    });

    const dstPendingBeforeConfirm = await getGWPendingInteropBalance(gwProvider, targetChainId, assetId);
    const dstChainBalBeforeConfirm = await getGWChainBalance(gwProvider, targetChainId, assetId);

    console.log(`   --- Execution confirmation (destination chain ${targetChainId} → GW) ---`);
    console.log(`   GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] before confirm: ${dstPendingBeforeConfirm}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] before confirm: ${dstChainBalBeforeConfirm}`);

    const confirmResult = await callProcessLogsAndMessages({
      gwProvider,
      gwRpcUrl: gwChain.rpcUrl,
      chainId: targetChainId,
      logs: executedLogs,
      messages: executedMessages,
      logger: (line) => console.log(line),
    });

    expect(confirmResult.txHash).to.not.be.null;

    const dstPendingAfterConfirm = await getGWPendingInteropBalance(gwProvider, targetChainId, assetId);
    const dstChainBalAfterConfirm = await getGWChainBalance(gwProvider, targetChainId, assetId);

    console.log(`   GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] after confirm: ${dstPendingAfterConfirm}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] after confirm: ${dstChainBalAfterConfirm}`);

    const pendingDecrease = dstPendingBeforeConfirm.sub(dstPendingAfterConfirm);
    const chainBalIncrease = dstChainBalAfterConfirm.sub(dstChainBalBeforeConfirm);
    expect(
      pendingDecrease.eq(amountWei),
      `GWAssetTracker.pendingInteropBalance[${targetChainId}][assetId] should decrease by ${amountWei} after confirm, got ${pendingDecrease}`
    ).to.equal(true);
    expect(
      chainBalIncrease.eq(amountWei),
      `GWAssetTracker.chainBalance[${targetChainId}][assetId] should increase by ${amountWei} after confirm, got ${chainBalIncrease}`
    ).to.equal(true);

    return result;
  }

  it("transfers tokens between GW-settled chains and processes logs on GW", async () => {
    await transferAndProcessLogs({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
      amount: "5",
      sourceTokenAddress: state.testTokens![gwSettledChainIds[0]],
    });
  });

  it("transfers tokens in reverse direction between GW-settled chains", async () => {
    await transferAndProcessLogs({
      sourceChainId: gwSettledChainIds[1],
      targetChainId: gwSettledChainIds[0],
      amount: "3",
      sourceTokenAddress: state.testTokens![gwSettledChainIds[1]],
    });
  });
});
