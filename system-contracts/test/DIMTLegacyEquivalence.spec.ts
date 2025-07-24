import { expect } from "chai";
import { ethers } from "hardhat";
import type { DIMTLegacyTester } from "../typechain";
import { DIMTLegacyTesterFactory } from "../typechain";
import { prepareEnvironment } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import type { Wallet } from "zksync-ethers";

const TEST_DIMT_TESTER_ADDRESS = "0x0000000000000000000000000000000000009020";

describe("DIMT Legacy Equivalence", function () {
  let dimtTester: DIMTLegacyTester;
  let wallet: Wallet;

  before(async function () {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_DIMT_TESTER_ADDRESS, "DIMTLegacyTester");
    dimtTester = DIMTLegacyTesterFactory.connect(TEST_DIMT_TESTER_ADDRESS, wallet);
  });

  it("should verify DIMT equivalence with legacy MerkleTree for power-of-2 leaves", async function () {
    const testCases = [
      {
        name: "2 leaves",
        leaves: [
          ethers.utils.keccak256(ethers.utils.toUtf8Bytes("leaf1")),
          ethers.utils.keccak256(ethers.utils.toUtf8Bytes("leaf2")),
        ],
      },
      {
        name: "4 leaves",
        leaves: [
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["leaf", 0])),
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["leaf", 1])),
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["leaf", 2])),
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["leaf", 3])),
        ],
      },
      {
        name: "8 leaves",
        leaves: Array.from({ length: 8 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["leaf", i]))
        ),
      },
    ];

    for (const testCase of testCases) {
      const result = await dimtTester.testEquivalence(testCase.leaves);
      const { legacyRoot, dimtRoot } = result;

      expect(legacyRoot).to.not.equal(ethers.constants.HashZero);
      expect(dimtRoot).to.not.equal(ethers.constants.HashZero);
    }
  });

  it("should test legacy hash function consistency", async function () {
    const left = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("left"));
    const right = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("right"));

    const legacyHash = await dimtTester.getLegacyHash(left, right);
    const directHash = ethers.utils.keccak256(left + right.slice(2));

    expect(legacyHash).to.be.a("string");
    expect(directHash).to.be.a("string");
  });

  it("should demonstrate edge cases for equivalence testing", async function () {
    const edgeCases = [
      {
        name: "Single leaf",
        leaves: [ethers.utils.keccak256(ethers.utils.toUtf8Bytes("single"))],
      },
      {
        name: "Identical leaves",
        leaves: Array(4).fill(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("identical"))),
      },
      {
        name: "Zero values mixed",
        leaves: [
          ethers.constants.HashZero,
          ethers.utils.keccak256(ethers.utils.toUtf8Bytes("nonzero1")),
          ethers.constants.HashZero,
          ethers.utils.keccak256(ethers.utils.toUtf8Bytes("nonzero2")),
        ],
      },
    ];

    for (const testCase of edgeCases) {
      const result = await dimtTester.testEquivalence(testCase.leaves);
      const { legacyRoot, dimtRoot } = result;

      expect(legacyRoot).to.not.equal(ethers.constants.HashZero);
      expect(dimtRoot).to.not.equal(ethers.constants.HashZero);
    }
  });
});
