/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url } from "./utils";
import { BigNumber, ethers } from "ethers";
import { Provider, utils } from "zksync-ethers";
import { FacetCut, getCurrentFacetCutsForAdd } from "../src.ts/diamondCut";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const genesisUpgrade = '0x7315cf22Ffcb7bDb21aAA0D65112fBB4716111A4';
const validatorTimelockDeployTx = '0x14e27087d35a71861829a7f4ef472cfd0c84f91f87f607f522fc4f88f6c8733b';
const validatorTimelock = '0x72518E0269E72650243bC98c7Ce9c5b3736B565D';
const upgradeHyperchains = '0xC04629FC3266F3c1209f31b9ab1176C5f195b312';
const proxyAdmin = '0xF5c6b1aec9d019cC7Ec5Fc6609D9978617b5E193';

const diamondInit = '0x4f74AbD5df12F80757388d1918E5BB964bee23fF';

const bridgeHubImpl = '0xd7edDc9E0FD36650Bb7aD5e928a0c305E3132025';
const bridgeHub = '0x4dDcec5eCD9B44E900869Eb2696bb57Bc5413582';

const executorFacet = '0x568018Faa74955146Ea7aebC505a3e28cfCF1DcA';
const mailboxFacetDeployTx = '0x19b67214f91c2122968fe74d82d90e7d060ea760bcaf6d8db5d1085f9ecd4618';
const mailboxFacet = '0xe7B9B2048f58AafACD708D2D71348ddbde01da1D';
const gettersFacet = '0xd11012099Faa1Ce1E746425A550c966d8Df0319F';
const adminFacet = '0xAe800b0E4148fa63218681611E3058B9d5d0a4fa';

const verifier = '0xd1396F2Ea18EaEBE9b95205dAE3949E837d383D7';

const stmImplDeployTx = '0x3ccba9f0285bf51a8b87d7b0c63b7404a07d1d135ffb3d69b085c23404b43c59';
const stmImpl = '0xc05B2734379A31972a58E52A6D64611bb855Be45';
const stmDeployTx = '0x15c992fe9392ae99be918472992d2597e162a884cda48d21d38a7205e009b0bb';
const stm = '0x95416daeF5b50a62Ea5A246be565e9bAFB159683';

const legacyBridgeImplDeployTx = '0xde74e9d2c71c0fe0c908cecbe4ff219cb498496c2e641fe2631c22d597ca19e5';
const legacyBridgeImpl = '0x7aBB32De60Ed3bFC393f5e956ED0657046c8594e';

const sharedBridgeImplDeployTx = '0x138c786a9c8e682d4afb325df449282f6fe6926b2b140bc3ad7898e5ef52403c';
const sharedBridgeImpl = '0x67487118dD9Db5a28e2908F85684cD477d654260';
const sharedBridgeProxy = '0xA8695C6371ef45DeBcf3bab4de6ca1e39787903F';

const expectedL1WethAddress = '0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9';
const initialOwner = '0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7';
const expectedOwner = '0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7';
const expectedDelay = 0;
const eraChainId = 270;
const expectedSalt = '0x0000000000000000000000000000000000000000000000000000000000000003';
const expectedHyperchainAddr = '0x6d6e010A2680E2E5a3b097ce411528b36d880EF6';
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = '0x53dc316f108d1b64412be840e0ab89193e94ba6c4af8b9ca57d39ad4d782e0f4';
const expectedL2BridgeAddress = '0xCEB8d4888d2025aEaAD0272175281e0CaFC33152';
const expectedL1LegacyBridge = '0x7303B5Ce64f1ADB0558572611a0b90620b6dd5F4';
const expectedGenesisBatchCommitment = '0x49276362411c40c07ab01d3dfa9428abca95e361d8c980cd39f1ab6a9c561c0c';
const expectedIndexRepeatedStorageChanges = BigNumber.from(54);
const expectedProtocolVersion = 23;
const expectedGenesisRoot = '0xabdb766b18a479a5c783a4b80e12686bc8ea3cc2d8a3050491b701d72370ebb5';
const expectedRecursionNodeLevelVkHash = '0xf520cd5b37e74e19fdb369c8d676a04dce8a19457497ac6686d2bb95d94109c8';
const expectedRecursionLeafLevelVkHash = '0x435202d277dd06ef3c64ddd99fda043fc27c2bd8b7c66882966840202c27f4f6';
const expectedRecursionCircuitsSetVksHash = '0x0000000000000000000000000000000000000000000000000000000000000000';  
const expectedBootloaderHash = '0x010008e7f0f15ed191392960117f88fe371348982b28a033c7207ed2c09bc0f4';
const expectedDefaultAccountHash = '0x01000563374c277a2c1e34659a2a1e87371bb6d852ce142022d497bfb50b9e32';

const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

async function checkIdenticalBytecode(addr: string, contract: string) {
  const correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  const currentCode = await l1Provider.getCode(addr);

  if (ethers.utils.keccak256(currentCode) == ethers.utils.keccak256(correctCode)) {
    console.log(contract, 'bytecode is correct');
  } else {
    throw new Error(contract + ' bytecode is not correct');
  }
}

async function checkCorrectInitCode(txHash: string, contract: ethers.Contract, bytecode: string, params: any[]) {
  const deployTx = await l1Provider.getTransaction(txHash);
  const usedInitCode = await extractInitCode(deployTx.data);
  const correctConstructorData = contract.interface.encodeDeploy(params);
  const correctInitCode = ethers.utils.hexConcat([bytecode, correctConstructorData]);
  if (usedInitCode.toLowerCase() !== correctInitCode.toLowerCase()) {
    throw new Error(`Init code is not correct`);
  }

}

async function extractInitCode(data: string) {
  const create2FactoryAbi = (await hardhat.artifacts.readArtifact('SingletonFactory')).abi;

  const iface = new ethers.utils.Interface(create2FactoryAbi);
  const initCode = iface.parseTransaction({ data }).args._initCode;
  const salt = iface.parseTransaction({ data }).args._salt;
  if(salt !== expectedSalt) {
    throw new Error('Salt is not correct');
  }

  return initCode;
}

async function extractProxyInitializationData(contract: ethers.Contract, data: string) {
  const initCode = await extractInitCode(data);

  const artifact = (await hardhat.artifacts.readArtifact('TransparentUpgradeableProxy'));
  const proxyInterface = new ethers.utils.Interface(artifact.abi);

  // Deployment tx is a concatenation of the init code and the constructor data
  // constructor has the following type `constructor(address _logic, address admin_, bytes memory _data)`

  const constructorData = '0x' + initCode.slice(artifact.bytecode.length);

  const [,, initializeCode] = ethers.utils.defaultAbiCoder.decode(['address', 'address', 'bytes'], constructorData);

  // Now time to parse the initialize code
  const parsedData = contract.interface.parseTransaction({ data: initializeCode} );
  // console.log(parsedData);
  const initializeData = {
    ...parsedData.args._initializeData
  };

  const usedInitialOwner = initializeData.owner;
  if (usedInitialOwner.toLowerCase() !== initialOwner.toLowerCase()) {
    throw new Error('Initial owner is not correct');
  }

  const usedValidatorTimelock = initializeData.validatorTimelock;
  if (usedValidatorTimelock.toLowerCase() !== validatorTimelock.toLowerCase()) {
    throw new Error('Validator timelock is not correct');
  }
  const usedGenesisUpgrade = initializeData.genesisUpgrade;
  if (usedGenesisUpgrade.toLowerCase() !== genesisUpgrade.toLowerCase()) {
    throw new Error('Genesis upgrade is not correct');
  }
  const usedGenesisBatchHash = initializeData.genesisBatchHash;
  if (usedGenesisBatchHash.toLowerCase() !== expectedGenesisRoot.toLowerCase()) {
    throw new Error('Genesis batch hash is not correct');
  }
  const usedGenesisIndexRepeatedStorageChanges = initializeData.genesisIndexRepeatedStorageChanges;
  if(!usedGenesisIndexRepeatedStorageChanges.eq(expectedIndexRepeatedStorageChanges)) {
    throw new Error('Genesis index repeated storage changes is not correct');
  }

  const usedGenesisBatchCommitment = initializeData.genesisBatchCommitment;
  if (usedGenesisBatchCommitment.toLowerCase() !== expectedGenesisBatchCommitment.toLowerCase()) {
    throw new Error('Genesis batch commitment is not correct');
  }

  const usedProtocolVersion = initializeData.protocolVersion;
  if (!usedProtocolVersion.eq(expectedProtocolVersion)) {
    throw new Error('Protocol version is not correct');
  }

  const diamondCut = initializeData.diamondCut;

  if(diamondCut.initAddress.toLowerCase() !== diamondInit.toLowerCase()) {  
    throw new Error('Diamond init address is not correct');
  }

  let expectedFacetCuts: FacetCut[] = Object.values(
    await getCurrentFacetCutsForAdd(
      adminFacet,
      gettersFacet,
      mailboxFacet,
      executorFacet
    )
  );
  const usedFacetCuts = diamondCut.facetCuts.map((fc: any) => {
    return {
      facet: fc.facet,
      selectors: fc.selectors,
      action: fc.action,
      isFreezable: fc.isFreezable
    }
  });;

  // Now sort to compare
  expectedFacetCuts.sort((a, b) => a.facet.localeCompare(b.facet));
  usedFacetCuts.sort((a, b) => a.facet.localeCompare(b.facet));

  if(expectedFacetCuts.length !== usedFacetCuts.length) {
    throw new Error('Facet cuts length is not correct');
  }

  for(let i = 0; i < expectedFacetCuts.length; i++) {
    const used = usedFacetCuts[i];
    const expected = expectedFacetCuts[i];

    if(used.facet !== expected.facet) {
      throw new Error(`Facet ${i} is not correct`);
    }

    // For the array of selectors it is just easier to hexconcat them and compare
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
  ] = ethers.utils.defaultAbiCoder.decode([
    'address', 'bytes32', 'bytes32', 'bytes32', 'bytes32', 'bytes32', 'uint256',
    'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'
  ], diamondCut.initCalldata);

  if (usedVerifier.toLowerCase() !== verifier.toLowerCase()) {
    throw new Error('Verifier is not correct');
  }

  if (recursionNodeLevelVkHash.toLowerCase() !== expectedRecursionNodeLevelVkHash.toLowerCase()) {
    throw new Error('Recursion node level vk hash is not correct');
  }

  if (recursionLeafLevelVkHash.toLowerCase() !== expectedRecursionLeafLevelVkHash.toLowerCase()) {
    throw new Error('Recursion leaf level vk hash is not correct');
  }

  if (recursionCircuitsSetVksHash.toLowerCase() !== expectedRecursionCircuitsSetVksHash.toLowerCase()) {
    throw new Error('Recursion circuits set vks hash is not correct');
  }

  if (l2BootloaderBytecodeHash.toLowerCase() !== expectedBootloaderHash.toLowerCase()) {
    throw new Error('L2 bootloader bytecode hash is not correct');
  }

  if (l2DefaultAccountBytecodeHash.toLowerCase() !== expectedDefaultAccountHash.toLowerCase()) {
    throw new Error('L2 default account bytecode hash is not correct');
  }

  console.log('STM init data correct!');
}

async function checkValidatorTimelock() {
  const artifact = (await hardhat.artifacts.readArtifact('ValidatorTimelock'));
  const contract = new ethers.Contract(
    validatorTimelock,
    artifact.abi,
    l1Provider
  );

  const owner = await contract.owner();
  if (owner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error('ValidatorTimelock owner is not correct');
  }

  const usedStm = await contract.stateTransitionManager();
  if (usedStm.toLowerCase() != stm.toLowerCase()) {
    throw new Error('ValidatorTimelock stateTransitionManager is not correct');
  }

  await checkCorrectInitCode(
    validatorTimelockDeployTx,
    contract,
    artifact.bytecode,
    [initialOwner, expectedDelay, eraChainId]
  );

  console.log('ValidatorTimelock is correct!');
}

async function checkBridgehub() {
  const artifact = (await hardhat.artifacts.readArtifact('Bridgehub'));
  const contract = new ethers.Contract(
    bridgeHub,
    artifact.abi,
    l1Provider
  );

  const owner = await contract.owner();
  if (owner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error('ValidatorTimelock owner is not correct');
  }

  const baseToken = await contract.baseToken(eraChainId);
  if (baseToken.toLowerCase() != utils.ETH_ADDRESS_IN_CONTRACTS) {
    throw new Error('Bridgehub baseToken is not correct');
  }

  const hyperchain = await contract.getHyperchain(eraChainId);
  if (hyperchain.toLowerCase() != expectedHyperchainAddr.toLowerCase()) {
    throw new Error('Bridgehub hyperchain is not correct');
  }

  const sharedBridge = await contract.sharedBridge();
  if (sharedBridge.toLowerCase() != sharedBridgeProxy.toLowerCase()) {
    throw new Error('Bridgehub sharedBridge is not correct');
  }

  const usedSTM = await contract.stateTransitionManager(eraChainId);
  if (usedSTM.toLowerCase() != stm.toLowerCase()) {
    throw new Error('Bridgehub stateTransitionManager is not correct');
  }

  const isRegistered = await contract.stateTransitionManagerIsRegistered(usedSTM);
  if (!isRegistered) {
    throw new Error('Bridgehub stateTransitionManager is not registered');
  }

  const tokenIsRegistered = await contract.tokenIsRegistered(utils.ETH_ADDRESS_IN_CONTRACTS);
  if (!tokenIsRegistered) {
    throw new Error('Bridgehub token is not registered');
  }

  console.log('Bridgehub is correct!');
}

async function checkMailbox() {
  const artifact = (await hardhat.artifacts.readArtifact('MailboxFacet'));
  const contract = new ethers.Contract(
    mailboxFacet,
    artifact.abi,
    l1Provider
  );

  await checkCorrectInitCode(
    mailboxFacetDeployTx,
    contract,
    artifact.bytecode,
    [eraChainId]
  );
  console.log('Mailbox is correct!');
}

async function checkSTMImpl() {
  const artifact = (await hardhat.artifacts.readArtifact('StateTransitionManager'));
  const contract = new ethers.Contract(
    stmImpl,
    artifact.abi,
    l1Provider
  );

  await checkCorrectInitCode(
    stmImplDeployTx,
    contract,
    artifact.bytecode,
    [bridgeHub, maxNumberOfHyperchains]
  );

  console.log('STM impl correct!');
}

async function checkSTM() {
  const artifact = (await hardhat.artifacts.readArtifact('StateTransitionManager'));

  const contract = new ethers.Contract(
    stm,
    artifact.abi,
    l1Provider
  );


  const usedBH = await contract.BRIDGE_HUB();
  if (usedBH.toLowerCase() != bridgeHub.toLowerCase()) {
    throw new Error('STM bridgeHub is not correct');
  }
  const usedMaxNumberOfHyperchains = (await contract.MAX_NUMBER_OF_HYPERCHAINS()).toNumber();
  if (usedMaxNumberOfHyperchains != maxNumberOfHyperchains) {
    throw new Error('STM maxNumberOfHyperchains is not correct');
  }

  const genUpgrade = await contract.genesisUpgrade();
  if (genUpgrade.toLowerCase() != genesisUpgrade.toLowerCase()) {
    throw new Error('STM genesisUpgrade is not correct');
  }

  const storedBatchHashZero = await contract.storedBatchZero();
  if (storedBatchHashZero.toLowerCase() != expectedStoredBatchHashZero.toLowerCase()) {
    throw new Error('STM storedBatchHashZero is not correct');
  }
  
  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error('STM owner is not correct');
  }

  console.log('STM is correct!');

  await extractProxyInitializationData(contract, (await l1Provider.getTransaction(stmDeployTx)).data);
}

async function checkL1SharedBridgeImpl() {
  const artifact = (await hardhat.artifacts.readArtifact('L1SharedBridge'));
  const contract = new ethers.Contract(
    sharedBridgeImpl,
    artifact.abi,
    l1Provider
  );

  await checkCorrectInitCode(
    sharedBridgeImplDeployTx,
    contract,
    artifact.bytecode,
    [expectedL1WethAddress, bridgeHub, eraChainId, expectedHyperchainAddr]
  );

  console.log('L1 shared bridge impl correct!');
}

async function checkSharedBridge() {
  const artifact = (await hardhat.artifacts.readArtifact('L1SharedBridge'));
  const contract = new ethers.Contract(
    sharedBridgeProxy,
    artifact.abi,
    l1Provider
  );

  const l2BridgeAddr = await contract.l2BridgeAddress(eraChainId);
  if (l2BridgeAddr.toLowerCase() != expectedL2BridgeAddress.toLowerCase()) {
    throw new Error('Shared bridge l2BridgeAddress is not correct');
  }

  const usedLegacyBridge = await contract.legacyBridge();
  if (usedLegacyBridge.toLowerCase() != expectedL1LegacyBridge.toLowerCase()) {
    throw new Error('Shared bridge legacyBridge is not correct');
  }

  const usedOwner = await contract.owner();
  if (usedOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error('Shared bridge owner is not correct');
  }

  console.log('L1 shared bridge correct!');
}

async function checkLegacyBridge() {
  const artifact = (await hardhat.artifacts.readArtifact('L1ERC20Bridge'));
  const contract = new ethers.Contract(
    legacyBridgeImpl,
    artifact.abi,
    l1Provider
  );

  await checkCorrectInitCode(
    legacyBridgeImplDeployTx,
    contract,
    artifact.bytecode,
    [sharedBridgeProxy]
  );

  console.log('L1 shared bridge impl correct!');
}

async function checkProxyAdmin() {
  await checkIdenticalBytecode(proxyAdmin, 'ProxyAdmin');

  const artifact = (await hardhat.artifacts.readArtifact('ProxyAdmin'));
  const contract = new ethers.Contract(
    proxyAdmin,
    artifact.abi,
    l1Provider
  );

  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error('ProxyAdmin owner is not correct');
  }

  console.log('ProxyAdmin is correct!');
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-consistency-checker").description("upgrade shared bridge for era diamond proxy");

  program
    .action(async (cmd) => {
      await checkIdenticalBytecode(genesisUpgrade, 'GenesisUpgrade');
      await checkIdenticalBytecode(upgradeHyperchains, 'UpgradeHyperchains');
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

function expectedDiamondCut() {

}
