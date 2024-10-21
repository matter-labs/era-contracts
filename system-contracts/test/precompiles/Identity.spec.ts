import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, deployContractYul } from "../shared/utils";

describe.only("EcAdd tests", function () {
  let identity: Contract;

  before(async () => {
    identity = await deployContractYul("Identity", "precompiles");
  });

  describe("Ethereum tests", function () {
    it("Returns data", async () => {
      const data = "0xff00ff00ff00ff00ff";
      const returnData = await callFallback(identity, data);
      expect(returnData).to.be.equal(
        data
      );
    });
  });
});
