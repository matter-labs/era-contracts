import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, createPrecompileContractAtAddress, enableEvmEmulation, getWallets } from "../shared/utils";
import { MODEXP_ADDRESS } from "../shared/constants";
import { deployEvmPrecompileCaller } from "./shared/utils";

describe("Modexp tests", function () {
  for (const environment of ["EraVM"]) {
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

      describe("Ethereum Tests", function () {
        const testCases = [
          ["0 bytes: (0, 0) mod 0", "0x" + "00".repeat(96), "0x"],
          ["0 bytes: (0, 0) mod 1", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "01", "0x00"],
          ["0 bytes: (0, 0) mod 2", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "02", "0x00"],
          ["0 bytes: (0, 0) mod 4", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "04", "0x00"],
          ["0 bytes: (0, 0) mod 8", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "08", "0x00"],
          ["0 bytes: (0, 0) mod 16", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "10", "0x00"],
          ["0 bytes: (0, 0) mod 32", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "20", "0x00"],
          ["0 bytes: (0, 0) mod 64", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "40", "0x00"],
          ["0 bytes: (0, 0) mod 100", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "64", "0x00"],
          ["0 bytes: (0, 0) mod 128", "0x" + "00".repeat(64) + "01".padStart(64, "0") + "80", "0x00"],
        ];

        for (const [label, input, expected] of testCases) {
          it(label, async () => {
            const returnData = await callFallback(modexp, input);
            expect(returnData).to.equal(expected);
          });
        }

        // Additional test cases will be appended here
      });
    });
  }
});
