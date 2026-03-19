import { expect } from "chai";
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

  it("currently rejects transfers from gateway to GW-settled chains in the harness", async () => {
    const sourceToken = state.testTokens![gatewayChainId];
    await expectTransferToRevert(
      executeTokenTransfer({
        sourceChainId: gatewayChainId,
        targetChainId: gwSettledChainIds[0],
        amount: "10",
        sourceTokenAddress: sourceToken,
        logger: (line: string) => console.log(`[interop] ${line}`),
      })
    );
  });

  it("currently rejects transfers from GW-settled chains to the gateway chain in the harness", async () => {
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
