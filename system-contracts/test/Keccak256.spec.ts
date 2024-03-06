import type { KeccakTest } from "../typechain";
import { KeccakTestFactory } from "../typechain";
import { REAL_KECCAK256_CONTRACT_ADDRESS } from "./shared/constants";
import { getWallets, loadArtifact, publishBytecode, setCode, getCode } from "./shared/utils";
import { ethers } from "hardhat";
import { readYulBytecode } from "../scripts/utils";
import { Language } from "../scripts/constants";
import type { BytesLike } from "ethers";
import { prepareEnvironment } from "./shared/mocks";
import { expect } from "chai";

describe("Keccak256 tests", function () {
  let keccakTest: KeccakTest;
  let oldKeccakCode: string;

  // Kernel space address, needed to enable mimicCall
  const KECCAK_TEST_ADDRESS = "0x0000000000000000000000000000000000009000";

  before(async () => {
    await prepareEnvironment();
    await setCode(KECCAK_TEST_ADDRESS, (await loadArtifact("KeccakTest")).bytecode);

    oldKeccakCode = await getCode(REAL_KECCAK256_CONTRACT_ADDRESS);

    keccakTest = KeccakTestFactory.connect(KECCAK_TEST_ADDRESS, getWallets()[0]);
    const correctKeccakCode = readYulBytecode({
      codeName: "Keccak256",
      path: "precompiles",
      lang: Language.Yul,
      address: ethers.constants.AddressZero,
    });

    await publishBytecode(oldKeccakCode);
    await publishBytecode(correctKeccakCode);

    await setCode(REAL_KECCAK256_CONTRACT_ADDRESS, correctKeccakCode);
  });

  after(async () => {
    await setCode(REAL_KECCAK256_CONTRACT_ADDRESS, oldKeccakCode);
  });

  it("zero pointer test", async () => {
    await keccakTest.zeroPointerTest();
  });

  it("keccak validation test", async () => {
    const seed = ethers.utils.randomBytes(32);
    // Displaying seed for reproducible tests
    console.log("Keccak256 fussing seed", ethers.utils.hexlify(seed));

    const BLOCK_SIZE = 136;

    const inputsToTest = [
      "0x",
      randomHexFromSeed(seed, BLOCK_SIZE),
      randomHexFromSeed(seed, BLOCK_SIZE - 1),
      randomHexFromSeed(seed, BLOCK_SIZE - 2),
      randomHexFromSeed(seed, BLOCK_SIZE + 1),
      randomHexFromSeed(seed, BLOCK_SIZE + 2),
      randomHexFromSeed(seed, 101 * BLOCK_SIZE),
      randomHexFromSeed(seed, 101 * BLOCK_SIZE - 1),
      randomHexFromSeed(seed, 101 * BLOCK_SIZE - 2),
      randomHexFromSeed(seed, 101 * BLOCK_SIZE + 1),
      randomHexFromSeed(seed, 101 * BLOCK_SIZE + 2),
      // In order to get random length, we use modulo operation
      randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(113).toNumber()),
      randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(1101).toNumber()),
      randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(17).toNumber()),
    ];

    for (const input of inputsToTest) {
      const expectedOutput = ethers.utils.keccak256(input);
      const result = await getWallets()[0].call({
        to: REAL_KECCAK256_CONTRACT_ADDRESS,
        data: input,
      });

      expect(expectedOutput).to.eq(result);
    }
  });
});

function randomHexFromSeed(seed: BytesLike, len: number) {
  const hexLen = len * 2 + 2;
  let data = "0x";
  while (data.length < hexLen) {
    const next = ethers.utils.keccak256(ethers.utils.hexConcat([seed, data]));
    data = ethers.utils.hexConcat([data, next]);
  }
  return data.substring(0, hexLen);
}
