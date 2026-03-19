import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import type { MultiChainTokenTransferResult } from "../../src/core/types";
import {
  buildInteropBundleLog,
  callProcessLogsAndMessages,
  getGWChainBalance,
  getGWPendingInteropBalance,
} from "../../src/helpers/process-logs-helper";
import { migrateTokenBalanceToGW } from "../../src/helpers/token-balance-migration-helper";
import { getAbi } from "../../src/core/contracts";
import { L2_NATIVE_TOKEN_VAULT_ADDR } from "../../src/core/const";
import { getChainIdByRole, getChainIdsByRole, getL2Chain, getChainDiamondProxy } from "../../src/core/utils";

/**
 * Extract the InteropBundle struct from the source transaction receipt.
 * Parses the InteropBundleSent event emitted by InteropCenter.
 */
async function extractInteropBundle(
  rpcUrl: string,
  txHash: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
): Promise<any> {
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const receipt = await provider.getTransactionReceipt(txHash);
  const iface = new ethers.utils.Interface(getAbi("InteropCenter"));

  for (const logEntry of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed.name === "InteropBundleSent") {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        return (parsed.args as any).interopBundle;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  throw new Error(`InteropBundleSent event not found in tx ${txHash}`);
}

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
    const assetId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["uint256", "address", "address"],
        [sourceChainId, L2_NATIVE_TOKEN_VAULT_ADDR, sourceToken]
      )
    );

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

    // Establish the source chain's balance via TBM if needed
    const amountBN = BigNumber.from(result.amountWei);
    const currentSrcBalance = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    if (currentSrcBalance.lt(amountBN)) {
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const srcChain = getL2Chain(state.chains!, sourceChainId);
      const l2Provider = new ethers.providers.JsonRpcProvider(srcChain.rpcUrl);
      const gwDiamondProxy = getChainDiamondProxy(state.chainAddresses!, gwChainId);
      const l2DiamondProxy = getChainDiamondProxy(state.chainAddresses!, sourceChainId);

      await migrateTokenBalanceToGW({
        l2Provider,
        l1Provider,
        gwProvider,
        chainId: sourceChainId,
        assetId,
        l1AssetTrackerAddr: state.l1Addresses!.l1AssetTracker,
        gwDiamondProxyAddr: gwDiamondProxy,
        l2DiamondProxyAddr: l2DiamondProxy,
        logger: (line) => console.log(line),
      });
    }

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

    if (sourceChainId !== 1) {
      const srcDelta = srcGwBalanceBefore.sub(srcGwBalanceAfter);
      expect(
        srcDelta.eq(amountWei),
        `GWAssetTracker.chainBalance[${sourceChainId}][assetId] should decrease by ${amountWei}, got ${srcDelta}`
      ).to.equal(true);
    }

    if (targetChainId !== 1) {
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
    }

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

  it("transfers tokens from GW-settled chain to GW and processes logs", async () => {
    await transferAndProcessLogs({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwChainId,
      amount: "2",
      sourceTokenAddress: state.testTokens![gwSettledChainIds[0]],
    });
  });
});
