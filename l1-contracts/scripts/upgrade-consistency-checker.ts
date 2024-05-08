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
const genesisUpgrade = "0xc6aB8b3b93f3E47fb4163eB9Dc7A61E1a5D86369";
const validatorTimelockDeployTx = "0x420e0dddae4a1565fee430ecafa8f5ddbc3eebee2666d0c91f97a47bf054eeb4";
const validatorTimelock = "0xc2d7a7Bd59a548249e64C1a587220c0E4F6F439E";
const upgradeHyperchains = "0xb2963DDc6694a989B527AED0B1E19f9F0675AE4d";

const verifier = "0x9D6c59D9A234F585B367b4ba3C62e5Ec7A6179FD";
const proxyAdmin = "0xf2c1d17441074FFb18E9A918db81A17dB1752146";

const bridgeHubImpl = "0xF9D2E98Ed518eC6Daac0579a9707d83da55D5f89";
const bridgeHub = "0x5B5c82f4Da996e118B127880492a23391376F65c";

const executorFacet = "0x1a451d9bFBd176321966e9bc540596Ca9d39B4B1";
const adminFacet = "0x342a09385E9BAD4AD32a6220765A6c333552e565";
const mailboxFacetDeployTx = "0x2fa6af6e9317089be2734ffae73771c8099382d390d4edbb6c35e2db7f73b152";
const mailboxFacet = "0x7814399116C17F2750Ca99cBFD2b75bA9a0793d7";
const gettersFacet = "0x345c6ca2F3E08445614f4299001418F125AD330a";

const diamondInit = "0x05D865AE297d236Bc5C7988328d02A00b3D38a4F";

const stmImplDeployTx = "0x7a077accd4ee39d14b6c23ef31ece4a84c87aff41cd64fd4d2ac23a3885dd4f8";
const stmImpl = "0x3060D61538fC91B6580e34C5b5D09651CBB9c609";
const stmDeployTx = "0x30138b826e8f8f855e7fe9e6153d49376b53bce71c34cb2a78e186b12156c966";
const stm = "0x280372beAAf440C52a2ed893daa14CDACc0422b8";

const sharedBridgeImplDeployTx = "0xd24d38cab0beb62f6de9a83cd0a5d7e339e985ba84ac6ef07a336efd79ae333a";
const sharedBridgeImpl = "0x3819200C978d8A589a1e28A2e8fEb9a0CAD700F7";
const sharedBridgeProxy = "0x241F19eA8CcD04515b309f1C9953A322F51891FC";

const legacyBridgeImplDeployTx = "0xd8cca5843318ca176afd1075ca6fbb941837a641324300d3719f9189e49fd62c";
const legacyBridgeImpl = "0xbf3d4109D65A66c629D1999fb630bE2eE16d7038";

const expectedL1WethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const initialOwner = "0x71d84c3404a6ae258E6471d4934B96a2033F9438";
const expectedOwner = "0x71d84c3404a6ae258E6471d4934B96a2033F9438";
const expectedDelay = 0;
const eraChainId = 324;
const expectedSalt = "0x0000000000000000000000000000000000000000000000000000000000000000";
const expectedHyperchainAddr = "0x32400084c286cf3e17e7b677ea9583e60a000324";
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = "0x1574fa776dec8da2071e5f20d71840bfcbd82c2bca9ad68680edfedde1710bc4";
const expectedL2BridgeAddress = "0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102";
const expectedL1LegacyBridge = "0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063";
const expectedGenesisBatchCommitment = "0x2d00e5f8d77afcebf58a6b82ae56ba967566fe7dfbcb6760319fb0d215d18ffd";
const expectedIndexRepeatedStorageChanges = BigNumber.from(54);
const expectedProtocolVersion = 24;
const expectedGenesisRoot = "0xabdb766b18a479a5c783a4b80e12686bc8ea3cc2d8a3050491b701d72370ebb5";
const expectedRecursionNodeLevelVkHash = "0xf520cd5b37e74e19fdb369c8d676a04dce8a19457497ac6686d2bb95d94109c8";
const expectedRecursionLeafLevelVkHash = "0x435202d277dd06ef3c64ddd99fda043fc27c2bd8b7c66882966840202c27f4f6";
const expectedRecursionCircuitsSetVksHash = "0x0000000000000000000000000000000000000000000000000000000000000000";
const expectedBootloaderHash = "0x010008e742608b21bf7eb23c1a9d0602047e3618b464c9b59c0fba3b3d7ab66e";
const expectedDefaultAccountHash = "0x01000563374c277a2c1e34659a2a1e87371bb6d852ce142022d497bfb50b9e32";

const validatorOne = "0x0D3250c3D5FAcb74Ac15834096397a3Ef790ec99";
const validatorTwo = "0x3527439923a63F8C13CF72b8Fe80a77f6e572092";

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
    await checkIdenticalBytecode(verifier, eraChainId == 324 ? "Verifier" : "TestnetVerifier");
    await checkIdenticalBytecode(diamondInit, "DiamondInit");

    await checkMailbox();

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
