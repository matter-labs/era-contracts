import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdByRole, getChainIdsByRole } from "../../src/utils";

describe("03 - Interop Transfer (Direct Settlement)", function () {
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
  });

  it("transfers tokens from gateway to first GW-settled chain via InteropCenter", async () => {
    const sourceToken = state.testTokens![gatewayChainId];
    const result = await executeTokenTransfer({
      sourceChainId: gatewayChainId,
      targetChainId: gwSettledChainIds[0],
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

  it("transfers tokens from first GW-settled chain to gateway via InteropCenter", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    const result = await executeTokenTransfer({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gatewayChainId,
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

  it("transfers tokens from direct-settled to gateway chain via InteropCenter", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    const result = await executeTokenTransfer({
      sourceChainId: directSettledChainId,
      targetChainId: gatewayChainId,
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
