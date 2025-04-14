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
        it("0^0 mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" + // baseLen = 1
            "0000000000000000000000000000000000000000000000000000000000000001" + // expLen = 1
            "0000000000000000000000000000000000000000000000000000000000000001" + // modLen = 1
            "00" + // base=0
            "00" + // exp=0
            "01"; // mod=1
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("0^1 mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "00" +
            "01" +
            "01";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("1^0 mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "01" +
            "00" +
            "01";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("1^1 mod 1", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "01" +
            "01" +
            "01";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("3^5 mod 100", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "03" +
            "05" +
            "64"; // 100 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x2b"); // 43 in hex
        });

        it("3^9984 mod 39936", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000002" + // expLen = 2
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "03" +
            "2700" + // 9984 in hex
            "9c00"; // 39936 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x6801");
        });

        it("49^2401 mod 2401", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "31" + // 49 in hex
            "0961" + // 2401 in hex
            "0961"; // 2401 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x0000");
        });

        it("37120^37111 mod 37111", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "9100" + // 37120 in hex
            "90f7" + // 37111 in hex
            "90f7"; // 37111 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x1c3b");
        });

        it("39936^1 mod 55201", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "9c00" + // 39936 in hex
            "01" +
            "d7a1"; // 55201 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x9c00");
        });

        it("55190^55190 mod 42965", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "0000000000000000000000000000000000000000000000000000000000000002" +
            "d796" + // 55190 in hex
            "d796" + // 55190 in hex
            "a7d5"; // 42965 in hex
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x866a");
        });

        // Edge cases
        it("0^0 mod 0", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "00" +
            "00" +
            "00";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
        });

        it("0^1 mod 0", async () => {
          const input =
            "0x" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "00" +
            "01" +
            "00";
          const returnData = await callFallback(modexp, input);
          expect(returnData).to.equal("0x00");
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
