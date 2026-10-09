import { expect } from "chai";
import { ethers } from "ethers";
import { executeTokenTransfer, expectTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { getChainIdByRole, getChainIdsByRole, getL2RpcUrl, createProvider } from "../../src/core/utils";
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
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
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
  ]) {
    it(title, async () => {
      await expectTokenTransfer({
        sourceChainId: gwSettledChainIds[sourceIndex],
        targetChainId: gwSettledChainIds[targetIndex],
        amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
        logger: (line: string) => console.log(`[interop] ${line}`),
      });
    });
  }

  it("repeats a transfer to an existing bridged token on a GW-settled chain", async () => {
    const [sourceChainId, targetChainId] = gwSettledChainIds;
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

  // These destinations are not registered on the source chain's L2Bridgehub in this topology.
  for (const { title, sourceRole, targetRole, amount } of [
    {
      title: "rejects transfers from GW-settled chains to the gateway chain",
      sourceRole: "gwSettled",
      targetRole: "gateway",
      amount: "5",
    },
    {
      title: "rejects transfers from direct-settled chains to the gateway chain across settlement layers",
      sourceRole: "directSettled",
      targetRole: "gateway",
      amount: "3",
    },
    {
      title: "rejects transfers from direct-settled chains to GW-settled chains across settlement layers",
      sourceRole: "directSettled",
      targetRole: "gwSettled",
      amount: "3",
    },
  ] as const) {
    it(title, async () => {
      const sourceChainId = getChainIdByRole(state.chains!.config, sourceRole);
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
