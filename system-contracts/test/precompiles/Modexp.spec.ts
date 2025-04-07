import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, createPrecompileContractAtAddress, enableEvmEmulation } from "../shared/utils";
import { MODEXP_ADDRESS } from "../shared/constants";
import { deployEvmPrecompileCaller } from "./shared/utils";

describe("Modexp tests", function () {
  for (const environment in ["EraVM, EVM"]) {
    describe(`Tests in (${environment})`, function () {
      let modexp: Contract;

      before(async () => {
        if (environment == "EraVM") {
          modexp = await createPrecompileContractAtAddress(MODEXP_ADDRESS);
        } else {
          await enableEvmEmulation();
          modexp = await deployEvmPrecompileCaller(MODEXP_ADDRESS);
        }
      });

      describe("Tests", function () {
        // FIXME: add tests
      });
    });
  }
});
