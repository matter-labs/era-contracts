import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import type { EvmPredeploysManager } from "../typechain";
import { EvmPredeploysManagerFactory, ContractDeployerFactory, AccountCodeStorageFactory } from "../typechain";
import {
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TEST_EVM_PREDEPLOYS_MANAGER,
  SERVICE_CALL_PSEUDO_CALLER,
  TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
  TEST_EVM_HASHES_STORAGE,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS,
  REAL_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { deployContractOnAddress, getWallets } from "./shared/utils";

const PATH_TO_PREDEPLOYS_DATA = "../scripts/evm-predeploys-data";

describe("EvmPredeploysManager tests", function () {
  let evmPredeploysManager: EvmPredeploysManager;

  const setDummyEvmVersionedHash = async (contractAddress: string) => {
    const real_deployer_signer = await ethers.getImpersonatedSigner(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);

    const accountCodeStorage = AccountCodeStorageFactory.connect(
      REAL_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
      real_deployer_signer
    );

    await accountCodeStorage.storeAccountConstructingCodeHash(
      contractAddress,
      "0x0201000000000000000000000000000000000000000000000000000000000000"
    );
  };

  const readPredeploysData = (pathToData: string) => {
    const dirPath = path.join(__dirname, pathToData);
    return fs
      .readdirSync(dirPath)
      .filter((file) => path.extname(file) === ".json")
      .map((file) => {
        const filePath = path.join(dirPath, file);
        const content = fs.readFileSync(filePath, "utf8");
        return JSON.parse(content);
      });
  };

  before(async () => {
    const wallet = getWallets()[0];

    // Ugly, but this is required to execute force-deploy
    await deployContractOnAddress(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, "ContractDeployer");
    await deployContractOnAddress(TEST_EVM_PREDEPLOYS_MANAGER, "EvmPredeploysManager");
    await deployContractOnAddress(TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS, "AccountCodeStorage");
    await deployContractOnAddress(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS, "KnownCodesStorage");
    await deployContractOnAddress(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, "NonceHolder");
    await deployContractOnAddress(TEST_EVM_HASHES_STORAGE, "EvmHashesStorage");
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    await deployContractOnAddress(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, "SystemContext");

    evmPredeploysManager = EvmPredeploysManagerFactory.connect(TEST_EVM_PREDEPLOYS_MANAGER, wallet);

    const service_caller_signer = await ethers.getImpersonatedSigner(SERVICE_CALL_PSEUDO_CALLER);

    const contractDeployer = ContractDeployerFactory.connect(
      TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
      service_caller_signer
    );
    await contractDeployer.setAllowedBytecodeTypesToDeploy(1); // Allow EVM contracts to be deployed
  });

  describe("deployPredeployedContract", function () {
    it("successfully deploys all predeployed contracts", async () => {
      const predeploys = readPredeploysData(PATH_TO_PREDEPLOYS_DATA);
      for (const predeploy of predeploys) {
        // We need to do this trick to actually force VM to call EVM emulator for contract construction.
        // This is required since we use test version of account code storage and VM checks only the real one
        await setDummyEvmVersionedHash(predeploy.address);

        const tx = await evmPredeploysManager.deployPredeployedContract(predeploy.address, predeploy.input);
        await tx.wait();
      }
    });
  });
});
