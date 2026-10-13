import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { expectTokenTransfer } from "../../src/helpers/token-transfer";
import { getChainIdsByRole } from "../../src/core/utils";
import { randomBigNumber } from "../../src/helpers/balance-helpers";

const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

describe("06 - Gateway Interop (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
  });

  it("transfers tokens between GW-settled chains", async () => {
    await expectTokenTransfer({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
      amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });
  });

  it("transfers tokens in reverse direction between GW-settled chains", async () => {
    await expectTokenTransfer({
      sourceChainId: gwSettledChainIds[1],
      targetChainId: gwSettledChainIds[0],
      amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });
  });
});
