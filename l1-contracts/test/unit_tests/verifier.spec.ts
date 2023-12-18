import * as hardhat from "hardhat";
import { expect } from "chai";
import type { VerifierTest, VerifierRecursiveTest } from "../../typechain";
import { VerifierTestFactory } from "../../typechain";
import { getCallRevertReason } from "./utils";
import { ethers } from "hardhat";

describe("Verifier test", function () {
  const Q_MOD = "21888242871839275222246405745257275088696311157297823662689037894645226208583";
  const R_MOD = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

  const PROOF = {
    publicInputs: ["0xa3dd954bb76c1474c1a04f04870cc75bcaf66ec23c0303c87fb119f9"],
    serializedProof: [
      "0x162e0e35310fa1265df0051490fad590e875a98b4e7781ce1bb2698887e24070",
      "0x1a3645718b688a382a00b99059f9488daf624d04ceb39b5553f0a1a0d508dde6",
      "0x44df31be22763cde0700cc784f70758b944096a11c9b32bfb4f559d9b6a9567",
      "0x2efae700419dd3fa0bebf5404efef2f3b5f8f2288c595ec219a05607e9971c9",
      "0x223e7327348fd30effc617ee9fa7e28117869f149719cf93c20788cb78adc291",
      "0x99f67d073880787c73d54bc2509c1611ac6f48fbe3b5214b4dc2f3cb3a572c0",
      "0x17365bde1bbcd62561764ddd8b2d562edbe1c07519cd23f03831b694c6665a2d",
      "0x2f321ac8e18ab998f8fe370f3b5114598881798ccc6eac24d7f4161c15fdabb3",
      "0x2f6b4b0f4973f2f6e2fa5ecd34602b20b56f0e4fb551b011af96e555fdc1197d",
      "0xb8d070fec07e8467425605015acba755f54db7f566c6704818408d927419d80",
      "0x103185cff27eef6e8090373749a8065129fcc93482bd6ea4db1808725b6da2e",
      "0x29b35d35c22deda2ac9dd56a9f6a145871b1b6557e165296f804297160d5f98b",
      "0x240bb4b0b7e30e71e8af2d908e72bf47b6496aab1e1f7cb32f2604d79f76cff8",
      "0x1cd2156a0f0c1944a8a3359618ff978b27eb42075c667960817be624ce161489",
      "0xbd0b75112591ab1b4a6a3e03fb76368419b78e4b95ee773b8ef5e7848695cf7",
      "0xcd1da7fcfc27d2d9e9743e80951694995b162298d4109428fcf1c9a90f24905",
      "0x2672327da3fdec6c58e8a0d33ca94e059da0787e9221a2a0ac412692cc962aac",
      "0x50e88db23f7582691a0fb7e5c95dd713e54188833fe1d241e3e32a98dfeb0f0",
      "0x8dc78ede51774238b0984b02ac7fcf8b0a8dfcb6ca733b90c6b44aac4551057",
      "0x2a3167374e2d54e47ce865ef222346adf7a27d4174820a637cf656899238387",
      "0x2f161fddcebb9ed8740c14d3a782efcf6f0ad069371194f87bcc04f9e9baf2ee",
      "0x25dcf81d1721eab45e86ccfee579eaa4e54a4a80a19edf784f24cc1ee831e58a",
      "0x1e483708e664ced677568d93b3b4f505e9d2968f802e04b31873f7d8f635fb0f",
      "0x2bf6cdf920d353ba8bda932b72bf6ff6a93aa831274a5dc3ea6ea647a446d18e",
      "0x2aa406a77d9143221165e066adfcc9281b9c90afdcee4336eda87f85d2bfe5b",
      "0x26fc05b152609664e624a233e52e12252a0cae9d2a86a36717300063faca4b4b",
      "0x24579fb180a63e5594644f4726c5af6d091aee4ee64c2c2a37d98f646a9c8d9d",
      "0xb34ff9cbae3a9afe40e80a46e7d1419380e210a0e9595f61eb3a300aaef9f34",
      "0x2ee89372d00fd0e32a46d513f7a80a1ae64302f33bc4b100384327a443c0193c",
      "0x2b0e285154aef9e8af0777190947379df37da05cf342897bf1de1bc40e497893",
      "0x158b022dd94b2c5c44994a5be28b2f570f1187277430ed9307517fa0c830d432",
      "0x1d1ea6f83308f30e544948e221d6b313367eccfe54ec05dfa757f023b5758f3d",
      "0x1a08a4549273627eadafe47379be8e997306f5b9567618b38c93a0d58eb6c54c",
      "0xf434e5d987974afdd7f45a0f84fb800ecbbcdf2eeb302e415371e1d08ba4ad7",
      "0x168b5b6d46176887125f13423384b8e8dd4fd947aac832d8d15b87865580b5fb",
      "0x166cd223e74511332e2df4e7ad7a82c3871ed0305a5708521702c5e62e11a30b",
      "0x10f0979b9797e30f8fe15539518c7f4dfc98c7acb1490da60088b6ff908a4876",
      "0x20e08df88bbafc9a810fa8e2324c36b5513134477207763849ed4a0b6bd9639",
      "0x1e977a84137396a3cfb17565ecfb5b60dffb242c7aab4afecaa45ebd2c83e0a3",
      "0x19f3f9b6c6868a0e2a7453ff8949323715817869f8a25075308aa34a50c1ca3c",
      "0x248b030bbfab25516cca23e7937d4b3b46967292ef6dfd3df25fcfe289d53fac",
      "0x26bee4a0a5c8b76caa6b73172fa7760bd634c28d2c2384335b74f5d18e3933f4",
      "0x106719993b9dacbe46b17f4e896c0c9c116d226c50afe2256dca1e81cd510b5c",
      "0x19b5748fd961f755dd3c713d09014bd12adbb739fa1d2160067a312780a146a2",
    ],
    recursiveAggregationInput: [],
  };
  let verifier: VerifierTest;

  before(async function () {
    const verifierFactory = await hardhat.ethers.getContractFactory("VerifierTest");
    const verifierContract = await verifierFactory.deploy();
    verifier = VerifierTestFactory.connect(verifierContract.address, verifierContract.signer);
  });

  it("Should verify proof", async () => {
    // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
    const calldata = verifier.interface.encodeFunctionData("verify", [
      PROOF.publicInputs,
      PROOF.serializedProof,
      PROOF.recursiveAggregationInput,
    ]);
    await verifier.fallback({ data: calldata });

    // Check that proof is verified
    const result = await verifier.verify(PROOF.publicInputs, PROOF.serializedProof, PROOF.recursiveAggregationInput);
    expect(result, "proof verification failed").true;
  });

  describe("Should verify valid proof with fields values in non standard format", function () {
    it("Public input with dirty bits over Fr mask", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Fill dirty bits
      validProof.publicInputs[0] = ethers.BigNumber.from(validProof.publicInputs[0])
        .add("0xe000000000000000000000000000000000000000000000000000000000000000")
        .toHexString();
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });

    it("Elliptic curve points over modulo", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Add modulo to points
      validProof.serializedProof[0] = ethers.BigNumber.from(validProof.serializedProof[0]).add(Q_MOD);
      validProof.serializedProof[1] = ethers.BigNumber.from(validProof.serializedProof[1]).add(Q_MOD).add(Q_MOD);
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });

    it("Fr over modulo", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Add modulo to number
      validProof.serializedProof[22] = ethers.BigNumber.from(validProof.serializedProof[22]).add(R_MOD);
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });
  });

  describe("Should revert on invalid input", function () {
    it("More than 1 public inputs", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more public input to proof
      invalidProof.publicInputs.push(invalidProof.publicInputs[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Empty public inputs", async () => {
      const revertReason = await getCallRevertReason(
        verifier.verify([], PROOF.serializedProof, PROOF.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("More than 44 words for proof", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more "serialized proof" input
      invalidProof.serializedProof.push(invalidProof.serializedProof[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Empty serialized proof", async () => {
      const revertReason = await getCallRevertReason(
        verifier.verify(PROOF.publicInputs, [], PROOF.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Not empty recursive aggregation input", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more "recursive aggregation input" value
      invalidProof.recursiveAggregationInput.push(invalidProof.publicInputs[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Elliptic curve point at infinity", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Change first point to point at infinity (encode as (0, 0) on EVM)
      invalidProof.serializedProof[0] = ethers.constants.HashZero;
      invalidProof.serializedProof[1] = ethers.constants.HashZero;
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });
  });

  it("Should failed with invalid public input", async () => {
    const revertReason = await getCallRevertReason(
      verifier.verify([ethers.constants.HashZero], PROOF.serializedProof, PROOF.recursiveAggregationInput)
    );
    expect(revertReason).equal("invalid quotient evaluation");
  });

  it("Should return correct Verification key hash", async () => {
    const vksHash = await verifier.verificationKeyHash();
    expect(vksHash).equal("0x6625fa96781746787b58306d414b1e25bd706d37d883a9b3acf57b2bd5e0de52");
  });
});

describe("Verifier with recursive part test", function () {
  const Q_MOD = "21888242871839275222246405745257275088696311157297823662689037894645226208583";
  const R_MOD = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

  const PROOF = {
    publicInputs: ["0xa3dd954bb76c1474c1a04f04870cc75bcaf66ec23c0303c87fb119f9"],
    serializedProof: [
      "0x162e0e35310fa1265df0051490fad590e875a98b4e7781ce1bb2698887e24070",
      "0x1a3645718b688a382a00b99059f9488daf624d04ceb39b5553f0a1a0d508dde6",
      "0x44df31be22763cde0700cc784f70758b944096a11c9b32bfb4f559d9b6a9567",
      "0x2efae700419dd3fa0bebf5404efef2f3b5f8f2288c595ec219a05607e9971c9",
      "0x223e7327348fd30effc617ee9fa7e28117869f149719cf93c20788cb78adc291",
      "0x99f67d073880787c73d54bc2509c1611ac6f48fbe3b5214b4dc2f3cb3a572c0",
      "0x17365bde1bbcd62561764ddd8b2d562edbe1c07519cd23f03831b694c6665a2d",
      "0x2f321ac8e18ab998f8fe370f3b5114598881798ccc6eac24d7f4161c15fdabb3",
      "0x2f6b4b0f4973f2f6e2fa5ecd34602b20b56f0e4fb551b011af96e555fdc1197d",
      "0xb8d070fec07e8467425605015acba755f54db7f566c6704818408d927419d80",
      "0x103185cff27eef6e8090373749a8065129fcc93482bd6ea4db1808725b6da2e",
      "0x29b35d35c22deda2ac9dd56a9f6a145871b1b6557e165296f804297160d5f98b",
      "0x240bb4b0b7e30e71e8af2d908e72bf47b6496aab1e1f7cb32f2604d79f76cff8",
      "0x1cd2156a0f0c1944a8a3359618ff978b27eb42075c667960817be624ce161489",
      "0xbd0b75112591ab1b4a6a3e03fb76368419b78e4b95ee773b8ef5e7848695cf7",
      "0xcd1da7fcfc27d2d9e9743e80951694995b162298d4109428fcf1c9a90f24905",
      "0x2672327da3fdec6c58e8a0d33ca94e059da0787e9221a2a0ac412692cc962aac",
      "0x50e88db23f7582691a0fb7e5c95dd713e54188833fe1d241e3e32a98dfeb0f0",
      "0x8dc78ede51774238b0984b02ac7fcf8b0a8dfcb6ca733b90c6b44aac4551057",
      "0x2a3167374e2d54e47ce865ef222346adf7a27d4174820a637cf656899238387",
      "0x2f161fddcebb9ed8740c14d3a782efcf6f0ad069371194f87bcc04f9e9baf2ee",
      "0x25dcf81d1721eab45e86ccfee579eaa4e54a4a80a19edf784f24cc1ee831e58a",
      "0x1e483708e664ced677568d93b3b4f505e9d2968f802e04b31873f7d8f635fb0f",
      "0x2bf6cdf920d353ba8bda932b72bf6ff6a93aa831274a5dc3ea6ea647a446d18e",
      "0x2aa406a77d9143221165e066adfcc9281b9c90afdcee4336eda87f85d2bfe5b",
      "0x26fc05b152609664e624a233e52e12252a0cae9d2a86a36717300063faca4b4b",
      "0x24579fb180a63e5594644f4726c5af6d091aee4ee64c2c2a37d98f646a9c8d9d",
      "0xb34ff9cbae3a9afe40e80a46e7d1419380e210a0e9595f61eb3a300aaef9f34",
      "0x2ee89372d00fd0e32a46d513f7a80a1ae64302f33bc4b100384327a443c0193c",
      "0x2b0e285154aef9e8af0777190947379df37da05cf342897bf1de1bc40e497893",
      "0x158b022dd94b2c5c44994a5be28b2f570f1187277430ed9307517fa0c830d432",
      "0x1d1ea6f83308f30e544948e221d6b313367eccfe54ec05dfa757f023b5758f3d",
      "0x1a08a4549273627eadafe47379be8e997306f5b9567618b38c93a0d58eb6c54c",
      "0xf434e5d987974afdd7f45a0f84fb800ecbbcdf2eeb302e415371e1d08ba4ad7",
      "0x168b5b6d46176887125f13423384b8e8dd4fd947aac832d8d15b87865580b5fb",
      "0x166cd223e74511332e2df4e7ad7a82c3871ed0305a5708521702c5e62e11a30b",
      "0x10f0979b9797e30f8fe15539518c7f4dfc98c7acb1490da60088b6ff908a4876",
      "0x20e08df88bbafc9a810fa8e2324c36b5513134477207763849ed4a0b6bd9639",
      "0x1e977a84137396a3cfb17565ecfb5b60dffb242c7aab4afecaa45ebd2c83e0a3",
      "0x19f3f9b6c6868a0e2a7453ff8949323715817869f8a25075308aa34a50c1ca3c",
      "0x248b030bbfab25516cca23e7937d4b3b46967292ef6dfd3df25fcfe289d53fac",
      "0x26bee4a0a5c8b76caa6b73172fa7760bd634c28d2c2384335b74f5d18e3933f4",
      "0x106719993b9dacbe46b17f4e896c0c9c116d226c50afe2256dca1e81cd510b5c",
      "0x19b5748fd961f755dd3c713d09014bd12adbb739fa1d2160067a312780a146a2",
    ],
    recursiveAggregationInput: [
      "0x04fdf01a2faedb9e3a620bc1cd8ceb4b0adac04631bdfa9e7e9fc15e35693cc0",
      "0x1419728b438cc9afa63ab4861753e0798e29e08aac0da17b2c7617b994626ca2",
      "0x23ca418458f6bdc30dfdbc13b80c604f8864619582eb247d09c8e4703232897b",
      "0x0713c1371914ac18d7dced467a8a60eeca0f3d80a2cbd5dcc75abb6cbab39f39",
    ],
  };
  let verifier: VerifierRecursiveTest;

  before(async function () {
    const verifierFactory = await hardhat.ethers.getContractFactory("VerifierRecursiveTest");
    const verifierContract = await verifierFactory.deploy();
    verifier = VerifierTestFactory.connect(verifierContract.address, verifierContract.signer);
  });

  it("Should verify proof", async () => {
    // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
    const calldata = verifier.interface.encodeFunctionData("verify", [
      PROOF.publicInputs,
      PROOF.serializedProof,
      PROOF.recursiveAggregationInput,
    ]);
    await verifier.fallback({ data: calldata });

    // Check that proof is verified
    const result = await verifier.verify(PROOF.publicInputs, PROOF.serializedProof, PROOF.recursiveAggregationInput);
    expect(result, "proof verification failed").true;
  });

  describe("Should verify valid proof with fields values in non standard format", function () {
    it("Public input with dirty bits over Fr mask", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Fill dirty bits
      validProof.publicInputs[0] = ethers.BigNumber.from(validProof.publicInputs[0])
        .add("0xe000000000000000000000000000000000000000000000000000000000000000")
        .toHexString();
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });

    it("Elliptic curve points over modulo", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Add modulo to points
      validProof.serializedProof[0] = ethers.BigNumber.from(validProof.serializedProof[0]).add(Q_MOD);
      validProof.serializedProof[1] = ethers.BigNumber.from(validProof.serializedProof[1]).add(Q_MOD).add(Q_MOD);
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });

    it("Fr over modulo", async () => {
      const validProof = JSON.parse(JSON.stringify(PROOF));
      // Add modulo to number
      validProof.serializedProof[22] = ethers.BigNumber.from(validProof.serializedProof[22]).add(R_MOD);
      const result = await verifier.verify(
        validProof.publicInputs,
        validProof.serializedProof,
        validProof.recursiveAggregationInput
      );
      expect(result, "proof verification failed").true;
    });
  });

  describe("Should revert on invalid input", function () {
    it("More than 1 public inputs", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more public input to proof
      invalidProof.publicInputs.push(invalidProof.publicInputs[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Empty public inputs", async () => {
      const revertReason = await getCallRevertReason(
        verifier.verify([], PROOF.serializedProof, PROOF.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("More than 44 words for proof", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more "serialized proof" input
      invalidProof.serializedProof.push(invalidProof.serializedProof[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Empty serialized proof", async () => {
      const revertReason = await getCallRevertReason(
        verifier.verify(PROOF.publicInputs, [], PROOF.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("More than 4 words for recursive aggregation input", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Add one more "recursive aggregation input" value
      invalidProof.recursiveAggregationInput.push(invalidProof.recursiveAggregationInput[0]);
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Empty recursive aggregation input", async () => {
      const revertReason = await getCallRevertReason(verifier.verify(PROOF.publicInputs, PROOF.serializedProof, []));
      expect(revertReason).equal("loadProof: Proof is invalid");
    });

    it("Elliptic curve point at infinity", async () => {
      const invalidProof = JSON.parse(JSON.stringify(PROOF));
      // Change first point to point at infinity (encode as (0, 0) on EVM)
      invalidProof.serializedProof[0] = ethers.constants.HashZero;
      invalidProof.serializedProof[1] = ethers.constants.HashZero;
      const revertReason = await getCallRevertReason(
        verifier.verify(invalidProof.publicInputs, invalidProof.serializedProof, invalidProof.recursiveAggregationInput)
      );
      expect(revertReason).equal("loadProof: Proof is invalid");
    });
  });

  it("Should failed with invalid public input", async () => {
    const revertReason = await getCallRevertReason(
      verifier.verify([ethers.constants.HashZero], PROOF.serializedProof, PROOF.recursiveAggregationInput)
    );
    expect(revertReason).equal("invalid quotient evaluation");
  });

  it("Should failed with invalid recursive aggregative input", async () => {
    const revertReason = await getCallRevertReason(
      verifier.verify(PROOF.publicInputs, PROOF.serializedProof, [1, 2, 1, 2])
    );
    expect(revertReason).equal("finalPairing: pairing failure");
  });

  it("Should return correct Verification key hash", async () => {
    const vksHash = await verifier.verificationKeyHash();
    expect(vksHash).equal("0x88b3ddc4ed85974c7e14297dcad4097169440305c05fdb6441ca8dfd77cd7fa7");
  });
});
