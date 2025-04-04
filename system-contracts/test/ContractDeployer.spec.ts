import type { ZkSyncArtifact } from "@matterlabs/hardhat-zksync-deploy/dist/types";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-ethers";
import { utils } from "zksync-ethers";
import type { ContractDeployer } from "../typechain";
import { ContractDeployerFactory, DeployableFactory } from "../typechain";
import {
  ONE_BYTES32_HEX,
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TEST_FORCE_DEPLOYER_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment, setResult } from "./shared/mocks";
import {
  deployContract,
  deployContractOnAddress,
  getWallets,
  loadArtifact,
  publishBytecode,
  setConstructingCodeHash,
} from "./shared/utils";

describe("ContractDeployer tests", function () {
  let wallet: Wallet;
  let deployerAccount: ethers.Signer;
  let forceDeployer: ethers.Signer;

  let contractDeployer: ContractDeployer;
  let contractDeployerSystemCall: ContractDeployer;

  let deployableArtifact: ZkSyncArtifact;

  const RANDOM_ADDRESS = ethers.utils.getAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
  const RANDOM_ADDRESS_2 = ethers.utils.getAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbee2");
  const RANDOM_ADDRESS_3 = ethers.utils.getAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbee3");
  const EMPTY_KERNEL_ADDRESS = ethers.utils.getAddress("0x0000000000000000000000000000000000000101");
  const AA_VERSION_NONE = 0;
  const AA_VERSION_1 = 1;
  const NONCE_ORDERING_SEQUENTIAL = 0;
  const NONCE_ORDERING_ARBITRARY = 1;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];

    await deployContractOnAddress(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, "ContractDeployer", false);
    contractDeployer = ContractDeployerFactory.connect(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, wallet);

    const contractDeployerSystemCallContract = await deployContract("SystemCaller", [contractDeployer.address]);
    contractDeployerSystemCall = ContractDeployerFactory.connect(contractDeployerSystemCallContract.address, wallet);

    deployableArtifact = await loadArtifact("Deployable");

    deployerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
    forceDeployer = await ethers.getImpersonatedSigner(TEST_FORCE_DEPLOYER_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_FORCE_DEPLOYER_ADDRESS],
    });
  });

  describe("setAllowedBytecodeTypesToDeploy", function () {
    it("can't change if not forceDeployer", async () => {
      const newContractDeployer = await deployContract("ContractDeployer", []);

      expect(newContractDeployer.setAllowedBytecodeTypesToDeploy(1)).to.be.revertedWithCustomError(
        newContractDeployer,
        "Unauthorized"
      );
    });

    it("successfully updated allowedBytecodeTypesToDeploy", async () => {
      const newContractDeployer = await deployContract("ContractDeployer", []);

      expect(await newContractDeployer.allowedBytecodeTypesToDeploy()).to.be.eq(0);
      await newContractDeployer.connect(forceDeployer).setAllowedBytecodeTypesToDeploy(1);
      expect(await newContractDeployer.allowedBytecodeTypesToDeploy()).to.be.eq(1);
    });
  });

  describe("updateAccountVersion", function () {
    it("non system call failed", async () => {
      await expect(contractDeployer.updateAccountVersion(AA_VERSION_NONE)).to.be.revertedWithCustomError(
        contractDeployer,
        "SystemCallFlagRequired"
      );
    });

    it("from none to version1", async () => {
      expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion).to.be.eq(
        AA_VERSION_NONE
      );
      await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_1);
      expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion).to.be.eq(
        AA_VERSION_1
      );
    });

    it("from version1 to none", async () => {
      expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion).to.be.eq(
        AA_VERSION_1
      );
      await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_NONE);
      expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion).to.be.eq(
        AA_VERSION_NONE
      );
    });
  });

  describe("updateNonceOrdering", function () {
    it("non system call failed", async () => {
      await expect(contractDeployer.updateNonceOrdering(NONCE_ORDERING_SEQUENTIAL)).to.be.revertedWithCustomError(
        contractDeployer,
        "SystemCallFlagRequired"
      );
    });

    it("reverts in any case", async () => {
      expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).nonceOrdering).to.be.eq(
        NONCE_ORDERING_SEQUENTIAL
      );
      await expect(
        contractDeployerSystemCall.updateNonceOrdering(NONCE_ORDERING_ARBITRARY)
      ).to.be.revertedWithCustomError(contractDeployer, "InvalidNonceOrderingChange");
    });
  });

  describe("getAccountInfo", function () {
    it("success", async () => {
      const accountInfo = await contractDeployer.getAccountInfo(RANDOM_ADDRESS);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });

  describe("extendedAccountVersion", function () {
    it("account abstraction contract", async () => {
      await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_1);
      expect(await contractDeployer.extendedAccountVersion(contractDeployerSystemCall.address)).to.be.eq(AA_VERSION_1);
      await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_NONE);
    });

    it("EOA", async () => {
      await setResult("AccountCodeStorage", "getRawCodeHash", [RANDOM_ADDRESS], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      expect(await contractDeployer.extendedAccountVersion(RANDOM_ADDRESS)).to.be.eq(AA_VERSION_1);
    });

    it("Empty address", async () => {
      await setResult("AccountCodeStorage", "getRawCodeHash", [EMPTY_KERNEL_ADDRESS], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      // Now testing that the system contracts with empty bytecode are still treated as AA_VERSION_NONE
      expect(await contractDeployer.extendedAccountVersion(EMPTY_KERNEL_ADDRESS)).to.be.eq(AA_VERSION_NONE);
    });

    it("not AA", async () => {
      await setResult("AccountCodeStorage", "getRawCodeHash", [RANDOM_ADDRESS], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });
      expect(await contractDeployer.extendedAccountVersion(RANDOM_ADDRESS)).to.be.eq(AA_VERSION_NONE);
    });
  });

  describe("getNewAddressCreate2", function () {
    it("success", async () => {
      expect(
        await contractDeployer.getNewAddressCreate2(
          RANDOM_ADDRESS,
          "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
          "0x0000000022000000000123812381283812831823812838912389128938912893",
          "0x"
        )
      ).to.be.eq(
        utils.create2Address(
          RANDOM_ADDRESS,
          "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
          "0x0000000022000000000123812381283812831823812838912389128938912893",
          "0x"
        )
      );
    });
  });

  describe("getNewAddressCreate", function () {
    it("success", async () => {
      expect(await contractDeployer.getNewAddressCreate(RANDOM_ADDRESS, 3223233)).to.be.eq(
        utils.createAddress(RANDOM_ADDRESS, 3223233)
      );
    });
  });

  // TODO: some other things can be tested:
  // - check other contracts (like known codes storage)
  // - cases with the kernel space address (not possible in production)
  // - twice on the same address for create (not possible in production)
  // - constructor behavior (failed, invalid immutables array)
  // - more cases for force deployments
  describe("createAccount", function () {
    let expectedAddress: string;

    before(async () => {
      await setResult("NonceHolder", "incrementDeploymentNonce", [contractDeployerSystemCall.address], {
        failure: false,
        returnData: "0x00000000000000000000000000000000000000000000000000000000deadbeef",
      });

      expectedAddress = utils.createAddress(contractDeployerSystemCall.address, "0xdeadbeef");
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });

      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(expectedAddress, deployableArtifact.bytecode);
    });

    it("non system call failed", async () => {
      await expect(
        contractDeployer.createAccount(
          ethers.constants.HashZero,
          utils.hashBytecode(deployableArtifact.bytecode),
          "0x",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployer, "SystemCallFlagRequired");
    });

    it("zero bytecode hash failed", async () => {
      await expect(
        contractDeployerSystemCall.createAccount(
          ethers.constants.HashZero,
          ethers.constants.HashZero,
          "0x",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployer, "EmptyBytes32");
    });

    it("not known bytecode hash failed", async () => {
      await setResult(
        "KnownCodesStorage",
        "getMarker",
        ["0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"],
        { failure: false, returnData: ethers.constants.HashZero }
      );
      await expect(
        contractDeployerSystemCall.createAccount(
          ethers.constants.HashZero,
          "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
          "0x",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployer, "UnknownCodeHash");
    });

    // TODO: other mock events can be checked as well
    it("successfully deployed", async () => {
      await expect(
        contractDeployerSystemCall.createAccount(
          ethers.constants.HashZero,
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xdeadbeef",
          AA_VERSION_NONE
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(0, "0xdeadbeef");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });

    it("non-zero value deployed", async () => {
      await expect(
        contractDeployerSystemCall.createAccount(
          ethers.constants.HashZero,
          utils.hashBytecode(deployableArtifact.bytecode),
          "0x",
          AA_VERSION_NONE,
          { value: 11111111 }
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(11111111, "0x");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });

  describe("create2Account", function () {
    let expectedAddress: string;

    before(async () => {
      await setResult("NonceHolder", "incrementDeploymentNonce", [contractDeployerSystemCall.address], {
        failure: false,
        returnData: "0x00000000000000000000000000000000000000000000000000000000deadbee1",
      });

      expectedAddress = utils.create2Address(
        contractDeployerSystemCall.address,
        utils.hashBytecode(deployableArtifact.bytecode),
        "0x1234567891234567891234512222122167891123456789123456787654323456",
        "0xdeadbeef"
      );
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(expectedAddress, deployableArtifact.bytecode);
    });

    it("non system call failed", async () => {
      await expect(
        contractDeployer.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xdeadbeef",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployer, "SystemCallFlagRequired");
    });

    it("zero bytecode hash failed", async () => {
      await expect(
        contractDeployerSystemCall.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          ethers.constants.HashZero,
          "0x",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployerSystemCall, "EmptyBytes32");
    });

    it("not known bytecode hash failed", async () => {
      const expectedAddress = utils.create2Address(
        contractDeployerSystemCall.address,
        "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
        "0x1234567891234567891234512222122167891123456789123456787654323456",
        "0x"
      );
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult(
        "KnownCodesStorage",
        "getMarker",
        ["0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"],
        { failure: false, returnData: ethers.constants.HashZero }
      );
      await expect(
        contractDeployerSystemCall.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
          "0x",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployerSystemCall, "UnknownCodeHash");
    });

    it("successfully deployed", async () => {
      await expect(
        contractDeployerSystemCall.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xdeadbeef",
          AA_VERSION_NONE
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(0, "0xdeadbeef");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });

    it("already deployed failed", async () => {
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: utils.hashBytecode(deployableArtifact.bytecode),
      });
      await expect(
        contractDeployerSystemCall.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xdeadbeef",
          AA_VERSION_NONE
        )
      ).to.be.revertedWithCustomError(contractDeployerSystemCall, "HashIsNonZero");
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
    });

    it("non-zero value deployed", async () => {
      await expect(
        contractDeployerSystemCall.create2Account(
          "0x1234567891234567891234512222122167891123456789123456787654323456",
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xdeadbeef",
          AA_VERSION_NONE,
          { value: 5555 }
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(5555, "0xdeadbeef");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });

  describe("create", function () {
    let expectedAddress;

    before(async () => {
      await setResult("NonceHolder", "incrementDeploymentNonce", [contractDeployerSystemCall.address], {
        failure: false,
        returnData: "0x00000000000000000000000000000000000000000000000000000000deadbee2",
      });

      expectedAddress = utils.createAddress(contractDeployerSystemCall.address, "0xdeadbee2");
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(expectedAddress, deployableArtifact.bytecode);
    });

    it("non system call failed", async () => {
      await expect(
        contractDeployer.create(ethers.constants.HashZero, utils.hashBytecode(deployableArtifact.bytecode), "0x")
      ).to.be.revertedWithCustomError(contractDeployer, "SystemCallFlagRequired");
    });

    it("successfully deployed", async () => {
      await expect(
        contractDeployerSystemCall.create(
          ethers.constants.HashZero,
          utils.hashBytecode(deployableArtifact.bytecode),
          "0x12"
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(0, "0x12");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });
  //
  describe("create2", function () {
    let expectedAddress: string;

    before(async () => {
      await setResult("NonceHolder", "incrementDeploymentNonce", [contractDeployerSystemCall.address], {
        failure: false,
        returnData: "0x00000000000000000000000000000000000000000000000000000000deadbee3",
      });

      expectedAddress = utils.create2Address(
        contractDeployerSystemCall.address,
        utils.hashBytecode(deployableArtifact.bytecode),
        ethers.constants.HashZero,
        "0xabcd"
      );
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(expectedAddress, deployableArtifact.bytecode);
    });

    it("non system call failed", async () => {
      await expect(
        contractDeployer.create2(ethers.constants.HashZero, utils.hashBytecode(deployableArtifact.bytecode), "0xabcd")
      ).to.be.revertedWithCustomError(contractDeployer, "SystemCallFlagRequired");
    });

    it("successfully deployed", async () => {
      await expect(
        contractDeployerSystemCall.create2(
          ethers.constants.HashZero,
          utils.hashBytecode(deployableArtifact.bytecode),
          "0xabcd"
        )
      )
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(contractDeployerSystemCall.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
        .to.emit(DeployableFactory.connect(expectedAddress, wallet), "Deployed")
        .withArgs(0, "0xabcd");
      const accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });

  describe.only("createEVM", function () {
    let expectedAddress;

    before(async () => {
      await setResult("NonceHolder", "incrementDeploymentNonce", [contractDeployerSystemCall.address], {
        failure: false,
        returnData: "0x00000000000000000000000000000000000000000000000000000000deadbee2",
      });

      expectedAddress = utils.createAddress(contractDeployerSystemCall.address, "0xdeadbee2");
      await setResult("AccountCodeStorage", "getCodeHash", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("NonceHolder", "getRawNonce", [expectedAddress], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(expectedAddress, deployableArtifact.bytecode);
    });

    it("non system call failed", async () => {
      let deployableArtifactInitCode = "0x6105a0600e6000396105a06000f300000001002001900000007b0000613d000000600210027000000022022001970000001f0320003900000023043001980000003f0340003900000024033001970000008003300039000000400030043f000000800020043f000000130000613d000000000321034f000000a004400039000000a005000039000000003603043c0000000005650436000000000045004b0000000f0000c13d0000001f0320018f0000002504200198000000a0024000390000001d0000613d000000a005000039000000000601034f000000006706043c0000000005750436000000000025004b000000190000c13d000000000003004b0000002a0000613d000000000141034f0000000303300210000000000402043300000000043401cf000000000434022f000000000101043b0000010003300089000000000131022f00000000013101cf000000000141019f0000000000120435000000400100043d000000200210003900000040030000390000000000320435000000000200041600000000002104350000004003100039000000800200043d00000000002304350000002b062001970000001f0520018f0000006004100039000000a10040008c000000480000413d000000000006004b000000430000613d000000000854001900000080075001bf000000200880008a0000000009680019000000000a670019000000000a0a04330000000000a90435000000200660008c0000003d0000c13d000000000005004b0000005e0000613d000000a0060000390000000007040019000000540000013d0000000007640019000000000006004b000000510000613d000000a0080000390000000009040019000000008a0804340000000009a90436000000000079004b0000004d0000c13d000000000005004b0000005e0000613d000000a0066000390000000305500210000000000807043300000000085801cf000000000858022f00000000060604330000010005500089000000000656022f00000000055601cf000000000585019f00000000005704350000001f052000390000002b035001970000000002420019000000000002043500000060023000390000006003200210000000260020009c0000002703008041000000220010009c00000022010080410000004001100210000000000113019f0000000002000414000000220020009c0000002202008041000000c0022002100000000001210019000000280110009a0000800d02000039000000010300003900000029040000410082007d0000040f00000001002001900000007b0000613d0000002001000039000001000010044300000120000004430000002a01000041000000830001042e0000000001000019000000840001043000000080002104210000000102000039000000000001042d0000000002000019000000000001042d0000008200000432000000830001042e000000840001043000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000001ffffffe000000000000000000000000000000000000000000000000000000003ffffffe000000000000000000000000000000000000000000000000000000000ffffffe0000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000ffffffff000000000000000000000000fe0000000000000000000000000000000000000000000000000000000000000081877aef325fcaf4d37b3982af46756e639f7c8d87ba441191deee76618494cb0000000200000000000000000000000000000040000001000000000000000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe082543d880c2b5c550d3f0322c105b599bb685c943127c5bfb171cb399c4e71d6";
      await expect(
        contractDeployer.createEVM(deployableArtifactInitCode)
      ).to.be.revertedWithCustomError(contractDeployer, "SystemCallFlagRequired");
    });

    it("successfully deployed", async () => {
      let deployableArtifactInitCode = "0x6105a0600e6000396105a06000f300000001002001900000007b0000613d000000600210027000000022022001970000001f0320003900000023043001980000003f0340003900000024033001970000008003300039000000400030043f000000800020043f000000130000613d000000000321034f000000a004400039000000a005000039000000003603043c0000000005650436000000000045004b0000000f0000c13d0000001f0320018f0000002504200198000000a0024000390000001d0000613d000000a005000039000000000601034f000000006706043c0000000005750436000000000025004b000000190000c13d000000000003004b0000002a0000613d000000000141034f0000000303300210000000000402043300000000043401cf000000000434022f000000000101043b0000010003300089000000000131022f00000000013101cf000000000141019f0000000000120435000000400100043d000000200210003900000040030000390000000000320435000000000200041600000000002104350000004003100039000000800200043d00000000002304350000002b062001970000001f0520018f0000006004100039000000a10040008c000000480000413d000000000006004b000000430000613d000000000854001900000080075001bf000000200880008a0000000009680019000000000a670019000000000a0a04330000000000a90435000000200660008c0000003d0000c13d000000000005004b0000005e0000613d000000a0060000390000000007040019000000540000013d0000000007640019000000000006004b000000510000613d000000a0080000390000000009040019000000008a0804340000000009a90436000000000079004b0000004d0000c13d000000000005004b0000005e0000613d000000a0066000390000000305500210000000000807043300000000085801cf000000000858022f00000000060604330000010005500089000000000656022f00000000055601cf000000000585019f00000000005704350000001f052000390000002b035001970000000002420019000000000002043500000060023000390000006003200210000000260020009c0000002703008041000000220010009c00000022010080410000004001100210000000000113019f0000000002000414000000220020009c0000002202008041000000c0022002100000000001210019000000280110009a0000800d02000039000000010300003900000029040000410082007d0000040f00000001002001900000007b0000613d0000002001000039000001000010044300000120000004430000002a01000041000000830001042e0000000001000019000000840001043000000080002104210000000102000039000000000001042d0000000002000019000000000001042d0000008200000432000000830001042e000000840001043000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000001ffffffe000000000000000000000000000000000000000000000000000000003ffffffe000000000000000000000000000000000000000000000000000000000ffffffe0000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000ffffffff000000000000000000000000fe0000000000000000000000000000000000000000000000000000000000000081877aef325fcaf4d37b3982af46756e639f7c8d87ba441191deee76618494cb0000000200000000000000000000000000000040000001000000000000000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe082543d880c2b5c550d3f0322c105b599bb685c943127c5bfb171cb399c4e71d6";
      await expect(
        contractDeployerSystemCall.createEVM(
          deployableArtifactInitCode, { gasLimit: 20000000 }
        )
      ).to.emit(contractDeployer, "ContractDeployed")
    });

  });

  describe("forceDeployOnAddress", function () {
    it("not from self call failed", async () => {
      const deploymentData = {
        bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
        newAddress: RANDOM_ADDRESS,
        callConstructor: false,
        value: 0,
        input: "0x",
      };
      await expect(contractDeployer.forceDeployOnAddress(deploymentData, wallet.address)).to.be.revertedWithCustomError(
        contractDeployer,
        "Unauthorized"
      );
    });

    it("not known bytecode hash failed", async () => {
      await setResult(
        "KnownCodesStorage",
        "getMarker",
        ["0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"],
        { failure: false, returnData: ethers.constants.HashZero }
      );
      const deploymentData = {
        bytecodeHash: "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
        newAddress: RANDOM_ADDRESS,
        callConstructor: false,
        value: 0,
        input: "0x",
      };
      await expect(
        contractDeployer.connect(deployerAccount).forceDeployOnAddress(deploymentData, wallet.address)
      ).to.be.revertedWithCustomError(contractDeployerSystemCall, "UnknownCodeHash");
    });

    it("successfully deployed", async () => {
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });
      const deploymentData = {
        bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
        newAddress: RANDOM_ADDRESS,
        callConstructor: false,
        value: 0,
        input: "0x",
      };
      await expect(contractDeployer.connect(deployerAccount).forceDeployOnAddress(deploymentData, wallet.address))
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS)
        .to.not.emit(DeployableFactory.connect(RANDOM_ADDRESS, wallet), "Deployed");
      const accountInfo = await contractDeployer.getAccountInfo(RANDOM_ADDRESS);
      expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });

  describe("forceDeployOnAddresses", function () {
    it("not allowed to call", async () => {
      const deploymentData = [
        {
          bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
          newAddress: RANDOM_ADDRESS_2,
          callConstructor: true,
          value: 0,
          input: "0x",
        },
        {
          bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
          newAddress: RANDOM_ADDRESS_3,
          callConstructor: false,
          value: 0,
          input: "0xab",
        },
      ];
      await expect(contractDeployer.forceDeployOnAddresses(deploymentData)).to.be.revertedWithCustomError(
        contractDeployer,
        "Unauthorized"
      );
    });

    it("successfully deployed", async () => {
      await setResult("KnownCodesStorage", "getMarker", [utils.hashBytecode(deployableArtifact.bytecode)], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });

      // We still need to set in the real account code storage to make VM decommitment work.
      await publishBytecode(deployableArtifact.bytecode);
      await setConstructingCodeHash(RANDOM_ADDRESS_2, deployableArtifact.bytecode);
      await setConstructingCodeHash(RANDOM_ADDRESS_3, deployableArtifact.bytecode);

      const deploymentData = [
        {
          bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
          newAddress: RANDOM_ADDRESS_2,
          callConstructor: true,
          value: 0,
          input: "0x",
        },
        {
          bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
          newAddress: RANDOM_ADDRESS_3,
          callConstructor: false,
          value: 0,
          input: "0xab",
        },
      ];
      await expect(contractDeployer.connect(forceDeployer).forceDeployOnAddresses(deploymentData))
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(forceDeployer.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS_2)
        .to.emit(contractDeployer, "ContractDeployed")
        .withArgs(forceDeployer.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS_3)
        .to.emit(DeployableFactory.connect(RANDOM_ADDRESS_2, wallet), "Deployed")
        .withArgs(0, "0x")
        .to.not.emit(DeployableFactory.connect(RANDOM_ADDRESS_3, wallet), "Deployed");

      const accountInfo1 = await contractDeployer.getAccountInfo(RANDOM_ADDRESS_2);
      expect(accountInfo1.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo1.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);

      const accountInfo2 = await contractDeployer.getAccountInfo(RANDOM_ADDRESS_3);
      expect(accountInfo2.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
      expect(accountInfo2.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
    });
  });
});
