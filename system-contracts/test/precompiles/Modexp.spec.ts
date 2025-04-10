import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, createPrecompileContractAtAddress, enableEvmEmulation } from "../shared/utils";
import { MODEXP_ADDRESS } from "../shared/constants";
import { deployEvmPrecompileCaller } from "./shared/utils";

describe("Modexp tests", function () {
  for (const environment of ["EraVM", "EVM"]) {
    describe(`Tests in (${environment})`, function () {
      let modexp: Contract;

      before(async () => {
        if (environment == "EraVM") {
          modexp = createPrecompileContractAtAddress(MODEXP_ADDRESS);
        } else if (environment == "EVM") {
          await enableEvmEmulation();
          const wallet = getWallets()[0];
          modexp = await deployEvmPrecompileCaller(MODEXP_ADDRESS, wallet);
        } else {
          throw new Error("Invalid environment");
        }
      });

      describe("Tests", function () {
        // FIXME: add tests
        it("Empty input", async () => {
          const returnData = await callFallback(modexp, "0x");

          // TODO: check if this is valid
          expect(returnData).to.be.equal("0x0000000000000000000000000000000000000000000000000000000000000000");
        });
      });
    });
  }
});
