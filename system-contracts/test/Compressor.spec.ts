import { expect } from "chai";
import type { BytesLike } from "ethers";
import { BigNumber } from "ethers";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-web3";
import * as zksync from "zksync-web3";
import type { Compressor } from "../typechain";
import { CompressorFactory } from "../typechain";
import {
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_COMPRESSOR_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TWO_IN_256,
} from "./shared/constants";
import { encodeCalldata, getMock, prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";

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
    it("non-bootloader failed to call", async () => {
      await expect(compressor.publishCompressedBytecode("0x", "0x0000")).to.be.revertedWith(
        "Callable only by the bootloader"
      );
    });

    it("invalid encoded length", async () => {
      const BYTECODE = "0xdeadbeefdeadbeef";
      const COMPRESSED_BYTECODE = "0x0001deadbeefdeadbeef00000000";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded data length should be 4 times shorter than the original bytecode");
    });

    it("chunk index is out of bounds", async () => {
      const BYTECODE = "0xdeadbeefdeadbeef";
      const COMPRESSED_BYTECODE = "0x0001deadbeefdeadbeef0001";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded chunk index is out of bounds");
    });

    it("chunk does not match the original bytecode", async () => {
      const BYTECODE = "0xdeadbeefdeadbeef1111111111111111";
      const COMPRESSED_BYTECODE = "0x0002deadbeefdeadbeef111111111111111100000000";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("Encoded chunk does not match the original bytecode");
    });

    it("invalid bytecode length in bytes", async () => {
      const BYTECODE = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
      const COMPRESSED_BYTECODE = "0x0001deadbeefdeadbeef000000000000";
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("po");
    });

    // Test case with too big bytecode is unrealistic because API cannot accept so much data.
    it("invalid bytecode length in words", async () => {
      const BYTECODE = "0x" + "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef".repeat(2);
      const COMPRESSED_BYTECODE = "0x0001deadbeefdeadbeef" + "0000".repeat(4 * 2);
      await expect(
        compressor.connect(bootloaderAccount).publishCompressedBytecode(BYTECODE, COMPRESSED_BYTECODE)
      ).to.be.revertedWith("pr");
    });

    it("successfully published", async () => {
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

interface StateDiff {
  key: BytesLike;
  index: number;
  initValue: BigNumber;
  finalValue: BigNumber;
}

function encodeStateDiffs(stateDiffs: StateDiff[]): string {
  const rawStateDiffs = [];
  for (const stateDiff of stateDiffs) {
    rawStateDiffs.push(
      ethers.utils.solidityPack(
        ["address", "bytes32", "bytes32", "uint64", "uint256", "uint256", "bytes"],
        [
          ethers.constants.AddressZero,
          ethers.constants.HashZero,
          stateDiff.key,
          stateDiff.index,
          stateDiff.initValue,
          stateDiff.finalValue,
          "0x" + "00".repeat(116),
        ]
      )
    );
  }
  return ethers.utils.hexlify(ethers.utils.concat(rawStateDiffs));
}

function compressStateDiffs(enumerationIndexSize: number, stateDiffs: StateDiff[]): string {
  let num_initial = 0;
  const initial = [];
  const repeated = [];
  for (const stateDiff of stateDiffs) {
    const addition = stateDiff.finalValue.sub(stateDiff.initValue).add(TWO_IN_256).mod(TWO_IN_256);
    const subtraction = stateDiff.initValue.sub(stateDiff.finalValue).add(TWO_IN_256).mod(TWO_IN_256);
    let op = 3;
    let min = stateDiff.finalValue;
    if (addition.lt(min)) {
      min = addition;
      op = 1;
    }
    if (subtraction.lt(min)) {
      min = subtraction;
      op = 2;
    }
    if (min.gte(BigNumber.from(2).pow(248))) {
      min = stateDiff.finalValue;
      op = 0;
    }
    let len = 0;
    const minHex = min.eq(0) ? "0x" : min.toHexString();
    if (op > 0) {
      len = (minHex.length - 2) / 2;
    }
    const metadata = (len << 3) + op;
    const enumerationIndexType = "uint" + (enumerationIndexSize * 8).toString();
    if (stateDiff.index === 0) {
      num_initial += 1;
      initial.push(ethers.utils.solidityPack(["bytes32", "uint8", "bytes"], [stateDiff.key, metadata, minHex]));
    } else {
      repeated.push(
        ethers.utils.solidityPack([enumerationIndexType, "uint8", "bytes"], [stateDiff.index, metadata, minHex])
      );
    }
  }
  return ethers.utils.hexlify(
    ethers.utils.concat([ethers.utils.solidityPack(["uint16"], [num_initial]), ...initial, ...repeated])
  );
}
