import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import type { MultiChainTokenTransferResult } from "../../src/core/types";
import { getChainIdsByRole, getL2RpcUrl, createProvider } from "../../src/core/utils";

import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  INTEROP_CENTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  BundleStatus,
} from "../../src/core/const";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  getInteropProtocolFee,
  registerL2NativeTokenIfNeeded,
  getBundleStatus,
} from "../../src/helpers/interop-helpers";
import {
  captureBalance,
  getTokenBalance,
  getTokenAddressForAsset,
  approveTokenForNtv,
  expectBalanceDelta,
  expectNativeSpend,
  expectSuccessfulReceipt,
  expectEvent,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

describe("06 - Gateway Interop (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
  });

  /**
   * Helper: execute a cross-chain token transfer between GW-settled chains and
   * verify the real value movement (source-chain burn, destination-chain mint).
   */
  async function transferTokens(params: {
    sourceChainId: number;
    targetChainId: number;
    sourceTokenAddress?: string;
  }): Promise<MultiChainTokenTransferResult> {
    const { sourceChainId, targetChainId } = params;

    const sourceToken = params.sourceTokenAddress || state.testTokens![sourceChainId];

    const amountWei = randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX);
    const sourceProvider = createProvider(getL2RpcUrl(state, sourceChainId));
    const targetProvider = createProvider(getL2RpcUrl(state, targetChainId));
    const assetId = encodeNtvAssetId(sourceChainId, sourceToken);
    await registerL2NativeTokenIfNeeded(sourceProvider, sourceToken);
    await approveTokenForNtv(sourceProvider, sourceToken, amountWei);
    const fee = await getInteropProtocolFee(sourceProvider);
    const sourceBefore = await captureBalance(sourceProvider, sourceToken);
    const destinationTokenBefore = await getTokenAddressForAsset(targetProvider, assetId);
    const destinationBefore = await getTokenBalance(targetProvider, destinationTokenBefore, ANVIL_DEFAULT_ACCOUNT_ADDR);
    const result = await executeTokenTransfer({
      sourceChainId,
      targetChainId,
      amount: ethers.utils.formatUnits(amountWei, 18),
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });

    const sourceReceipt = await expectSuccessfulReceipt(sourceProvider, result.sourceTxHash, "interop source");
    const targetReceipt = await expectSuccessfulReceipt(targetProvider, result.targetTxHash, "interop destination");
    const sourceAfter = await captureBalance(sourceProvider, sourceToken);
    const destinationToken = await getTokenAddressForAsset(targetProvider, assetId);
    const destinationAfter = await getTokenBalance(targetProvider, destinationToken, ANVIL_DEFAULT_ACCOUNT_ADDR);
    expectBalanceDelta(sourceBefore.token!, sourceAfter.token!, amountWei.mul(-1), "interop source token");
    expectBalanceDelta(destinationBefore, destinationAfter, amountWei, "interop destination token");
    expectNativeSpend(sourceBefore, sourceAfter, fee, sourceReceipt, "interop source fee");

    const sent = expectEvent(sourceReceipt, "InteropCenter", INTEROP_CENTER_ADDR, "InteropBundleSent");
    expect(sent.interopBundle.sourceChainId.toNumber()).to.equal(sourceChainId);
    expect(sent.interopBundle.destinationChainId.toNumber()).to.equal(targetChainId);
    expect(sent.interopBundle.calls).to.have.length(1);
    const executed = expectEvent(targetReceipt, "L2InteropHandler", L2_INTEROP_HANDLER_ADDR, "BundleExecuted");
    expect(executed.bundleHash).to.equal(sent.interopBundleHash);
    expect(await getBundleStatus(targetProvider, sent.interopBundleHash)).to.equal(BundleStatus.FullyExecuted);
    const minted = expectEvent(targetReceipt, "L2NativeTokenVault", L2_NATIVE_TOKEN_VAULT_ADDR, "BridgeMint");
    expect(minted.chainId.toNumber()).to.equal(sourceChainId);
    expect(minted.assetId).to.equal(assetId);
    expect(minted.receiver).to.equal(ANVIL_DEFAULT_ACCOUNT_ADDR);
    expect(minted.amount.toString()).to.equal(amountWei.toString());

    return result;
  }

  it("transfers tokens between GW-settled chains", async () => {
    await transferTokens({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
      sourceTokenAddress: state.testTokens![gwSettledChainIds[0]],
    });
  });

  it("transfers tokens in reverse direction between GW-settled chains", async () => {
    await transferTokens({
      sourceChainId: gwSettledChainIds[1],
      targetChainId: gwSettledChainIds[0],
      sourceTokenAddress: state.testTokens![gwSettledChainIds[1]],
    });
  });
});
