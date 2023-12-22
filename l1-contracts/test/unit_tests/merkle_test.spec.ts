import { expect } from "chai";
import * as hardhat from "hardhat";
import type { MerkleTest } from "../../typechain-types";
import { MerkleTest__factory } from "../../typechain-types";
import { MerkleTree } from "merkletreejs";
import { getCallRevertReason } from "./utils";
import * as ethers from "ethers";

describe("Merkle lib tests", function () {
  let merkleTest: MerkleTest;

  before(async () => {
    const contractFactory = await hardhat.ethers.getContractFactory("MerkleTest");
    const contract = await contractFactory.deploy();
    merkleTest = MerkleTest__factory.connect(await contract.getAddress(), contract.runner);
  });

  describe("should calculate root correctly", function () {
    let elements;
    let merkleTree;

    before(async () => {
      elements = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        .split("")
        .map((val) => ethers.toUtf8Bytes(val));
      merkleTree = new MerkleTree(elements, ethers.keccak256, { hashLeaves: true });
    });

    it("first element", async () => {
      const index = 0;
      const leaf = ethers.keccak256(elements[index]);
      const proof = merkleTree.getHexProof(leaf, index);

      const rootFromContract = await merkleTest.calculateRoot(proof, index, leaf);
      expect(rootFromContract).to.equal(merkleTree.getHexRoot());
    });

    it("middle element", async () => {
      const index = Math.ceil(elements.length / 2);
      const leaf = ethers.keccak256(elements[index]);
      const proof = merkleTree.getHexProof(leaf, index);

      const rootFromContract = await merkleTest.calculateRoot(proof, index, leaf);
      expect(rootFromContract).to.equal(merkleTree.getHexRoot());
    });

    it("last element", async () => {
      const index = elements.length - 1;
      const leaf = ethers.keccak256(elements[index]);
      const proof = merkleTree.getHexProof(leaf, index);

      const rootFromContract = await merkleTest.calculateRoot(proof, index, leaf);
      expect(rootFromContract).to.equal(merkleTree.getHexRoot());
    });
  });

  it("should fail trying calculate root with empty path", async () => {
    const revertReason = await getCallRevertReason(merkleTest.calculateRoot([], 0, ethers.ZeroHash));
    expect(revertReason).equal("xc");
  });

  it("should fail trying calculate root with too big leaf index", async () => {
    const bigIndex = 2n^255n;
    const revertReason = await getCallRevertReason(
      merkleTest.calculateRoot([ethers.ZeroHash], bigIndex, ethers.ZeroHash)
    );
    expect(revertReason).equal("px");
  });
});
