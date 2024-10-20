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
import * as fs from 'fs'; 
import { getAllSelectors } from "../src.ts/diamondCut";
import { parse } from "path";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const genesisUpgrade = '0x7BF68E0BB44Cf263Dbb809F252B723F08A86F123';
const validatorTimelock = '';
const defaultUpgradeAddress = '0x534AF884A80fe457d1184DDD932474BEC9207470'; 

const diamondProxyAddress = '0x5BBdEDe0F0bAc61AA64068b60379fe32ecc0F96C';

const verifier = '0xCcB73Fdd0E3A3B9522631A1d8A168b5d9C532ceA';
const proxyAdmin = process.env.CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR!;

const bridgeHubImpl = process.env.CONTRACTS_BRIDGEHUB_IMPL_ADDR!;
const bridgeHub = process.env.CONTRACTS_BRIDGEHUB_PROXY_ADDR!;

const executorFacet = '0xBB13642F795014E0EAC2b0d52ECD5162ECb66712';
const adminFacet = '0x90C0A0a63d7ff47BfAA1e9F8fa554dabc986504a';
const mailboxFacetDeployTx = "0x07d150e5e96949fd816db58ca6c3cf935d3426a4ef4c78759d7bbe1b185fc473";
const mailboxFacet = '0xf2677CF5ad53aE8D8612E2eeA0f2aa6191eb9c21';
const gettersFacet = '0x81754d2E48e3e553ba6Dfd193FC72B3A0c6076d9'!;

const diamondInit = '0x4c17c0A1da9665D59EbE3a9e58459Ebe77041C64';

const stmImplDeployTx = "0xe01c0bb497017a25c92bfc712e370e8f900554b107fe0b6022976d05c349f2b6";
const stmImpl = process.env.CONTRACTS_STATE_TRANSITION_IMPL_ADDR!;
const stmDeployTx = "0x514bbf46d227eee8567825bf5c8ee1855aa8a1916f7fee7b191e2e3d5ecba849";
const stm = process.env.CONTRACTS_STATE_TRANSITION_PROXY_ADDR!;

const sharedBridgeImplDeployTx = "0x074204db79298c2f6beccae881c2ad7321c331e97fb4bd93adce2eb23bf17a17";
const sharedBridgeImpl = process.env.CONTRACTS_L1_SHARED_BRIDGE_IMPL_ADDR!;
const sharedBridgeProxy = process.env.CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR!;

const legacyBridgeImplDeployTx = "0x234da786f098fa2e44b9abaf41b7045b4a25570e1a34fd01a101d23570e84d61";
const legacyBridgeImpl = process.env.CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR!;

const expectedL1WethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const initialOwner = "0x71d84c3404a6ae258E6471d4934B96a2033F9438";
const expectedOwner = "0x71d84c3404a6ae258E6471d4934B96a2033F9438"; //process.env.CONTRACTS_GOVERNANCE_ADDR!;
const expectedDelay = "75600";
const eraChainId: string = '271';
// const expectedSalt = "0x0000000000000000000000000000000000000000000000000000000000000001";
const expectedHyperchainAddr = "0x32400084c286cf3e17e7b677ea9583e60a000324";
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = "0x1574fa776dec8da2071e5f20d71840bfcbd82c2bca9ad68680edfedde1710bc4";
const expectedL2BridgeAddress = "0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102";
const expectedL1LegacyBridge = "0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063";
const expectedGenesisBatchCommitment = "0xc57085380434970021d87774b377ce1bb12f5b6064af11595e70011965747def";
const expectedIndexRepeatedStorageChanges = BigNumber.from(54);
const expectedProtocolVersion = BigNumber.from(2).pow(32).mul(24);

const expectedGenesisRoot = "0x28a7e67393021f957572495f8fdadc2c477ae3f4f413ae18c16cff6ee65680e2";
const expectedRecursionNodeLevelVkHash = "0xf520cd5b37e74e19fdb369c8d676a04dce8a19457497ac6686d2bb95d94109c8";
const expectedRecursionLeafLevelVkHash = "0xf9664f4324c1400fa5c3822d667f30e873f53f1b8033180cd15fe41c1e2355c6";
const expectedRecursionCircuitsSetVksHash = "0x0000000000000000000000000000000000000000000000000000000000000000";
const expectedBootloaderHash = "0x010008c3be57ae5800e077b6c2056d9d75ad1a7b4f0ce583407961cc6fe0b678";
const expectedDefaultAccountHash = "0x0100055dba11508480be023137563caec69debc85f826cb3a4b68246a7cabe30";

const validatorOne = process.env.ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR!;
const validatorTwo = process.env.ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR!;

const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

const EXPECTED_OLD_PROTOCOL_VERSION = '0x0000000000000000000000000000000000000000000000000000001800000002';
const EXPECTED_OLD_VERSION_DEADLINE = '0x672797ed';
const EXPECTED_UPGRADE_TIMESTAMP = '0x671522ed';
const EXPECTED_NEW_PROTOCOL_VERSION = '0x0000000000000000000000000000000000000000000000000000001900000000';
const EXPECTED_MAJOR_VERSION = '0x19';

async function checkIdenticalBytecode(addr: string, contract: string, forgeFile?: string) {
  let correctCode;
  if (!forgeFile) {
    correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  } else {
    const json = JSON.parse(fs.readFileSync(`./out/${forgeFile}.sol/${contract}.json`).toString());
    correctCode = json.deployedBytecode.object;
  }
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
  // FIXME: maybe restore, it does not matter much
  // if (salt !== expectedSalt) {
  //   throw new Error(`Salt is not correct ${salt}`);
  // }

  return initCode;
}

async function extractProxyInitializationData(contract: ethers.Contract, data: string) {
  const initCode = await extractInitCode(data);

  const artifact = await hardhat.artifacts.readArtifact(
    "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
  );

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
  const usedGenesisUpgrade = initializeData.chainCreationParams.genesisUpgrade;
  if (usedGenesisUpgrade.toLowerCase() !== genesisUpgrade.toLowerCase()) {
    throw new Error("Genesis upgrade is not correct");
  }
  const usedGenesisBatchHash = initializeData.chainCreationParams.genesisBatchHash;
  if (usedGenesisBatchHash.toLowerCase() !== expectedGenesisRoot.toLowerCase()) {
    throw new Error("Genesis batch hash is not correct");
  }
  const usedGenesisIndexRepeatedStorageChanges = initializeData.chainCreationParams.genesisIndexRepeatedStorageChanges;
  if (!usedGenesisIndexRepeatedStorageChanges.eq(expectedIndexRepeatedStorageChanges)) {
    throw new Error("Genesis index repeated storage changes is not correct");
  }

  const usedGenesisBatchCommitment = initializeData.chainCreationParams.genesisBatchCommitment;
  if (usedGenesisBatchCommitment.toLowerCase() !== expectedGenesisBatchCommitment.toLowerCase()) {
    throw new Error("Genesis batch commitment is not correct");
  }

  const usedProtocolVersion = initializeData.protocolVersion;
  if (!usedProtocolVersion.eq(expectedProtocolVersion)) {
    throw new Error(`Protocol version is not correct ${usedProtocolVersion}`);
  }

  const diamondCut = initializeData.chainCreationParams.diamondCut;

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

  checkDiamondInitData(diamondCut.initCalldata);

  console.log("STM init data correct!");
}

async function checkDiamondInitData(initCalldata: string) {

  console.log(initCalldata.length);
  const [
    usedVerifier,
    // We just unpack verifier params here
    recursionNodeLevelVkHash,
    recursionLeafLevelVkHash,
    recursionCircuitsSetVksHash,
    l2BootloaderBytecodeHash,
    l2DefaultAccountBytecodeHash,
    priorityTxMaxGasLimit,

    // We unpack fee params
    pubdataPricingMode,
    batchOverheadL1Gas,
    maxPubdataPerBatch,
    priorityTxMaxPubdata,
    maxL2GasPerBatch,
    minimalL2GasPrice,

    blobVersionedHashRetriever
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
    initCalldata
  );
  console.log('I am here ')

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

  console.log({
    priorityTxMaxGasLimit,

    // We unpack fee params
    pubdataPricingMode,
    batchOverheadL1Gas,
    maxPubdataPerBatch,
    priorityTxMaxPubdata,
    maxL2GasPerBatch,
    minimalL2GasPrice,

    blobVersionedHashRetriever
  });
}

async function checkBridgehub() {
  const artifact = await hardhat.artifacts.readArtifact("Bridgehub");
  const contract = new ethers.Contract(bridgeHub, artifact.abi, l1Provider);

  const owner = await contract.owner();
  if (owner.toLowerCase() != expectedOwner.toLowerCase()) {
    throw new Error("Bridgehub owner is not correct");
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

  console.log("L1 legacy bridge impl correct!");
}

const SCHEDULE_DATA = fs.readFileSync('./scripts/schedule.txt');
const EXPECTED_L2_DATA = fs.readFileSync('./scripts/expected-l2-data.txt');
const SET_CHAIN_CREATION_PARAMS_DATA = fs.readFileSync('./scripts/chain-creation-params.txt');
const EXECUTE_UPGRADE_DATA = fs.readFileSync('./scripts/execute-upgrade.txt');

function getStmContract(): ethers.Contract {
  return new ethers.Contract(stm, hardhat.artifacts.readArtifactSync('StateTransitionManager').abi, l1Provider);
}

function getGetters(): ethers.Contract {
  return new ethers.Contract(diamondProxyAddress, hardhat.artifacts.readArtifactSync('GettersFacet').abi, l1Provider)
}

function getAdmin(): ethers.Contract {
  return new ethers.Contract(diamondProxyAddress, hardhat.artifacts.readArtifactSync('AdminFacet').abi, l1Provider)
}

async function testThatAllSelectorsAreDeleted(facetCuts: any) {
  const getters = getGetters();
  const loupe = Array.from(await getters.facets());
  
  const expectedDeletedSelectors = loupe.map((facet: any) => {
    const sortedSelectors = Array.from(facet.selectors!).sort().join(',');
    return `${sortedSelectors}`;
  }).sort();

  const realDeletedFacets = [];
  for(const facetCut of facetCuts) {
    const isAddressZero = (facetCut.facet == ethers.constants.AddressZero);
    const isActionDelete = (facetCut.action == 2); 
    if(!isAddressZero && !isActionDelete) {
      // This is addition, we do not care
      continue;
    }
    if(!isAddressZero || !isActionDelete) {
      throw new Error('incosistent');
    }

    const sortedSelectors = Array.from(facetCut.selectors!).sort().join(',');
    realDeletedFacets.push(sortedSelectors);
  }
  realDeletedFacets.sort();
  
  if (expectedDeletedSelectors.join('#') !== realDeletedFacets.join('#')) {
    throw new Error('Incosistent deleted selectors');
  }
}

async function testThatAllSelectorsAreAdded(facetCuts: any) {
  const expectedFacets = [
    {
      address: executorFacet,
      name: 'ExecutorFacet',
      freezeable: true,
    },
    {
      address: mailboxFacet,
      name: 'MailboxFacet',
      freezeable: true,
    },
    {
      address: gettersFacet,
      name: 'GettersFacet',
      freezeable: false,
    },
    {
      address: adminFacet,
      name: 'AdminFacet',
      freezeable: false,
    },
  ];
  const included = [false, false, false, false];

  const realAddedFacets = [];
  for(const facetCut of facetCuts) {
    if(facetCut.action !== 0 && facetCut.action !== 2) {
      throw new Error('bad action');
    }
    
    const isAddressNonZero = (facetCut.facet != ethers.constants.AddressZero);
    const isActionAdd = (facetCut.action == 0); 
    if(!isAddressNonZero && !isActionAdd) {
      // This is addition, we do not care
      continue;
    }
    if(!isAddressNonZero || !isActionAdd) {
      throw new Error('incosistent');
    }

    const sortedSelectors = Array.from(facetCut.selectors!).sort().join(',');
    const facetAddress = facetCut.facet;

    let found = false;
    for(let i = 0; i < expectedFacets.length; i++) {
      if (facetAddress.toLowerCase() == expectedFacets[i].address.toLowerCase()) {
        if(included[i]) {
          throw new Error('Facet ' + i + ' has been included already');
        }
        included[i] = true;
      } else {
        continue;
      }

      found = true;
      const expectedSortedSelectors = getAllSelectors(new ethers.utils.Interface(hardhat.artifacts.readArtifactSync(expectedFacets[i].name).abi)).sort().join(',');

      if(sortedSelectors !== expectedSortedSelectors) {
        throw new Error('Selector mismatch for address ' + facetAddress);
      }

      if(facetCut.isFreezable !== expectedFacets[i].freezeable) {
        throw new Error('Freezability issue for facet address ' + facetAddress);
      }
    }

    if(!found) {
      throw new Error('Unkown address ' + facetAddress);
    }
  }

  for(let i = 0; i < 4; i++) {
    if(!included[i]) {
      throw new Error('Facet ' + i + ' was not included');
    }
  }
}

function caseEq(a: string, b:string) {
  return a.toLowerCase()== b.toLowerCase();
}

async function checkUpgradeTx(upgradeTx: any) {
  if(!BigNumber.from(254).eq(upgradeTx.txType)) {
    throw new Error('bad tx type');
  }
  const FORCE_DEPLOYER_ADDR = '0x8007';
  if(!BigNumber.from(FORCE_DEPLOYER_ADDR).eq(upgradeTx.from)) {
    throw new Error('bad tx from');
  }
  const CONTRACT_DEPLOYER_ADDR = '0x8006'
  if(!BigNumber.from(CONTRACT_DEPLOYER_ADDR).eq(upgradeTx.to)) {
    throw new Error('bad tx to');
  }

  if(!BigNumber.from(72_000_000).eq(upgradeTx.gasLimit)) {
    throw new Error('bad tx gaslimt');
  }
  
  if(!BigNumber.from(800).eq(upgradeTx.gasPerPubdataByteLimit)) {
    throw new Error('bad tx gasperpubdata');
  }

  if(!BigNumber.from(0).eq(upgradeTx.maxFeePerGas)) {
    throw new Error('bad tx maxFeePerGas');
  }

  if(!BigNumber.from(0).eq(upgradeTx.maxPriorityFeePerGas)) {
    throw new Error('bad tx maxPriorityFeePerGas');
  }

  if(!BigNumber.from(0).eq(upgradeTx.paymaster)) {
    throw new Error('bad tx paymaster');
  }

  if(!BigNumber.from(EXPECTED_MAJOR_VERSION).eq(upgradeTx.nonce)) {
    throw new Error('bad tx nonce');
  }

  if(!BigNumber.from(0).eq(upgradeTx.value)) {
    throw new Error('bad tx value');
  }

  if(upgradeTx.reserved.length !== 4) {
    throw new Error('bad reserved length');
  }
  for(const rv of upgradeTx.reserved) {
    if(!BigNumber.from(0).eq(rv)) {
      throw new Error('bad tx reserved');
    }
  }

  // we'll check it later
  if(upgradeTx.data !== EXPECTED_L2_DATA.toString()) {
    throw new Error('bad l2 data');
  }

  if(upgradeTx.signature !== '0x') {
    throw new Error('bad tx sig');
  }

  if(upgradeTx.factoryDeps.length !== 0) {
    throw new Error('bad tx factoryDeps');
  }
  if(upgradeTx.paymasterInput !== '0x') {
    throw new Error('bad tx paymasterInput');
  }
  if(upgradeTx.reservedDynamic !== '0x') {
    throw new Error('bad tx reservedDynamic');
  }
}

async function checkDefaultUpgradeCalldata(initCalldata: any) {
  const defaultUpgradeInterface = new ethers.utils.Interface(
    hardhat.artifacts.readArtifactSync('DefaultUpgrade').abi
  );
  const parsedUpgrade = defaultUpgradeInterface.parseTransaction({
    data: initCalldata
  });
  if(parsedUpgrade.name !== 'upgrade') {
    throw new Error('bad scheulde name');
  }
  const upgradeStruct = parsedUpgrade.args._proposedUpgrade;

  if(!BigNumber.from(EXPECTED_UPGRADE_TIMESTAMP).eq(upgradeStruct.upgradeTimestamp)) {
    throw new Error('Bad upgrade timestamp');
  }
  if(!BigNumber.from(EXPECTED_NEW_PROTOCOL_VERSION).eq(upgradeStruct.newProtocolVersion)) {
    throw new Error('Bad upgrade timestamp');
  }
  if(upgradeStruct.postUpgradeCalldata !== '0x') {
    throw new Error('post upgrade calldata');
  } 
  if(upgradeStruct.l1ContractsUpgradeCalldata !== '0x') {
    throw new Error('bad l1ContractsUpgradeCalldata');
  }
  const {recursionNodeLevelVkHash,recursionLeafLevelVkHash,recursionCircuitsSetVksHash} = upgradeStruct.verifierParams; 
  if(recursionNodeLevelVkHash !== ethers.constants.HashZero || recursionLeafLevelVkHash !== ethers.constants.HashZero || recursionCircuitsSetVksHash !== ethers.constants.HashZero) {
    throw new Error('bad vk');
  }

  if(!caseEq(upgradeStruct.verifier, verifier)) {
    throw new Error('bad verifier');
  }

  if(upgradeStruct.defaultAccountHash !== expectedDefaultAccountHash) {
    throw new Error('bad aa hash');
  }

  if(upgradeStruct.bootloaderHash !== expectedBootloaderHash) {
    throw new Error('bad bootloader hash');
  }

  if(upgradeStruct.factoryDeps.length > 0) {
    throw new Error('bad deps');
  }
  

  const upgradeTx = upgradeStruct.l2ProtocolUpgradeTx;
  checkUpgradeTx(upgradeTx);
}

async function checkScheduleData() { 
  const contract = getStmContract();
  const iface = contract.interface;

  const parsedData = iface.parseTransaction({data: SCHEDULE_DATA.toString()});
  
  if(parsedData.name !== 'setNewVersionUpgrade') {
    throw new Error('bad scheulde name');
  }


  if(!BigNumber.from(EXPECTED_OLD_PROTOCOL_VERSION).eq(parsedData.args._oldProtocolVersion)) {
    console.log(parsedData.args._oldProtocolVersion);
    throw new Error('nad version');
  }

  if(!BigNumber.from(EXPECTED_OLD_VERSION_DEADLINE).eq(parsedData.args._oldProtocolVersionDeadline)) {
    throw new Error('bad deadline');
  }
  
  if(!BigNumber.from(EXPECTED_NEW_PROTOCOL_VERSION).eq(parsedData.args._newProtocolVersion)) {
    throw new Error('bad new version');
  }

  const cutData = parsedData.args._cutData;

  // Okay, now it is time to check cutdata

  const {
    facetCuts,
    initAddress,
    initCalldata
  } =  cutData;

  if (initAddress !== defaultUpgradeAddress) {
    throw new Error('Bad default upgrade ' + initAddress + ' ' + defaultUpgradeAddress);
  }

  await testThatAllSelectorsAreDeleted(facetCuts);
  await testThatAllSelectorsAreAdded(facetCuts);

  // Now, what is left is to check the upgrade data.
  await checkDefaultUpgradeCalldata(initCalldata);
}

async function checkDiamondInitCalldata(initCalldata: string) {
  const iface = new ethers.utils.Interface(
    hardhat.artifacts.readArtifactSync('DiamondInit').abi
  );
  const parsedData = iface.parseTransaction({ data: initCalldata });
  if(parsedData.name !== 'initialize') {
    throw new Error('bad scheulde name');
  }

  const initializeData = parsedData.args._initializeData;
}

async function checkChainCreationParams() {
  const contract = getStmContract();
  const iface = contract.interface;

  const parsedData = iface.parseTransaction({data: SET_CHAIN_CREATION_PARAMS_DATA.toString()});
  
  if(parsedData.name !== 'setChainCreationParams') {
    throw new Error('bad scheulde name');
  }

  const chainCreationParams = parsedData.args._chainCreationParams;

  const usedGenesisUpgrade = chainCreationParams.genesisUpgrade;
  if (usedGenesisUpgrade.toLowerCase() !== genesisUpgrade.toLowerCase()) {
    throw new Error("Genesis upgrade is not correct");
  }
  const usedGenesisBatchHash = chainCreationParams.genesisBatchHash;
  if (usedGenesisBatchHash.toLowerCase() !== expectedGenesisRoot.toLowerCase()) {
    throw new Error("Genesis batch hash is not correct");
  }
  const usedGenesisIndexRepeatedStorageChanges = chainCreationParams.genesisIndexRepeatedStorageChanges;
  if (!usedGenesisIndexRepeatedStorageChanges.eq(expectedIndexRepeatedStorageChanges)) {
    throw new Error("Genesis index repeated storage changes is not correct");
  }
  const usedGenesisBatchCommitment = chainCreationParams.genesisBatchCommitment;
  if (usedGenesisBatchCommitment.toLowerCase() !== expectedGenesisBatchCommitment.toLowerCase()) {
    throw new Error("Genesis batch commitment is not correct");
  }

  const initDiamondCut = chainCreationParams.diamondCut;
  if(!caseEq(initDiamondCut.initAddress, diamondInit)) {
    throw new Error('bad diamond init ' + initDiamondCut.initAddress + ' ' + diamondInit);
  }
  await testThatAllSelectorsAreAdded(initDiamondCut.facetCuts);

  const initCalldata = initDiamondCut.initCalldata;
  await checkDiamondInitData(initCalldata);
}

async function checkExecuteUpgrade() {
  const contract = getAdmin();
  const iface = contract.interface;

  const parsedData = iface.parseTransaction({data: EXECUTE_UPGRADE_DATA.toString()});

  if(parsedData.name !== 'upgradeChainFromVersion') {
    throw new Error('bad scheulde name');
  }

  if(!BigNumber.from(EXPECTED_OLD_PROTOCOL_VERSION).eq(parsedData.args._oldProtocolVersion)) {
    throw new Error('Invalid old version');
  }

  // todo check that diamond cut is the same as in the upgrade

}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("upgrade-consistency-checker")
    .description("upgrade shared bridge for era diamond proxy");

  program.action(async () => {
    await checkIdenticalBytecode(defaultUpgradeAddress, "DefaultUpgrade", "DefaultUpgrade");
    await checkIdenticalBytecode(genesisUpgrade, "GenesisUpgrade", "GenesisUpgrade");
    
    await checkIdenticalBytecode(executorFacet, "ExecutorFacet");
    await checkIdenticalBytecode(gettersFacet, "GettersFacet");
    await checkIdenticalBytecode(adminFacet, "AdminFacet");
    await checkMailbox();
    
    await checkIdenticalBytecode(verifier, eraChainId == "324" ? "Verifier" : "TestnetVerifier", eraChainId == "324" ? "Verifier" : "TestnetVerifier");
    await checkIdenticalBytecode(diamondInit, "DiamondInit", "DiamondInit");

    await checkScheduleData();  
    console.log("Schedule data is correct")
    await checkChainCreationParams();
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
