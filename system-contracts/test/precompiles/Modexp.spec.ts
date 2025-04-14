import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, createPrecompileContractAtAddress, enableEvmEmulation, getWallets } from "../shared/utils";
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

      describe("Ethereum Tests", function () {
        it("Test 1: (0, 0) mod 0", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "00".padStart(64, "0");
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 2: (0, 0) mod 1", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "01";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 3: (0, 0) mod 2", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "02";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 4: (0, 0) mod 4", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "04";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 5: (0, 0) mod 8", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "08";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 6: (0, 0) mod 16", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "10";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 7: (0, 0) mod 32", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "20";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 8: (0, 0) mod 64", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "40";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 9: (0, 0) mod 100", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "64";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        it("Test 10: (0, 0) mod 128", async () => {
          const input = "0x" + "00".padStart(64, "0") + "00".padStart(64, "0") + "01".padStart(64, "0") + "80";
          const returnData = await callFallback(modexp, input);
          console.log("Returned:", returnData);
        });

        // it("Test 4: (1^1) mod 1", async () => {
        //   const input = "0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001010101";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x0");
        // });

        it("Test 6: (3^9984) mod 39936", async () => {
          const input =
            "0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020327009c00";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x6801");
        });

        // it("Test 7: (9^37111) mod 37111", async () => {
        //   const input = "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000209390f0";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x1c3b");
        // });

        // it("Test 8: (49^2401) mod 2401", async () => {
        //   const input = "0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002311961";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x0");
        // });

        // it("Test 9: (37120^22411) mod 22000", async () => {
        //   const input = "0x00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000290f079081f50";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x3e80");
        // });

        it("Test 10: (39936^1) mod 55201", async () => {
          const input =
            "0x0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000029c0001d7a1";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x9c00");
        });

        it("Test 11: (55190^55190) mod 42965", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000002" + // baseLen = 2
            "0000000000000000000000000000000000000000000000000000000000000002" + // expLen = 2
            "0000000000000000000000000000000000000000000000000000000000000002" + // modLen = 2
            "d796" + // base = 55190
            "d796" + // exponent = 55190
            "a7d5"; // modulus = 42965
          const returnData = await callFallback(modexp, input);
          console.log(returnData);
          expect(returnData).to.equal("0x866a");
        });

        // it("Test 12: (0^0) mod 2", async () => {
        //   const input = "0x" +
        //     "0000000000000000000000000000000000000000000000000000000000000000" +
        //     "0000000000000000000000000000000000000000000000000000000000000000" +
        //     "0000000000000000000000000000000000000000000000000000000000000001" +
        //     "00" + "00" + "02";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x01");
        // });

        // it("Test 13: (1^0) mod 2", async () => {
        //   const input = "0x" +
        //     "0000000000000000000000000000000000000000000000000000000000000001" +
        //     "0000000000000000000000000000000000000000000000000000000000000000" +
        //     "0000000000000000000000000000000000000000000000000000000000000001" +
        //     "01" + "00" + "02";
        //   const returnData = await callFallback(modexp, input);
        //   expect(returnData).to.equal("0x01");
        // });

        it("Test 14: (1^1) mod 2", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "01" +
            "01" +
            "02";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x01");
        });

        it("Test 15: (2^2) mod 5", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "02" +
            "02" +
            "05";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x04");
        });

        it("Test 16: (3^2) mod 2", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "03" +
            "02" +
            "02";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x01");
        });

        it("Test 17: (2^1) mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "02" +
            "01" +
            "01";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("Test 18: (0^2) mod 3", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "00" +
            "02" +
            "03";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("Test 19: (3^0) mod 5", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "03" +
            "00" +
            "05";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x01");
        });

        it("0 bytes: (0, 0) mod 0", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000000" + // baseLen
            "0000000000000000000000000000000000000000000000000000000000000000" + // expLen
            "0000000000000000000000000000000000000000000000000000000000000000"; // modLen
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.be.equal("0x");
        });

        it("1-byte base: (2^0, 0) mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" + // baseLen = 1
            "0000000000000000000000000000000000000000000000000000000000000001" + // expLen = 1
            "0000000000000000000000000000000000000000000000000000000000000001" + // modLen = 1
            "02" +
            "00" +
            "01"; // base=2, exp=0, mod=1
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("Small numbers: (2^5) mod 13 = 6", async () => {
          const base = "02",
            exp = "05",
            mod = "0d";
          const input =
            "0x" + "01".padStart(64, "0") + "01".padStart(64, "0") + "01".padStart(64, "0") + base + exp + mod;
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x06");
        });

        it("Base = 0, any exp, mod != 0 → result = 0", async () => {
          const input =
            "0x" + "01".padStart(64, "0") + "01".padStart(64, "0") + "01".padStart(64, "0") + "00" + "02" + "0f";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("Any base, exp = 0, mod != 0 → result = 1", async () => {
          const input =
            "0x" + "01".padStart(64, "0") + "01".padStart(64, "0") + "01".padStart(64, "0") + "03" + "00" + "05"; // base = 3, exp = 0, mod = 5
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x01");
        });

        it("Max supported bytes (32-byte base/exp/mod)", async () => {
          const base = "0".repeat(63) + "2"; // 0x02 padded to 32 bytes
          const exp = "0".repeat(63) + "5";
          const mod = "0".repeat(63) + "d";
          const input =
            "0x" + "20".padStart(64, "0") + "20".padStart(64, "0") + "20".padStart(64, "0") + base + exp + mod;
          const returnData = await callFallback(modexp, input);
          expect(returnData.slice(-2)).to.equal("06");
        });

        it("Base > MAX_BASE_BYTES_SUPPORTED → should revert", async () => {
          const base = "01".repeat(33); // 33 bytes
          const input =
            "0x" + "21".padStart(64, "0") + "01".padStart(64, "0") + "01".padStart(64, "0") + base + "02" + "03";
          await expect(callFallback(modexp, input)).to.be.reverted;
        });

        it("Exp > MAX_EXP_BYTES_SUPPORTED → should revert", async () => {
          const exp = "01".repeat(33); // 33 bytes
          const input =
            "0x" + "01".padStart(64, "0") + "21".padStart(64, "0") + "01".padStart(64, "0") + "02" + exp + "03";
          await expect(callFallback(modexp, input)).to.be.reverted;
        });

        it("Mod > MAX_MOD_BYTES_SUPPORTED → should revert", async () => {
          const mod = "01".repeat(33); // 33 bytes
          const input =
            "0x" + "01".padStart(64, "0") + "01".padStart(64, "0") + "21".padStart(64, "0") + "02" + "03" + mod;
          await expect(callFallback(modexp, input)).to.be.reverted;
        });
      });
    });
  }
});
