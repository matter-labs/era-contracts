import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdByRole, getChainIdsByRole } from "../../src/core/utils";

async function expectTransferToRevert(promise: Promise<unknown>, expectedSubstring?: string): Promise<void> {
  let rejected = false;
  try {
    await promise;
  } catch (error) {
    rejected = true;
    if (expectedSubstring) {
      const message = error instanceof Error ? error.message : String(error);
      expect(message).to.contain(expectedSubstring);
    }
  }
  expect(rejected, "Expected transfer to revert").to.equal(true);
}

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

  // Registration paths: transfers that cross a settlement-layer boundary (GW-settled -> gateway, and
  // direct-settled <-> gateway/GW-settled) are not registered and must revert. Note: the reverse
  // direction (gateway -> GW-settled) IS a valid interop path — the gateway is a full interop
  // participant with the chains that settle on it — and is exercised by the happy-path tests' cluster.

  it("rejects transfers from GW-settled chains to the gateway chain", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    await expectTransferToRevert(
      executeTokenTransfer({
        sourceChainId: gwSettledChainIds[0],
        targetChainId: gatewayChainId,
        amount: "5",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });

  it("rejects transfers from direct-settled chains to the gateway chain across settlement layers", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    await expectTransferToRevert(
      executeTokenTransfer({
        sourceChainId: directSettledChainId,
        targetChainId: gatewayChainId,
        amount: "3",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });

  it("rejects transfers from direct-settled chains to GW-settled chains across settlement layers", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    await expectTransferToRevert(
      executeTokenTransfer({
        sourceChainId: directSettledChainId,
        targetChainId: gwSettledChainIds[0],
        amount: "3",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });
});
