import { expect } from "chai";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdByRole, getChainIdsByRole } from "../../src/core/utils";

async function expectDestinationChainNotRegistered(promise: Promise<unknown>): Promise<void> {
  try {
    await promise;
    throw new Error("Expected transfer to fail with DestinationChainNotRegistered");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    expect(message).to.contain("DestinationChainNotRegistered");
  }
}

describe("03 - Interop Transfer (Registration Constraints)", function () {
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

  it("rejects transfers from gateway to GW-settled chains without real registration", async () => {
    const sourceToken = state.testTokens![gatewayChainId];
    await expectDestinationChainNotRegistered(
      executeTokenTransfer({
        sourceChainId: gatewayChainId,
        targetChainId: gwSettledChainIds[0],
        amount: "10",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });

  it("rejects transfers from GW-settled chains to the gateway chain", async () => {
    const sourceToken = state.testTokens![gwSettledChainIds[0]];
    await expectDestinationChainNotRegistered(
      executeTokenTransfer({
        sourceChainId: gwSettledChainIds[0],
        targetChainId: gatewayChainId,
        amount: "5",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });

  it("rejects transfers from direct-settled chains to the gateway chain", async () => {
    const sourceToken = state.testTokens![directSettledChainId];
    await expectDestinationChainNotRegistered(
      executeTokenTransfer({
        sourceChainId: directSettledChainId,
        targetChainId: gatewayChainId,
        amount: "3",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });
});
