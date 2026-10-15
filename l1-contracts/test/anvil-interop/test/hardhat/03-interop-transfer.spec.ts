import { expect } from "chai";
import { ethers } from "ethers";
import { executeTokenTransfer, expectTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { getChainIdByRole, getInteropChainIds, getL2RpcUrl, createProvider } from "../../src/core/utils";
import {
  customError,
  expectRevert,
  captureBalance,
  expectBalanceDelta,
  getTokenAddressForAsset,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

describe("03 - Interop Transfer", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let interopChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    interopChainIds = getInteropChainIds(state.chains.config);
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop chains for interop transfer tests");
    }
  });

  // Happy path: transfers between chains that allowed each other as interop peers succeed.

  for (const { title, sourceIndex, targetIndex } of [
    {
      title: "transfers tokens from first interop chain to second interop chain",
      sourceIndex: 0,
      targetIndex: 1,
    },
    {
      title: "transfers tokens from second interop chain to first interop chain",
      sourceIndex: 1,
      targetIndex: 0,
    },
  ]) {
    it(title, async () => {
      await expectTokenTransfer({
        sourceChainId: interopChainIds[sourceIndex],
        targetChainId: interopChainIds[targetIndex],
        amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
        logger: (line: string) => console.log(`[interop] ${line}`),
      });
    });
  }

  it("repeats a transfer to an existing bridged token on an interop chain", async () => {
    const [sourceChainId, targetChainId] = interopChainIds;
    const assetId = encodeNtvAssetId(sourceChainId, state.testTokens![sourceChainId]);
    const targetProvider = createProvider(getL2RpcUrl(state, targetChainId));
    expect(
      await getTokenAddressForAsset(targetProvider, assetId),
      "the first transfer must already have bridged this token to the target"
    ).to.not.equal(ethers.constants.AddressZero);
    await expectTokenTransfer({
      sourceChainId,
      targetChainId,
      amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
      logger: (line: string) => console.log(`[interop] ${line}`),
    });
  });

  // Only interop chains register their peers on their L2Bridgehub, so these destinations are not registered on
  // the source chain's L2Bridgehub.
  for (const { title, sourceRole, targetRole, amount } of [
    {
      title: "rejects transfers from the GW-settled chain to the gateway chain, neither of which has interop",
      sourceRole: "gwSettled",
      targetRole: "gateway",
      amount: "5",
    },
    {
      title: "rejects transfers from an interop chain to the gateway chain, which has no interop",
      sourceRole: "interop",
      targetRole: "gateway",
      amount: "3",
    },
    {
      title: "rejects transfers from an interop chain to the GW-settled chain, which has no interop",
      sourceRole: "interop",
      targetRole: "gwSettled",
      amount: "3",
    },
  ] as const) {
    it(title, async () => {
      const sourceChainId =
        sourceRole === "interop" ? interopChainIds[0] : getChainIdByRole(state.chains!.config, sourceRole);
      const targetChainId = getChainIdByRole(state.chains!.config, targetRole);
      const sourceToken = state.testTokens![sourceChainId];
      const sourceProvider = createProvider(getL2RpcUrl(state, sourceChainId));
      const sourceBefore = await captureBalance(sourceProvider, sourceToken);
      await expectRevert(
        () =>
          executeTokenTransfer({
            sourceChainId,
            targetChainId,
            amount,
            sourceTokenAddress: sourceToken,
            logger: (line: string) => console.log(`[interop] ${line}`),
          }),
        "unregistered destination route",
        customError("InteropCenter", "DestinationChainNotRegistered(uint256)", [targetChainId]),
        sourceProvider
      );
      const sourceAfter = await captureBalance(sourceProvider, sourceToken);
      expectBalanceDelta(
        sourceBefore.token!,
        sourceAfter.token!,
        ethers.constants.Zero,
        "rejected transfer source token"
      );
    });
  }
});
