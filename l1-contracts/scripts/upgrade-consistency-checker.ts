/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url } from "./utils";
import { BigNumber, ethers } from "ethers";
import { utils } from "zksync-ethers";
import type { FacetCut } from "../src.ts/diamondCut";
import { getCurrentFacetCutsForAdd } from "../src.ts/diamondCut";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const genesisUpgrade = "0x1d2Fb190B100412Bc4C6e07f926E2855E50E03Ac";
const validatorTimelockDeployTx = "0x4d0b3672452870ed5ec6ded7f04d9af5a2f825cb1c8d2bda1756c2a76615c3f8";
const validatorTimelock = "0x1A0EdA40D86213F6D0Ca233D9b33CDf66e2ef1ab";
const upgradeHyperchains = "0x706EA5608e5075f6a2eb9C8cf73C37ae9bc58A25";

const verifier = "0x88b96FCabF5b0db763ccf687748b00E9d0f14ec1";
const proxyAdmin = "0x93AEeE8d98fB0873F8fF595fDd534A1f288786D2";

const bridgeHubImpl = "0x1cEFbB67C5A98471157594454fDE61340b205feC";
const bridgeHub = "0x7BDF7970F17278a6Ff75Fdbc671E870b0728ae41";

const executorFacet = "0xFDfB1Af2570F5AF353F072E5Fd7Bb60E69F054Ee";
const adminFacet = "0xE698A6Fb588A7B4f5b4C7478FCeC51aB8f869B36";
const mailboxFacetDeployTx = "0xb037f3d401ade523d094c6c23f8c7c1e148b3edcba6ca6321358339fa12d5ac5";
const mailboxFacet = "0x3aA2A5f021E546f4fe989Fc4b428099D1FA853F5";
const gettersFacet = "0x22588e7cac6770e43FB99961Db70c608c45D9924";

const diamondInit = "0xaee9C9FfDcDcB2165ab06E07D32dc7B46379aA3e";

const stmImplDeployTx = "0x1186a70d93eb910342f79e67dda8706df576a44e74cb27832026e5dff41f67f2";
const stmImpl = "0x99D662d6eAf20bc0aAD185D58BdF945abfc8eDa2";
const stmDeployTx = "0xbad873087e897f8ad3b3a7611bd686adebaafcaa52fc778a87036b0c444ab3cb";
const stm = "0x925Dd0BC14552b0b261CA8A23ad26df9C6f2C8bA";

const sharedBridgeImplDeployTx = "0xe44f437adb1d261dc4ca2c80ad78f1d0239d7fe1b201efc202479e8f7a9f5306";
const sharedBridgeImpl = "0xAADA1d8Ec8Bc342a642fAEC52F6b92A2ea4411F3";
const sharedBridgeProxy = "0xc488a65b400769295f8C4b762AdCB3E6a036220b";

const legacyBridgeImplDeployTx = "0x9cd4dda77cc8568be4e846c080c3a3372811386248a10f0c16de9022988900b3";
const legacyBridgeImpl = "0x3aF396F034F64A3DC7A1c5F4295d6a827332f100";

const expectedL1WethAddress = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";
const initialOwner = "0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7";
const expectedOwner = "0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7";
const expectedDelay = 0;
const eraChainId = 271;
const expectedSalt = "0x000000000000000000000000000000000000000000000000000000000000000d";
const expectedHyperchainAddr = "0x5BBdEDe0F0bAc61AA64068b60379fe32ecc0F96C";
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = "0x1574fa776dec8da2071e5f20d71840bfcbd82c2bca9ad68680edfedde1710bc4";
const expectedL2BridgeAddress = "0x5978EE0398104a68De718c70cB60a4afdeD07EEE";
const expectedL1LegacyBridge = "0x26d60F0ac5dd7a8DBE98DCf20c0F4b057Ed62775";
const expectedGenesisBatchCommitment = "0x2d00e5f8d77afcebf58a6b82ae56ba967566fe7dfbcb6760319fb0d215d18ffd";
const expectedIndexRepeatedStorageChanges = BigNumber.from(54);
const expectedProtocolVersion = 24;
const expectedGenesisRoot = "0xabdb766b18a479a5c783a4b80e12686bc8ea3cc2d8a3050491b701d72370ebb5";
const expectedRecursionNodeLevelVkHash = "0xf520cd5b37e74e19fdb369c8d676a04dce8a19457497ac6686d2bb95d94109c8";
const expectedRecursionLeafLevelVkHash = "0x435202d277dd06ef3c64ddd99fda043fc27c2bd8b7c66882966840202c27f4f6";
const expectedRecursionCircuitsSetVksHash = "0x0000000000000000000000000000000000000000000000000000000000000000";
const expectedBootloaderHash = "0x010008e742608b21bf7eb23c1a9d0602047e3618b464c9b59c0fba3b3d7ab66e";
const expectedDefaultAccountHash = "0x01000563374c277a2c1e34659a2a1e87371bb6d852ce142022d497bfb50b9e32";

const expectedGovernance = "0xbF4B985eACb623aAFd0B90D9F8C794fa8585edE9";
const validatorOne = "0x1edC35c96144E77e162e5FbA34343078dab63acD";
const validatorTwo = "0x1230007ae8529E38721669Af4D2fAbc769f0FB21";

const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

async function checkIdenticalBytecode(addr: string, contract: string) {
  const correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  const currentCode = await l1Provider.getCode(addr);

  if (ethers.utils.keccak256(currentCode) == ethers.utils.keccak256(correctCode)) {
    console.log(contract, "bytecode is correct");
  } else {
    throw new Error(contract + " bytecode is not correct");
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function checkCorrectInitCode(txHash: string, contract: ethers.Contract, bytecode: string, params: any[]) {
  const deployTx = await l1Provider.getTransaction(txHash);
  const usedInitCode = await extractInitCode(deployTx.data);
  const correctConstructorData = contract.interface.encodeDeploy(params);
  const correctInitCode = ethers.utils.hexConcat([bytecode, correctConstructorData]);
  if (usedInitCode.toLowerCase() !== correctInitCode.toLowerCase()) {
    throw new Error("Init code is not correct");
  }
}

async function extractInitCode(data: string) {
  const create2FactoryAbi = (await hardhat.artifacts.readArtifact("SingletonFactory")).abi;

  const iface = new ethers.utils.Interface(create2FactoryAbi);
  const initCode = iface.parseTransaction({ data }).args._initCode;
  const salt = iface.parseTransaction({ data }).args._salt;
  if (salt !== expectedSalt) {
    throw new Error("Salt is not correct");
  }

  return initCode;
}

async function extractProxyInitializationData(contract: ethers.Contract, data: string) {
  const initCode = await extractInitCode(data);

  const artifact = await hardhat.artifacts.readArtifact("TransparentUpgradeableProxy");

  // Deployment tx is a concatenation of the init code and the constructor data
  // constructor has the following type `constructor(address _logic, address admin_, bytes memory _data)`

  const constructorData = "0x" + initCode.slice(artifact.bytecode.length);

  const [, , initializeCode] = ethers.utils.defaultAbiCoder.decode(["address", "address", "bytes"], constructorData);

  // Now time to parse the initialize code
  const parsedData = contract.interface.parseTransaction({ data: initializeCode });
  const initializeData = {
    ...parsedData.args._initializeData,
  };

  const usedInitialOwner = initializeData.owner;
  if (usedInitialOwner.toLowerCase() !== initialOwner.toLowerCase()) {
    throw new Error("Initial owner is not correct");
  }

  const usedValidatorTimelock = initializeData.validatorTimelock;
  if (usedValidatorTimelock.toLowerCase() !== validatorTimelock.toLowerCase()) {
    throw new Error("Validator timelock is not correct");
  }
  const usedGenesisUpgrade = initializeData.genesisUpgrade;
  if (usedGenesisUpgrade.toLowerCase() !== genesisUpgrade.toLowerCase()) {
    throw new Error("Genesis upgrade is not correct");
  }
  const usedGenesisBatchHash = initializeData.genesisBatchHash;
  if (usedGenesisBatchHash.toLowerCase() !== expectedGenesisRoot.toLowerCase()) {
    throw new Error("Genesis batch hash is not correct");
  }
  const usedGenesisIndexRepeatedStorageChanges = initializeData.genesisIndexRepeatedStorageChanges;
  if (!usedGenesisIndexRepeatedStorageChanges.eq(expectedIndexRepeatedStorageChanges)) {
    throw new Error("Genesis index repeated storage changes is not correct");
  }

  const usedGenesisBatchCommitment = initializeData.genesisBatchCommitment;
  if (usedGenesisBatchCommitment.toLowerCase() !== expectedGenesisBatchCommitment.toLowerCase()) {
    throw new Error("Genesis batch commitment is not correct");
  }

  const usedProtocolVersion = initializeData.protocolVersion;
  if (!usedProtocolVersion.eq(expectedProtocolVersion)) {
    throw new Error("Protocol version is not correct");
  }

  const diamondCut = initializeData.diamondCut;

  if (diamondCut.initAddress.toLowerCase() !== diamondInit.toLowerCase()) {
    throw new Error("Diamond init address is not correct");
  }

  const expectedFacetCuts: FacetCut[] = Object.values(
    await getCurrentFacetCutsForAdd(adminFacet, gettersFacet, mailboxFacet, executorFacet)
  );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const usedFacetCuts = diamondCut.facetCuts.map((fc: any) => {
    return {
      facet: fc.facet,
      selectors: fc.selectors,
      action: fc.action,
      isFreezable: fc.isFreezable,
    };
  });

  // Now sort to compare
  expectedFacetCuts.sort((a, b) => a.facet.localeCompare(b.facet));
  usedFacetCuts.sort((a, b) => a.facet.localeCompare(b.facet));

  if (expectedFacetCuts.length !== usedFacetCuts.length) {
    throw new Error("Facet cuts length is not correct");
  }

  for (let i = 0; i < expectedFacetCuts.length; i++) {
    const used = usedFacetCuts[i];
    const expected = expectedFacetCuts[i];

    if (used.facet !== expected.facet) {
      throw new Error(`Facet ${i} is not correct`);
    }

    // For the array of selectors it is just easier to hexconcat them and compare
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const usedSelectors = ethers.utils.hexConcat(Array.from(used.selectors).sort() as any[]);
    const expectedSelectors = ethers.utils.hexConcat(expected.selectors.sort());
    if (usedSelectors !== expectedSelectors) {
      throw new Error(`Facet ${i} selectors are not correct`);
    }

    if (used.action !== expected.action) {
      throw new Error(`Facet ${i} action is not correct`);
    }

    if (used.isFreezable !== expected.isFreezable) {
      throw new Error(`Facet ${i} isFreezable is not correct`);
    }
  }

  const [
    usedVerifier,
    // We just unpack verifier params here
    recursionNodeLevelVkHash,
    recursionLeafLevelVkHash,
    recursionCircuitsSetVksHash,
    l2BootloaderBytecodeHash,
    l2DefaultAccountBytecodeHash,
    // priorityTxMaxGasLimit,

    // // We unpack fee params
    // pubdataPricingMode,
    // batchOverheadL1Gas,
    // maxPubdataPerBatch,
    // priorityTxMaxPubdata,
    // maxL2GasPerBatch,
    // minimalL2GasPrice,

    // blobVersionedHashRetriever
  ] = ethers.utils.defaultAbiCoder.decode(
    [
      "address",
      "bytes32",
      "bytes32",
      "bytes32",
      "bytes32",
      "bytes32",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "address",
    ],
    diamondCut.initCalldata
  );

  if (usedVerifier.toLowerCase() !== verifier.toLowerCase()) {
    throw new Error("Verifier is not correct");
  }

  if (recursionNodeLevelVkHash.toLowerCase() !== expectedRecursionNodeLevelVkHash.toLowerCase()) {
    throw new Error("Recursion node level vk hash is not correct");
  }

  if (recursionLeafLevelVkHash.toLowerCase() !== expectedRecursionLeafLevelVkHash.toLowerCase()) {
    throw new Error("Recursion leaf level vk hash is not correct");
  }

  if (recursionCircuitsSetVksHash.toLowerCase() !== expectedRecursionCircuitsSetVksHash.toLowerCase()) {
    throw new Error("Recursion circuits set vks hash is not correct");
  }

  if (l2BootloaderBytecodeHash.toLowerCase() !== expectedBootloaderHash.toLowerCase()) {
    throw new Error("L2 bootloader bytecode hash is not correct");
  }

  if (l2DefaultAccountBytecodeHash.toLowerCase() !== expectedDefaultAccountHash.toLowerCase()) {
    throw new Error("L2 default account bytecode hash is not correct");
  }

  console.log("STM init data correct!");
}

async function checkValidatorTimelock() {
  const artifact = await hardhat.artifacts.readArtifact("ValidatorTimelock");
  const contract = new ethers.Contract(validatorTimelock, artifact.abi, l1Provider);

  const owner = await contract.owner();
  if (owner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error("ValidatorTimelock owner is not correct");
  }

  const usedStm = await contract.stateTransitionManager();
  if (usedStm.toLowerCase() != stm.toLowerCase()) {
    throw new Error("ValidatorTimelock stateTransitionManager is not correct");
  }

  const validatorOneIsSet = await contract.validators(eraChainId, validatorOne);
  if (!validatorOneIsSet) {
    throw new Error("ValidatorTimelock validatorOne is not correct");
  }

  const validatorTwoIsSet = await contract.validators(eraChainId, validatorTwo);
  if (!validatorTwoIsSet) {
    throw new Error("ValidatorTimelock validatorTwo is not correct");
  }

  await checkCorrectInitCode(validatorTimelockDeployTx, contract, artifact.bytecode, [
    initialOwner,
    expectedDelay,
    eraChainId,
  ]);

  console.log("ValidatorTimelock is correct!");
}

async function checkBridgehub() {
  const artifact = await hardhat.artifacts.readArtifact("Bridgehub");
  const contract = new ethers.Contract(bridgeHub, artifact.abi, l1Provider);

  const owner = await contract.owner();
  if (owner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error("ValidatorTimelock owner is not correct");
  }

  const baseToken = await contract.baseToken(eraChainId);
  if (baseToken.toLowerCase() != utils.ETH_ADDRESS_IN_CONTRACTS) {
    throw new Error("Bridgehub baseToken is not correct");
  }

  const hyperchain = await contract.getHyperchain(eraChainId);
  if (hyperchain.toLowerCase() != expectedHyperchainAddr.toLowerCase()) {
    throw new Error("Bridgehub hyperchain is not correct");
  }

  const sharedBridge = await contract.sharedBridge();
  if (sharedBridge.toLowerCase() != sharedBridgeProxy.toLowerCase()) {
    throw new Error("Bridgehub sharedBridge is not correct");
  }

  const usedSTM = await contract.stateTransitionManager(eraChainId);
  if (usedSTM.toLowerCase() != stm.toLowerCase()) {
    throw new Error("Bridgehub stateTransitionManager is not correct");
  }

  const isRegistered = await contract.stateTransitionManagerIsRegistered(usedSTM);
  if (!isRegistered) {
    throw new Error("Bridgehub stateTransitionManager is not registered");
  }

  const tokenIsRegistered = await contract.tokenIsRegistered(utils.ETH_ADDRESS_IN_CONTRACTS);
  if (!tokenIsRegistered) {
    throw new Error("Bridgehub token is not registered");
  }

  console.log("Bridgehub is correct!");
}

async function checkMailbox() {
  const artifact = await hardhat.artifacts.readArtifact("MailboxFacet");
  const contract = new ethers.Contract(mailboxFacet, artifact.abi, l1Provider);

  await checkCorrectInitCode(mailboxFacetDeployTx, contract, artifact.bytecode, [eraChainId]);
  console.log("Mailbox is correct!");
}

async function checkUpgradeHyperchainParams() {
  const artifact = await hardhat.artifacts.readArtifact("GettersFacet");
  const contract = new ethers.Contract(expectedHyperchainAddr, artifact.abi, l1Provider);

  // Note: there is no getters for chainId
  const setBridgehub = await contract.getBridgehub();
  if (setBridgehub != bridgeHub) {
    throw new Error("Bridgehub is not set in Era correctly");
  }
  const setStateTransitionManager = await contract.getStateTransitionManager();
  if (setStateTransitionManager != stm) {
    throw new Error("Bridgehub is not set in Era correctly");
  }
  const setBaseTokenBridge = await contract.getBaseTokenBridge();
  if (setBaseTokenBridge != sharedBridgeProxy) {
    throw new Error("Bridgehub is not set in Era correctly");
  }
  const setBaseToken = await contract.getBaseToken();
  if (setBaseToken != utils.ETH_ADDRESS_IN_CONTRACTS) {
    throw new Error("Bridgehub is not set in Era correctly");
  }
  const baseTokenGasPriceMultiplierNominator = await contract.baseTokenGasPriceMultiplierNominator();
  if (baseTokenGasPriceMultiplierNominator != 1) {
    throw new Error("baseTokenGasPriceMultiplierNominator is not set in Era correctly");
  }
  const baseTokenGasPriceMultiplierDenominator = await contract.baseTokenGasPriceMultiplierDenominator();
  if (baseTokenGasPriceMultiplierDenominator != 1) {
    throw new Error("baseTokenGasPriceMultiplierDenominator is not set in Era correctly");
  }
  const admin = await contract.getAdmin();
  if (admin != expectedGovernance) {
    throw new Error("admin is not set in Era correctly");
  }
  const validatorTimelockIsRegistered = await contract.isValidator(validatorTimelock);
  if (!validatorTimelockIsRegistered) {
    throw new Error("Bridgehub is not set in Era correctly");
  }
  console.log("Validator timelock and admin is set correctly in Era!");
}

async function checkSTMImpl() {
  const artifact = await hardhat.artifacts.readArtifact("StateTransitionManager");
  const contract = new ethers.Contract(stmImpl, artifact.abi, l1Provider);

  await checkCorrectInitCode(stmImplDeployTx, contract, artifact.bytecode, [bridgeHub, maxNumberOfHyperchains]);

  console.log("STM impl correct!");
}

async function checkSTM() {
  const artifact = await hardhat.artifacts.readArtifact("StateTransitionManager");

  const contract = new ethers.Contract(stm, artifact.abi, l1Provider);

  const usedBH = await contract.BRIDGE_HUB();
  if (usedBH.toLowerCase() != bridgeHub.toLowerCase()) {
    throw new Error("STM bridgeHub is not correct");
  }
  const usedMaxNumberOfHyperchains = (await contract.MAX_NUMBER_OF_HYPERCHAINS()).toNumber();
  if (usedMaxNumberOfHyperchains != maxNumberOfHyperchains) {
    throw new Error("STM maxNumberOfHyperchains is not correct");
  }

  const genUpgrade = await contract.genesisUpgrade();
  if (genUpgrade.toLowerCase() != genesisUpgrade.toLowerCase()) {
    throw new Error("STM genesisUpgrade is not correct");
  }

  const storedBatchHashZero = await contract.storedBatchZero();
  if (storedBatchHashZero.toLowerCase() != expectedStoredBatchHashZero.toLowerCase()) {
    throw new Error("STM storedBatchHashZero is not correct");
  }

  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error("STM owner is not correct");
  }

  console.log("STM is correct!");

  await extractProxyInitializationData(contract, (await l1Provider.getTransaction(stmDeployTx)).data);
}

async function checkL1SharedBridgeImpl() {
  const artifact = await hardhat.artifacts.readArtifact("L1SharedBridge");
  const contract = new ethers.Contract(sharedBridgeImpl, artifact.abi, l1Provider);

  await checkCorrectInitCode(sharedBridgeImplDeployTx, contract, artifact.bytecode, [
    expectedL1WethAddress,
    bridgeHub,
    eraChainId,
    expectedHyperchainAddr,
  ]);

  console.log("L1 shared bridge impl correct!");
}

async function checkSharedBridge() {
  const artifact = await hardhat.artifacts.readArtifact("L1SharedBridge");
  const contract = new ethers.Contract(sharedBridgeProxy, artifact.abi, l1Provider);

  const l2BridgeAddr = await contract.l2BridgeAddress(eraChainId);
  if (l2BridgeAddr.toLowerCase() != expectedL2BridgeAddress.toLowerCase()) {
    throw new Error("Shared bridge l2BridgeAddress is not correct");
  }

  const usedLegacyBridge = await contract.legacyBridge();
  if (usedLegacyBridge.toLowerCase() != expectedL1LegacyBridge.toLowerCase()) {
    throw new Error("Shared bridge legacyBridge is not correct");
  }

  const usedOwner = await contract.owner();
  if (usedOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error("Shared bridge owner is not correct");
  }

  console.log("L1 shared bridge correct!");
}

async function checkLegacyBridge() {
  const artifact = await hardhat.artifacts.readArtifact("L1ERC20Bridge");
  const contract = new ethers.Contract(legacyBridgeImpl, artifact.abi, l1Provider);

  await checkCorrectInitCode(legacyBridgeImplDeployTx, contract, artifact.bytecode, [sharedBridgeProxy]);

  console.log("L1 shared bridge impl correct!");
}

async function checkProxyAdmin() {
  await checkIdenticalBytecode(proxyAdmin, "ProxyAdmin");

  const artifact = await hardhat.artifacts.readArtifact("ProxyAdmin");
  const contract = new ethers.Contract(proxyAdmin, artifact.abi, l1Provider);

  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error(`ProxyAdmin owner is not correct ${currentOwner}, ${expectedOwner}`);
  }

  console.log("ProxyAdmin is correct!");
}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("upgrade-consistency-checker")
    .description("upgrade shared bridge for era diamond proxy");

  program.action(async () => {
    await checkIdenticalBytecode(genesisUpgrade, "GenesisUpgrade");
    await checkIdenticalBytecode(upgradeHyperchains, "UpgradeHyperchains");
    await checkIdenticalBytecode(executorFacet, "ExecutorFacet");
    await checkIdenticalBytecode(gettersFacet, "GettersFacet");
    await checkIdenticalBytecode(adminFacet, "AdminFacet");
    await checkIdenticalBytecode(bridgeHubImpl, "Bridgehub");
    await checkIdenticalBytecode(verifier, "TestnetVerifier");
    await checkIdenticalBytecode(diamondInit, "DiamondInit");

    await checkMailbox();
    // we can only check this after the diamond cut
    // await checkUpgradeHyperchainParams();

    await checkProxyAdmin();

    await checkValidatorTimelock();
    await checkBridgehub();

    await checkL1SharedBridgeImpl();
    await checkSharedBridge();

    await checkLegacyBridge();

    await checkSTMImpl();
    await checkSTM();
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
