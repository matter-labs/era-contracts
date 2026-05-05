import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole } from "../../src/core/utils";

describe("03 - Interop Transfer (GW-Settled Chains)", function () {
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

  it("transfers tokens from first GW-settled chain to second GW-settled chain", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    const result = await executeTokenTransfer({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
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

  it("transfers tokens from second GW-settled chain to first GW-settled chain", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[1]];
    const result = await executeTokenTransfer({
      sourceChainId: gwSettledChainIds[1],
      targetChainId: gwSettledChainIds[0],
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

  it("transfers tokens between two different GW-settled chains (reverse direction)", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    const result = await executeTokenTransfer({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
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
