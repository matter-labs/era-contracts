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
const genesisUpgrade = "0xDdc72e56A3b90793271FF0EA9a762294f163F992";
const validatorTimelockDeployTx = "0x1ada4121db6e83bfe38f1f92e31c0931e2f0f2b830429841a7d264c56cceb8b0";
const validatorTimelock = "0xc47CBbc601dbB65439e7b02B0d19bbA9Dba57442";
const upgradeHyperchains = "0xc029cE1EB5C61C4a3B2a6EE920bb3B7b026bc00b";

const verifier = "0x82856fED36d36e1d4db24398bC2056C440cB45FC";
const proxyAdmin = "0xCb7F8e556Ef02771eA32F54e767D6F9742ED31c2";

const bridgeHubImpl = "0x22c456Cb8E657bD48e14E9a54CE20169d78CB0F7";
const bridgeHub = "0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE";

const executorFacet = "0xd56f4696ecbE9ADc2e1539F5311ae6C92F4B2BAd";
const adminFacet = "0x21924127192db478faDf6Ae07f57df928EBCA6AE";
const mailboxFacetDeployTx = "0xad8028a8a1c7fe71e40fb6e32b80f5893b6b26af5475d9a014b9510faf460090";
const mailboxFacet = "0x445aD49fC6d1845ec774783659aA5351381b0c49";
const gettersFacet = "0xbF4C2dfBe9E722F0A87E104c3af5780d49872745";

const diamondInit = "0x17384Fd6Cc64468b69df514A940caC89B602d01c";

const stmImplDeployTx = "0x6dacf003368a922b9f916393f3c11c869c1f614c16345667cabd1d8b890ec0cb";
const stmImpl = "0x91E088D2F36500c4826E5623c9C14Dd90912c23E";
const stmDeployTx = "0x11ceebf3d0b95a4a49f798c937fd3e0085dc01a4e5d497b60b5072b13e58235a";
const stm = "0x6F03861D12E6401623854E494beACd66BC46e6F0";

const sharedBridgeImplDeployTx = "0x6dacf003368a922b9f916393f3c11c869c1f614c16345667cabd1d8b890ec0cb";
const sharedBridgeImpl = "0x91E088D2F36500c4826E5623c9C14Dd90912c23E";
const sharedBridgeProxy = "0x6F03861D12E6401623854E494beACd66BC46e6F0";

const legacyBridgeImplDeployTx = "0xc0640213aa843f812c44d63723b5dc03064d8e5a32d85e94689e3273df6c3ef5";
const legacyBridgeImpl = "0x8fE595B3f92AA34962d7A8aF106Fa50A3e4FC6fA";

const expectedL1WethAddress = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";
const initialOwner = "0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7";
const expectedOwner = "0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7";
const expectedDelay = 0;
const eraChainId = 270;
const expectedSalt = "0x0000000000000000000000000000000000000000000000000000000000000005";
const expectedHyperchainAddr = "0x6d6e010A2680E2E5a3b097ce411528b36d880EF6";
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = "0x53dc316f108d1b64412be840e0ab89193e94ba6c4af8b9ca57d39ad4d782e0f4";
const expectedL2BridgeAddress = "0xCEB8d4888d2025aEaAD0272175281e0CaFC33152";
const expectedL1LegacyBridge = "0x7303B5Ce64f1ADB0558572611a0b90620b6dd5F4";
const expectedGenesisBatchCommitment = "0x49276362411c40c07ab01d3dfa9428abca95e361d8c980cd39f1ab6a9c561c0c";
const expectedIndexRepeatedStorageChanges = BigNumber.from(54);
const expectedProtocolVersion = 23;
const expectedGenesisRoot = "0xabdb766b18a479a5c783a4b80e12686bc8ea3cc2d8a3050491b701d72370ebb5";
const expectedRecursionNodeLevelVkHash = "0xf520cd5b37e74e19fdb369c8d676a04dce8a19457497ac6686d2bb95d94109c8";
const expectedRecursionLeafLevelVkHash = "0x435202d277dd06ef3c64ddd99fda043fc27c2bd8b7c66882966840202c27f4f6";
const expectedRecursionCircuitsSetVksHash = "0x0000000000000000000000000000000000000000000000000000000000000000";
const expectedBootloaderHash = "0x010008e7f0f15ed191392960117f88fe371348982b28a033c7207ed2c09bc0f4";
const expectedDefaultAccountHash = "0x01000563374c277a2c1e34659a2a1e87371bb6d852ce142022d497bfb50b9e32";

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
  // console.log(parsedData);
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
    throw new Error("ProxyAdmin owner is not correct");
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
