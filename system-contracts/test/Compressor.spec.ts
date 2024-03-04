import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-ethers";
import * as zksync from "zksync-ethers";
import type { Compressor } from "../typechain";
import { CompressorFactory } from "../typechain";
import {
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_COMPRESSOR_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TWO_IN_256,
} from "./shared/constants";
import { encodeCalldata, getMock, prepareEnvironment, setResult } from "./shared/mocks";
import { compressStateDiffs, deployContractOnAddress, encodeStateDiffs, getWallets } from "./shared/utils";

describe("Compressor tests", function () {
  let wallet: Wallet;
  let bootloaderAccount: ethers.Signer;
  let l1MessengerAccount: ethers.Signer;

  let compressor: Compressor;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];

    await deployContractOnAddress(TEST_COMPRESSOR_CONTRACT_ADDRESS, "Compressor");
    compressor = CompressorFactory.connect(TEST_COMPRESSOR_CONTRACT_ADDRESS, wallet);

    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
  });

  after(async function () {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });

    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS],
    });
  });

  describe("publishCompressedBytecode", function () {
    it("should revert when it's a non-bootloader call", async () => {
      await expect(compressor.publishCompressedBytecode("0x", "0x0000")).to.be.revertedWith(
        "Callable only by the bootloader"
      );
    });

    it("should revert when the dictionary length is incorrect", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      // Dictionary has only 1 entry, but the dictionary length is 2
      const COMPRESSED_BYTECODE = "0x0002" + "deadbeefdeadbeef" + "0000" + "0000" + "0000" + "0000";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded data length should be 4 times shorter than the original bytecode");
    });

    it("should revert when there is no encoded data", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      // Dictionary has 2 entries, but there is no encoded data
      const COMPRESSED_BYTECODE = "0x0002" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded data length should be 4 times shorter than the original bytecode");
    });

    it("should revert when the encoded data length is invalid", async () => {
      // Bytecode length is 32 bytes (4 chunks)
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      // Compressed bytecode is 14 bytes
      // Dictionary length is 2 bytes
      // Dictionary is 8 bytes (1 entry)
      // Encoded data is 4 bytes
      const COMPRESSED_BYTECODE = "0x0001" + "deadbeefdeadbeef" + "00000000";
      // The length of the encodedData should be 32 / 4 = 8 bytes
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded data length should be 4 times shorter than the original bytecode");
    });

    it("should revert when the dictionary has too many entries", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      // Dictionary has 5 entries
      // Encoded data has 4 entries
      const COMPRESSED_BYTECODE =
        "0x0005" +
        "deadbeefdeadbeef" +
        "deadbeefdeadbeef" +
        "deadbeefdeadbeef" +
        "deadbeefdeadbeef" +
        "deadbeefdeadbeef" +
        "0000" +
        "0000" +
        "0000" +
        "0000";
      // The dictionary should have at most encode data length entries
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Dictionary should have at most the same number of entries as the encoded data");
    });

    it("should revert when the encoded data has chunks where index is out of bounds", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      // Dictionary has 1 entry
      // Encoded data has 4 entries, three 0000 and one 0001
      const COMPRESSED_BYTECODE = "0x0001" + "deadbeefdeadbeef" + "0000" + "0000" + "0000" + "0001";
      // The dictionary has only 1 entry, so at the last entry of the encoded data the chunk index is out of bounds
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded chunk index is out of bounds");
    });

    it("should revert when the encoded data has chunks that does not match the original bytecode", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "1111111111111111";
      // Encoded data has 4 entries, but the first one points to the wrong chunk of the dictionary
      const COMPRESSED_BYTECODE =
        "0x0002" + "deadbeefdeadbeef" + "1111111111111111" + "0001" + "0000" + "0000" + "0001";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded chunk does not match the original bytecode");
    });

    it("should revert when the bytecode length in bytes is invalid", async () => {
      // Bytecode length is 24 bytes (3 chunks), which is invalid because it's not a multiple of 32
      const BYTECODE = "0x" + "deadbeefdeadbeef" + "deadbeefdeadbeef" + "deadbeefdeadbeef";
      const COMPRESSED_BYTECODE = "0x0001" + "deadbeefdeadbeef" + "0000" + "0000" + "0000";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("po");
    });

    it("should revert when the bytecode length in words is odd", async () => {
      // Bytecode length is 2 words (64 bytes), which is invalid because it's odd
      const BYTECODE = "0x" + "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef".repeat(2);
      const COMPRESSED_BYTECODE = "0x0001" + "deadbeefdeadbeef" + "0000".repeat(4 * 2);
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("pr");
    });

    // Test case with too big bytecode is unrealistic because API cannot accept so much data.

    it("should successfully publish the bytecode", async () => {
      const BYTECODE =
        "0x000200000000000200010000000103550000006001100270000000150010019d0000000101200190000000080000c13d0000000001000019004e00160000040f0000000101000039004e00160000040f0000001504000041000000150510009c000000000104801900000040011002100000000001310019000000150320009c0000000002048019000000600220021000000000012100190000004f0001042e000000000100001900000050000104300000008002000039000000400020043f0000000002000416000000000110004c000000240000613d000000000120004c0000004d0000c13d000000200100003900000100001004430000012000000443000001000100003900000040020000390000001d03000041004e000a0000040f000000000120004c0000004d0000c13d0000000001000031000000030110008c0000004d0000a13d0000000101000367000000000101043b0000001601100197000000170110009c0000004d0000c13d0000000101000039000000000101041a0000000202000039000000000202041a000000400300043d00000040043000390000001805200197000000000600041a0000000000540435000000180110019700000020043000390000000000140435000000a0012002700000001901100197000000600430003900000000001404350000001a012001980000001b010000410000000001006019000000b8022002700000001c02200197000000000121019f0000008002300039000000000012043500000018016001970000000000130435000000400100043d0000000002130049000000a0022000390000000003000019004e000a0000040f004e00140000040f0000004e000004320000004f0001042e000000500001043000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffffffffffffff000000000000000000000000000000000000000000000000000000008903573000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffffffffffffffffffffffffffffffffffffff0000000000000000000000000000000000000000000000000000000000ffffff0000000000008000000000000000000000000000000000000000000000000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff80000000000000000000000000000000000000000000000000000000000000007fffff00000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
      const COMPRESSED_BYTECODE =
        "0x00510000000000000000ffffffffffffffff0000004d0000c13d00000000ffffffff0000000000140435004e000a0000040f000000000120004c00000050000104300000004f0001042e0000000101000039004e00160000040f0000000001000019000000020000000000000000007fffffffffffffff80000000000000000080000000000000ffffff8903573000000000ffffffff000000000000004e00000432004e00140000040f0000000003000019000000a0022000390000000002130049000000400100043d0000000000130435000000180160019700000000001204350000008002300039000000000121019f0000001c02200197000000b80220027000000000010060190000001b010000410000001a0120019800000060043000390000001901100197000000a001200270000000200430003900000018011001970000000000540435000000000600041a00000018052001970000004004300039000000400300043d000000000202041a0000000202000039000000000101041a000000170110009c0000001601100197000000000101043b00000001010003670000004d0000a13d000000030110008c00000000010000310000001d0300004100000040020000390000010001000039000001200000044300000100001004430000002001000039000000240000613d000000000110004c0000000002000416000000400020043f0000008002000039000000000121001900000060022002100000000002048019000000150320009c000000000131001900000040011002100000000001048019000000150510009c0000001504000041000000080000c13d0000000101200190000000150010019d0000006001100270000100000001035500020000000000020050004f004e004d004c004b000b000a0009000a004a004900480047004600450044004300420008000b000700410040003f003e003d00060002003c003b003a003900380037000500060002003600350034003300320031003000020009002f002e002d002c002b002a002900280027002600040025002400230004002200210020001f001e001d001c001b001a001900180017001600150005001400130008000700000000000000000000000000030012000000000000001100000000000000000003000100010000000000000010000f000000000000000100010001000e000000000000000d000c0000000000000000000000000000";
      await setResult("L1Messenger", "sendToL1", [COMPRESSED_BYTECODE], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await expect(compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE))
        .to.emit(getMock("KnownCodesStorage"), "Called")
        .withArgs(
          0,
          await encodeCalldata("KnownCodesStorage", "markBytecodeAsPublished", [zksync.utils.hashBytecode(BYTECODE)])
        );
    });

    // documentation example from https://github.com/matter-labs/zksync-era/blob/main/docs/guides/advanced/compression.md
    it("documentation example", async () => {
      const BYTECODE =
        "0x000000000000000A000000000000000D000000000000000A000000000000000C000000000000000B000000000000000A000000000000000D000000000000000A000000000000000D000000000000000A000000000000000B000000000000000B";
      const COMPRESSED_BYTECODE =
        "0x0004000000000000000A000000000000000D000000000000000B000000000000000C000000010000000300020000000100000001000000020002";
      await setResult("L1Messenger", "sendToL1", [COMPRESSED_BYTECODE], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await expect(compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE))
        .to.emit(getMock("KnownCodesStorage"), "Called")
        .withArgs(
          0,
          await encodeCalldata("KnownCodesStorage", "markBytecodeAsPublished", [zksync.utils.hashBytecode(BYTECODE)])
        );
    });
  });

  describe("verifyCompressedStateDiffs", function () {
    it("non l1 messenger failed to call", async () => {
      await expect(compressor.verifyCompressedStateDiffs(0, 8, "0x", "0x0000")).to.be.revertedWith(
        "Inappropriate caller"
      );
    });

    it("enumeration index size is too large", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 0,
          initValue: BigNumber.from(0),
          finalValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901234"),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[0].key = "0x1234567890123456789012345678901234567890123456789012345678901233";
      const compressedStateDiffs = compressStateDiffs(9, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 9, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("enumeration index size is too large");
    });

    it("initial write key mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 0,
          initValue: BigNumber.from(1),
          finalValue: BigNumber.from(0),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[0].key = "0x1234567890123456789012345678901234567890123456789012345678901233";
      const compressedStateDiffs = compressStateDiffs(4, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 4, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("iw: initial key mismatch");
    });

    it("repeated write key mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 1,
          initValue: BigNumber.from(1),
          finalValue: BigNumber.from(0),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[0].index = 2;
      const compressedStateDiffs = compressStateDiffs(8, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 8, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("rw: enum key mismatch");
    });

    it("no compression value mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 1,
          initValue: BigNumber.from(1),
          finalValue: BigNumber.from(0),
        },
        {
          key: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          index: 0,
          initValue: TWO_IN_256.div(2),
          finalValue: TWO_IN_256.sub(2),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[1].finalValue = TWO_IN_256.sub(1);
      const compressedStateDiffs = compressStateDiffs(3, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(2, 3, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("transform or no compression: compressed and final mismatch");
    });

    it("transform value mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 255,
          initValue: BigNumber.from(1),
          finalValue: BigNumber.from(0),
        },
        {
          key: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          index: 0,
          initValue: TWO_IN_256.div(2),
          finalValue: BigNumber.from(1),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[1].finalValue = BigNumber.from(0);
      const compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(2, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("transform or no compression: compressed and final mismatch");
    });

    it("add value mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901235",
          index: 255,
          initValue: TWO_IN_256.div(2).sub(2),
          finalValue: TWO_IN_256.div(2).sub(1),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[0].finalValue = TWO_IN_256.div(2);
      const compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("add: initial plus converted not equal to final");
    });

    it("sub value mismatch", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 0,
          initValue: TWO_IN_256.div(4),
          finalValue: TWO_IN_256.div(4).sub(5),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs[0].finalValue = TWO_IN_256.div(4).sub(1);
      const compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("sub: initial minus converted not equal to final");
    });

    it("invalid operation", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 0,
          initValue: TWO_IN_256.div(4),
          finalValue: TWO_IN_256.div(4).sub(5),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      let compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      const compressedStateDiffsCharArray = compressedStateDiffs.split("");
      compressedStateDiffsCharArray[2 + 4 + 64 + 1] = "f";
      compressedStateDiffs = compressedStateDiffsCharArray.join("");
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(1, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("unsupported operation");
    });

    it("Incorrect number of initial storage diffs", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 0,
          initValue: TWO_IN_256.div(4),
          finalValue: TWO_IN_256.div(4).sub(5),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901239",
          index: 121,
          initValue: TWO_IN_256.sub(1),
          finalValue: BigNumber.from(0),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs.push({
        key: "0x0234567890123456789012345678901234567890123456789012345678901231",
        index: 0,
        initValue: BigNumber.from(0),
        finalValue: BigNumber.from(1),
      });
      const compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(2, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("Incorrect number of initial storage diffs");
    });

    it("Extra data in compressed state diffs", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 0,
          initValue: TWO_IN_256.div(4),
          finalValue: TWO_IN_256.div(4).sub(5),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901239",
          index: 121,
          initValue: TWO_IN_256.sub(1),
          finalValue: BigNumber.from(0),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      stateDiffs.push({
        key: "0x0234567890123456789012345678901234567890123456789012345678901231",
        index: 1,
        initValue: BigNumber.from(0),
        finalValue: BigNumber.from(1),
      });
      const compressedStateDiffs = compressStateDiffs(1, stateDiffs);
      await expect(
        compressor.connect(l1MessengerAccount).verifyCompressedStateDiffs(2, 1, encodedStateDiffs, compressedStateDiffs)
      ).to.be.revertedWith("Extra data in _compressedStateDiffs");
    });

    it("successfully verified", async () => {
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901230",
          index: 0,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901231"),
          finalValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901230"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901232",
          index: 1,
          initValue: TWO_IN_256.sub(1),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 0,
          initValue: TWO_IN_256.div(2),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 2323,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901237"),
          finalValue: BigNumber.from("0x0239329298382323782378478237842378478237847237237872373272373272"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901238",
          index: 2,
          initValue: BigNumber.from(0),
          finalValue: BigNumber.from(1),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      const compressedStateDiffs = compressStateDiffs(4, stateDiffs);
      const tx = {
        from: TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
        to: compressor.address,
        data: compressor.interface.encodeFunctionData("verifyCompressedStateDiffs", [
          5,
          4,
          encodedStateDiffs,
          compressedStateDiffs,
        ]),
      };
      // eth_call to get return data
      expect(await ethers.provider.call(tx)).to.be.eq(ethers.utils.keccak256(encodedStateDiffs));
    });
  });
});
