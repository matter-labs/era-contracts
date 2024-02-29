import { hashBytecode } from "zksync-web3/build/src/utils";
import type { KeccakTest } from "../typechain";
import { KeccakTestFactory } from "../typechain";
import { REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, REAL_KECCAK256_CONTRACT_ADDRESS, REAL_SEKP256_R1_CONTRACT_ADDRESS } from "./shared/constants";
import { getWallets, loadArtifact, publishBytecode, setCode, getCode } from "./shared/utils";
import { ethers, network } from "hardhat";
import { readYulBytecode } from "../scripts/utils";
import { Language } from "../scripts/constants";
import type { BytesLike } from "ethers";
import { expect } from "chai";
import * as hre from "hardhat";
import { prepareEnvironment } from "./shared/mocks";

import { ec as EC } from 'elliptic';

describe.only("Keccak256 tests", function () {
  let keccakTest: KeccakTest;

  let correctSekp256R1CodeHash: string;

  let oldSekp256Code: string;

  before(async () => {
    await prepareEnvironment();
    
    oldSekp256Code = await getCode(REAL_SEKP256_R1_CONTRACT_ADDRESS);

    const testedSekp256R1Code = readYulBytecode({
      codeName: "Sekp256r1",
      path: "precompiles",
      lang: Language.Yul,
      address: ethers.constants.AddressZero,
    });


    console.log('tested', testedSekp256R1Code.length);

    await setCode(REAL_SEKP256_R1_CONTRACT_ADDRESS, testedSekp256R1Code);
  });

  it('Should correctly verify valid signature', async () => {
    const ec = new EC('p256');

    // The digest and secret key were copied from the following test suit: https://github.com/hyperledger/besu/blob/b6a6402be90339367d5bcabcd1cfd60df4832465/crypto/algorithms/src/test/java/org/hyperledger/besu/crypto/SECP256R1Test.java#L36
    const keyPair = ec.keyFromPrivate('519b423d715f8b581f4fa8ee59f4771a5b44c8130b4e3eacca54a56dda72b464');
    const message = '0x5905238877c77421f73e43ee3da6f2d9e2ccad5fc942dcec0cbd25482935faaf416983fe165b1a045ee2bcd2e6dca3bdf46c4310a7461f9a37960ca672d3feb5473e253605fb1ddfd28065b53cb5858a8ad28175bf9bd386a5e471ea7a65c17cc934a9d791e91491eb3754d03799790fe2d308d16146d5c9b0d0debd97d79ce8';//ethers.utils.randomBytes(128);

    const digest = ethers.utils.keccak256(message);
    const signature = keyPair.sign(digest.slice(2));

    // Export the signature to hexadecimal format
    const r = signature.r.toString(16);
    const s = signature.s.toString(16);
    
    const pk = keyPair.getPublic();

    const x = pk.getX().toString(16);
    const y = pk.getY().toString(16);

    // Contatenate the digest, r, s, x and y
    const calldata = digest + r + s + x + y;

    const result = await getWallets()[0].call({
        to: REAL_SEKP256_R1_CONTRACT_ADDRESS,
        data: calldata
    });

    expect(ethers.BigNumber.from(result).eq(1)).to.be.true;
  });

  it('Should reject invalid input', async () => {
    
    const result = await getWallets()[0].call({
        to: REAL_SEKP256_R1_CONTRACT_ADDRESS,
        data: '0xdeadbeef'
    });

    expect(ethers.BigNumber.from(result).eq(0)).to.be.true;

  });

  after(async () => {
    console.log(oldSekp256Code.length);
    await setCode(REAL_SEKP256_R1_CONTRACT_ADDRESS, oldSekp256Code);
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
