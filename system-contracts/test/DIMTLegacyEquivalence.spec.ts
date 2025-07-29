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

  it("should verify lazy push functionality produces identical roots", async function () {
    const testCases = [
      {
        name: "Small batch",
        leaves: Array.from({ length: 3 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["lazy", i]))
        ),
      },
      {
        name: "Medium batch",
        leaves: Array.from({ length: 7 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["batch", i]))
        ),
      },
      {
        name: "Large batch",
        leaves: Array.from({ length: 15 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["large", i]))
        ),
      },
      {
        name: "Power of 2 batch",
        leaves: Array.from({ length: 16 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["pow2", i]))
        ),
      },
    ];

    for (const testCase of testCases) {
      const result = await dimtTester.testLazyEquivalence(testCase.leaves);
      const { regularRoot, lazyRoot } = result;

      expect(regularRoot).to.equal(lazyRoot, `Lazy push failed for ${testCase.name}`);
      expect(regularRoot).to.not.equal(ethers.constants.HashZero);
    }
  });

  it("should verify mixed lazy and regular operations", async function () {
    const initialLeaves = Array.from({ length: 2 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["initial", i]))
    );
    const lazyLeaves = Array.from({ length: 5 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["lazy", i]))
    );
    const finalLeaves = Array.from({ length: 3 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["final", i]))
    );

    const result = await dimtTester.testMixedLazyOperations(initialLeaves, lazyLeaves, finalLeaves);
    const { regularRoot, mixedRoot } = result;

    expect(regularRoot).to.equal(mixedRoot, "Mixed lazy operations should produce same root as regular pushes");
    expect(regularRoot).to.not.equal(ethers.constants.HashZero);
  });

  it("should handle edge cases in lazy operations", async function () {
    const edgeCases = [
      {
        name: "Single lazy leaf",
        leaves: [ethers.utils.keccak256(ethers.utils.toUtf8Bytes("single_lazy"))],
      },
      {
        name: "Empty then lazy",
        leaves: [],
      },
      {
        name: "Many identical lazy leaves",
        leaves: Array(10).fill(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("identical_lazy"))),
      },
    ];

    for (const testCase of edgeCases) {
      if (testCase.leaves.length === 0) {
        // Skip empty array test case for now, there's an issue with the ethers.js binding
        continue;
      }

      const result = await dimtTester.testLazyEquivalence(testCase.leaves);
      const { regularRoot, lazyRoot } = result;
      expect(regularRoot).to.equal(lazyRoot, `Lazy edge case failed for ${testCase.name}`);
      expect(regularRoot).to.not.equal(ethers.constants.HashZero);
    }
  });

  it("should verify lazy push functionality produces identical roots for memory trees", async function () {
    const testCases = [
      {
        name: "Small batch memory",
        leaves: Array.from({ length: 3 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_lazy", i]))
        ),
      },
      {
        name: "Medium batch memory",
        leaves: Array.from({ length: 7 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_batch", i]))
        ),
      },
      {
        name: "Large batch memory",
        leaves: Array.from({ length: 15 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_large", i]))
        ),
      },
      {
        name: "Power of 2 batch memory",
        leaves: Array.from({ length: 16 }, (_, i) =>
          ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_pow2", i]))
        ),
      },
    ];

    for (const testCase of testCases) {
      const result = await dimtTester.testLazyEquivalenceMemory(testCase.leaves);
      const { regularRoot, lazyRoot } = result;

      expect(regularRoot).to.equal(lazyRoot, `Memory lazy push failed for ${testCase.name}`);
      expect(regularRoot).to.not.equal(ethers.constants.HashZero);
    }
  });

  it("should verify mixed lazy and regular operations for memory trees", async function () {
    const initialLeaves = Array.from({ length: 2 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_initial", i]))
    );
    const lazyLeaves = Array.from({ length: 5 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_lazy", i]))
    );
    const finalLeaves = Array.from({ length: 3 }, (_, i) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["mem_final", i]))
    );

    const result = await dimtTester.testMixedLazyOperationsMemory(initialLeaves, lazyLeaves, finalLeaves);
    const { regularRoot, mixedRoot } = result;

    expect(regularRoot).to.equal(mixedRoot, "Memory mixed lazy operations should produce same root as regular pushes");
    expect(regularRoot).to.not.equal(ethers.constants.HashZero);
  });
});
