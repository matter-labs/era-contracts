import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { executeTokenTransfer } from "../../src/token-transfer";
import type { MultiChainTokenTransferResult } from "../../src/types";
import {
  buildInteropBundleLog,
  callProcessLogsAndMessages,
  getGWChainBalance,
} from "../../src/process-logs-helper";
import { migrateTokenBalanceToGW } from "../../src/token-balance-migration-helper";
import { interopCenterAbi } from "../../src/contracts";
import { L2_NATIVE_TOKEN_VAULT_ADDR } from "../../src/const";

const L2A_CHAIN_ID = 12;
const L2B_CHAIN_ID = 13;
const GW_CHAIN_ID = 11;

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
  const iface = new ethers.utils.Interface(interopCenterAbi());

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

describe("06 - Gateway Interop (L2A <-> L2B)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  // batchNumber is auto-detected by callProcessLogsAndMessages

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
  });

  /**
   * Helper: execute a token transfer and then process the interop bundle log
   * via processLogsAndMessages on the gateway, verifying chainBalance changes.
   */
  async function transferAndProcessLogs(params: {
    sourceChainId: number;
    targetChainId: number;
    amount: string;
  }): Promise<MultiChainTokenTransferResult> {
    const { sourceChainId, targetChainId, amount } = params;
    const gwChain = state.chains!.l2.find((c) => c.chainId === GW_CHAIN_ID)!;
    const gwProvider = new ethers.providers.JsonRpcProvider(gwChain.rpcUrl);

    // Get the asset ID of the token being transferred
    // assetId = keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress))
    const sourceToken = state.testTokens![sourceChainId];
    const assetId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["uint256", "address", "address"],
        [sourceChainId, L2_NATIVE_TOKEN_VAULT_ADDR, sourceToken]
      )
    );

    // Execute the interop transfer
    const result = await executeTokenTransfer({
      sourceChainId,
      targetChainId,
      amount,
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });

    expect(result.sourceTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);
    expect(result.targetTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

    // Verify token balances changed correctly
    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(
      result.destinationBalanceBefore
    );
    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);

    // Extract the interop bundle from the source tx
    const interopBundle = await extractInteropBundle(result.sourceRpcUrl, result.sourceTxHash);

    // Build the log and message for processLogsAndMessages
    const { log: interopLog, message } = buildInteropBundleLog({
      txNumberInBatch: 0,
      interopBundle,
    });

    // Establish the source chain's balance via the full Token Balance Migration flow.
    // This ensures processLogsAndMessages doesn't revert with InsufficientChainBalance.
    const amountBN = BigNumber.from(result.amountWei);
    const currentSrcBalance = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    if (currentSrcBalance.lt(amountBN)) {
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const srcChain = state.chains!.l2.find((c) => c.chainId === sourceChainId)!;
      const l2Provider = new ethers.providers.JsonRpcProvider(srcChain.rpcUrl);
      const gwDiamondProxy = state.chainAddresses!.find((c) => c.chainId === GW_CHAIN_ID)!.diamondProxy;
      const l2DiamondProxy = state.chainAddresses!.find((c) => c.chainId === sourceChainId)!.diamondProxy;

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

    // Snapshot GW chain balances before processLogsAndMessages (after seeding)
    const srcGwBalanceBefore = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    const dstGwBalanceBefore = await getGWChainBalance(gwProvider, targetChainId, assetId);

    console.log(`   GWAssetTracker.chainBalance[${sourceChainId}][assetId] before: ${srcGwBalanceBefore}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] before: ${dstGwBalanceBefore}`);

    // Call processLogsAndMessages on GW for the source chain
    const processResult = await callProcessLogsAndMessages({
      gwProvider,
      gwRpcUrl: gwChain.rpcUrl,
      chainId: sourceChainId,
      logs: [interopLog],
      messages: [message],
      logger: (line) => console.log(line),
    });

    expect(processResult.txHash).to.match(/^0x[0-9a-fA-F]{64}$/);

    // Snapshot GW chain balances after
    const srcGwBalanceAfter = await getGWChainBalance(gwProvider, sourceChainId, assetId);
    const dstGwBalanceAfter = await getGWChainBalance(gwProvider, targetChainId, assetId);

    console.log(`   GWAssetTracker.chainBalance[${sourceChainId}][assetId] after: ${srcGwBalanceAfter}`);
    console.log(`   GWAssetTracker.chainBalance[${targetChainId}][assetId] after: ${dstGwBalanceAfter}`);

    // Verify asset balance changes:
    // _handleAssetRouterMessageInner(source, dest, assetId, amount) ->
    //   _handleChainBalanceChangeOnGateway: decrements chainBalance[source], increments chainBalance[dest]
    //   (unless source or dest is L1_CHAIN_ID)
    const amountWei = BigNumber.from(result.amountWei);

    if (sourceChainId !== 1) {
      const srcDelta = srcGwBalanceBefore.sub(srcGwBalanceAfter);
      expect(
        srcDelta.eq(amountWei),
        `GWAssetTracker.chainBalance[${sourceChainId}][assetId] should decrease by ${amountWei}, got ${srcDelta}`
      ).to.equal(true);
    }

    if (targetChainId !== 1) {
      const dstDelta = dstGwBalanceAfter.sub(dstGwBalanceBefore);
      expect(
        dstDelta.eq(amountWei),
        `GWAssetTracker.chainBalance[${targetChainId}][assetId] should increase by ${amountWei}, got ${dstDelta}`
      ).to.equal(true);
    }

    return result;
  }

  it("transfers tokens L2A->L2B and processes logs on GW", async () => {
    await transferAndProcessLogs({
      sourceChainId: L2A_CHAIN_ID,
      targetChainId: L2B_CHAIN_ID,
      amount: "5",
    });
  });

  it("transfers tokens L2B->L2A and processes logs on GW", async () => {
    await transferAndProcessLogs({
      sourceChainId: L2B_CHAIN_ID,
      targetChainId: L2A_CHAIN_ID,
      amount: "3",
    });
  });

  it("transfers tokens L2A->GW and processes logs on GW", async () => {
    await transferAndProcessLogs({
      sourceChainId: L2A_CHAIN_ID,
      targetChainId: GW_CHAIN_ID,
      amount: "2",
    });
  });
});
