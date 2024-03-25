import { REAL_P256VERIFY_CONTRACT_ADDRESS } from "./shared/constants";
import { getWallets, setCode, getCode } from "./shared/utils";
import { ethers } from "hardhat";
import { readYulBytecode } from "../scripts/utils";
import { Language } from "../scripts/constants";
import { expect } from "chai";
import { prepareEnvironment } from "./shared/mocks";

import { ec as EC } from "elliptic";
import { BigNumber } from "ethers";

describe("P256Verify tests", function () {
  const ONE = "0x0000000000000000000000000000000000000000000000000000000000000001";
  const P256_GROUP_ORDER = "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";

  let oldP256VerifyCode: string;

  let correctDigest: string;
  let correctX: string;
  let correctY: string;
  let correctS: string;
  let correctR: string;

  function compileSignature(options: { digest?: string; x?: string; y?: string; r?: string; s?: string }) {
    const { digest: providedDigest, x: providedX, y: providedY, r: providedR, s: providedS } = options;

    const digest = providedDigest || correctDigest;
    const x = providedX || correctX;
    const y = providedY || correctY;
    const r = providedR || correctR;
    const s = providedS || correctS;

    // Concatenate the digest, r, s, x and y.
    // Note that for r,s,x,y we need to remove the 0x prefix
    return digest + r.slice(2) + s.slice(2) + x.slice(2) + y.slice(2);
  }

  before(async () => {
    await prepareEnvironment();

    oldP256VerifyCode = await getCode(REAL_P256VERIFY_CONTRACT_ADDRESS);

    const testedP256VerifyCode = readYulBytecode({
      codeName: "P256Verify",
      path: "precompiles",
      lang: Language.Yul,
      address: ethers.constants.AddressZero,
    });

    await setCode(REAL_P256VERIFY_CONTRACT_ADDRESS, testedP256VerifyCode);

    const ec = new EC("p256");

    // The digest and secret key were copied from the following test suit: https://github.com/hyperledger/besu/blob/b6a6402be90339367d5bcabcd1cfd60df4832465/crypto/algorithms/src/test/java/org/hyperledger/besu/crypto/SECP256R1Test.java#L36
    const keyPair = ec.keyFromPrivate("519b423d715f8b581f4fa8ee59f4771a5b44c8130b4e3eacca54a56dda72b464");
    const message =
      "0x5905238877c77421f73e43ee3da6f2d9e2ccad5fc942dcec0cbd25482935faaf416983fe165b1a045ee2bcd2e6dca3bdf46c4310a7461f9a37960ca672d3feb5473e253605fb1ddfd28065b53cb5858a8ad28175bf9bd386a5e471ea7a65c17cc934a9d791e91491eb3754d03799790fe2d308d16146d5c9b0d0debd97d79ce8"; //ethers.utils.randomBytes(128);

    correctDigest = ethers.utils.keccak256(message);
    const signature = keyPair.sign(correctDigest.slice(2));

    // Export the signature to hexadecimal format
    correctR = "0x" + signature.r.toString(16);
    correctS = "0x" + signature.s.toString(16);

    const pk = keyPair.getPublic();

    correctX = "0x" + pk.getX().toString(16);
    correctY = "0x" + pk.getY().toString(16);
  });

  it("Should correctly verify valid signature", async () => {
    const result = await getWallets()[0].call({
      to: REAL_P256VERIFY_CONTRACT_ADDRESS,
      data: compileSignature({}),
    });

    expect(result).to.eq(ONE);
  });

  it("Should reject invalid input", async () => {
    const result = await getWallets()[0].call({
      to: REAL_P256VERIFY_CONTRACT_ADDRESS,
      data: "0xdeadbeef",
    });

    expect(result).to.eq("0x");
  });

  it("Should reject zeroed params", async () => {
    // Note that digest : 0 is a valid input
    for (const param of ["x", "y", "r", "s"]) {
      const result = await getWallets()[0].call({
        to: REAL_P256VERIFY_CONTRACT_ADDRESS,
        data: compileSignature({ [param]: ethers.constants.HashZero }),
      });

      expect(result).to.eq("0x");
    }
  });

  it("Should reject large s/r", async () => {
    const groupSize = "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";
    for (const param of ["r", "s"]) {
      const result = await getWallets()[0].call({
        to: REAL_P256VERIFY_CONTRACT_ADDRESS,
        data: compileSignature({ [param]: groupSize }),
      });

      expect(result).to.eq("0x");
    }
  });

  it("Should reject bad x/y", async () => {
    for (const param of ["x", "y"]) {
      const result = await getWallets()[0].call({
        to: REAL_P256VERIFY_CONTRACT_ADDRESS,
        // This will ensure that (x,y) is not a valid point on the curve
        data: compileSignature({ [param]: ONE }),
      });

      expect(result).to.eq("0x");
    }
  });

  it("Should reject when params are valid, but signature is not correct", async () => {
    for (const param of ["digest", "r", "s"]) {
      const result = await getWallets()[0].call({
        to: REAL_P256VERIFY_CONTRACT_ADDRESS,
        // "1" is a valid number, but it will lead to invalid signature
        data: compileSignature({ [param]: ONE }),
      });

      expect(result).to.eq("0x");
    }
  });

  it("Should reject when calldata is too long", async () => {
    const result = await getWallets()[0].call({
      to: REAL_P256VERIFY_CONTRACT_ADDRESS,
      // The signature is valid and yet the input is too long
      data: compileSignature({}) + "00",
    });

    expect(result).to.eq("0x");
  });

  it("Malleability is permitted", async () => {
    const newS = BigNumber.from(P256_GROUP_ORDER).sub(correctS);
    const result = await getWallets()[0].call({
      to: REAL_P256VERIFY_CONTRACT_ADDRESS,
      // The signature is valid and yet the input is too long
      data: compileSignature({ s: ethers.utils.hexZeroPad(newS.toHexString(), 32) }),
    });

    expect(result).to.eq(ONE);
  });

  after(async () => {
    await setCode(REAL_P256VERIFY_CONTRACT_ADDRESS, oldP256VerifyCode);
  });
});
