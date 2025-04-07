import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, deployContractYul, enableEvmEmulation } from "../shared/utils";
import { deployEvmPrecompileCaller } from "./shared/utils";

describe("Identity tests", function () {
  let identity: Contract;

  before(async () => {
    identity = await deployContractYul("Identity", "precompiles");
  });

  describe("Ethereum tests", function () {
    it("Returns data", async () => {
      const data = "0xff00ff00ff00ff00ff";
      const returnData = await callFallback(identity, data);
      expect(returnData).to.be.equal(data);
    });

    it("Returns data in EVM context", async () => {
      enableEvmEmulation();
      const precompileCaller = await deployEvmPrecompileCaller(identity.address);

      const data = "0xff00ff00ff00ff00ff";
      const returnData = await callFallback(precompileCaller, data);
      expect(returnData).to.be.equal(data);
    });
  });
});
