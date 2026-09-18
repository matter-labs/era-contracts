import { expect } from "chai";
import { ethers } from "ethers";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdByRole, getChainIdsByRole, getL2RpcUrl, createProvider } from "../../src/core/utils";

import {
  customError,
  expectRevert,
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

const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

describe("03 - Interop Transfer", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gatewayChainId: number;
  let directSettledChainId: number;
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gatewayChainId = getChainIdByRole(state.chains.config, "gateway");
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledChainIds.length < 2) {
      throw new Error("Need at least 2 GW-settled chains for interop transfer tests");
    }
  });

  // Happy path: transfers between chains that share the gateway settlement layer succeed.

  for (const { title, sourceIndex, targetIndex } of [
    {
      title: "transfers tokens from first GW-settled chain to second GW-settled chain",
      sourceIndex: 0,
      targetIndex: 1,
    },
    {
      title: "transfers tokens from second GW-settled chain to first GW-settled chain",
      sourceIndex: 1,
      targetIndex: 0,
    },
    { title: "repeats a transfer to an existing bridged token on a GW-settled chain", sourceIndex: 0, targetIndex: 1 },
  ]) {
    it(title, async () => {
      const sourceChainId = gwSettledChainIds[sourceIndex];
      const targetChainId = gwSettledChainIds[targetIndex];
      const sourceToken = state.testTokens![sourceChainId];
      const amountWei = randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX);
      const sourceProvider = createProvider(getL2RpcUrl(state, sourceChainId));
      const targetProvider = createProvider(getL2RpcUrl(state, targetChainId));
      const assetId = encodeNtvAssetId(sourceChainId, sourceToken);
      await registerL2NativeTokenIfNeeded(sourceProvider, sourceToken);
      await approveTokenForNtv(sourceProvider, sourceToken, amountWei);
      const fee = await getInteropProtocolFee(sourceProvider);
      const sourceBefore = await captureBalance(sourceProvider, sourceToken);
      const destinationTokenBefore = await getTokenAddressForAsset(targetProvider, assetId);
      const destinationBefore = await getTokenBalance(
        targetProvider,
        destinationTokenBefore,
        ANVIL_DEFAULT_ACCOUNT_ADDR
      );
      const result = await executeTokenTransfer({
        sourceChainId,
        targetChainId,
        amount: ethers.utils.formatUnits(amountWei, 18),
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
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
    });
  }

  // These destinations are absent from the source Bridgehub's registration set in this
  // topology. Captured on Anvil: 0x2d159f39, DestinationChainNotRegistered(uint256).
  it("rejects transfers from GW-settled chains to the gateway chain", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    const sourceProvider = createProvider(getL2RpcUrl(state, gwSettledChainIds[0]));
    const sourceBefore = await captureBalance(sourceProvider, sourceToken);
    await expectRevert(
      () =>
        executeTokenTransfer({
          sourceChainId: gwSettledChainIds[0],
          targetChainId: gatewayChainId,
          amount: "5",
          sourceTokenAddress: sourceToken,
          logger: (line: string) => console.log(`[interop] ${line}`),
        }),
      "unregistered destination route",
      customError("InteropCenter", "DestinationChainNotRegistered(uint256)"),
      createProvider(getL2RpcUrl(state, gwSettledChainIds[0]))
    );
    const sourceAfter = await captureBalance(sourceProvider, sourceToken);
    expectBalanceDelta(
      sourceBefore.token!,
      sourceAfter.token!,
      ethers.constants.Zero,
      "rejected transfer source token"
    );
  });

  it("rejects transfers from direct-settled chains to the gateway chain across settlement layers", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    const sourceProvider = createProvider(getL2RpcUrl(state, directSettledChainId));
    const sourceBefore = await captureBalance(sourceProvider, sourceToken);
    await expectRevert(
      () =>
        executeTokenTransfer({
          sourceChainId: directSettledChainId,
          targetChainId: gatewayChainId,
          amount: "3",
          sourceTokenAddress: sourceToken,
          logger: (line: string) => console.log(`[interop] ${line}`),
        }),
      "unregistered destination route",
      customError("InteropCenter", "DestinationChainNotRegistered(uint256)"),
      createProvider(getL2RpcUrl(state, directSettledChainId))
    );
    const sourceAfter = await captureBalance(sourceProvider, sourceToken);
    expectBalanceDelta(
      sourceBefore.token!,
      sourceAfter.token!,
      ethers.constants.Zero,
      "rejected transfer source token"
    );
  });

  it("rejects transfers from direct-settled chains to GW-settled chains across settlement layers", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    const sourceProvider = createProvider(getL2RpcUrl(state, directSettledChainId));
    const sourceBefore = await captureBalance(sourceProvider, sourceToken);
    await expectRevert(
      () =>
        executeTokenTransfer({
          sourceChainId: directSettledChainId,
          targetChainId: gwSettledChainIds[0],
          amount: "3",
          sourceTokenAddress: sourceToken,
          logger: (line: string) => console.log(`[interop] ${line}`),
        }),
      "unregistered destination route",
      customError("InteropCenter", "DestinationChainNotRegistered(uint256)"),
      createProvider(getL2RpcUrl(state, directSettledChainId))
    );
    const sourceAfter = await captureBalance(sourceProvider, sourceToken);
    expectBalanceDelta(
      sourceBefore.token!,
      sourceAfter.token!,
      ethers.constants.Zero,
      "rejected transfer source token"
    );
  });
});
