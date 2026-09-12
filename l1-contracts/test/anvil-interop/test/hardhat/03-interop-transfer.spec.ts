import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole } from "../../src/core/utils";

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
    interopChainIds = getChainIdsByRole(state.chains.config, "directSettled");
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 L1-settled L2 chains for interop transfer tests");
    }
  });

  // Happy path: every L2 chain settles on L1 and is registered as an interop peer of every other L2
  // chain, so transfers between any two of them succeed.

  it("transfers tokens from first L1-settled chain to second L1-settled chain", async () => {
    const sourceToken = state.testTokens![interopChainIds[0]];
    const result = await executeTokenTransfer({
      sourceChainId: interopChainIds[0],
      targetChainId: interopChainIds[1],
      amount: "10",
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.not.be.null;
    expect(result.targetTxHash).to.not.be.null;

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });

  it("transfers tokens from second L1-settled chain to first L1-settled chain", async () => {
    const sourceToken = state.testTokens![interopChainIds[1]];
    const result = await executeTokenTransfer({
      sourceChainId: interopChainIds[1],
      targetChainId: interopChainIds[0],
      amount: "5",
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.not.be.null;
    expect(result.targetTxHash).to.not.be.null;

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });

  it("transfers tokens from first to second L1-settled chain again after the round trip", async () => {
    const sourceToken = state.testTokens![interopChainIds[0]];
    const result = await executeTokenTransfer({
      sourceChainId: interopChainIds[0],
      targetChainId: interopChainIds[1],
      amount: "3",
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.not.be.null;
    expect(result.targetTxHash).to.not.be.null;

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });
});
