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

describe("03 - Interop Transfer Registration Paths", function () {
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

  it("transfers from the gateway chain to GW-settled chains (L1-settled source is allowed)", async () => {
    // The gateway chain settles directly on L1; sending interop bundles from L1-settled chains is
    // allowed (the InteropCenter's NotInGatewayMode gate was removed), so this transfer completes
    // end-to-end: the bundle is sent from the gateway and executed on the GW-settled destination.
    const sourceToken = state.testTokens![gatewayChainId];
    const result = await executeTokenTransfer({
      sourceChainId: gatewayChainId,
      targetChainId: gwSettledChainIds[0],
      amount: "10",
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.targetTxHash, "bundle should execute on the destination chain").to.not.equal(null);
    const received = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(received.toString(), "destination balance should increase by the transferred amount").to.equal(
      result.amountWei
    );
  });

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
