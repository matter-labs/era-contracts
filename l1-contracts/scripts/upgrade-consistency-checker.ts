/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url } from "./utils";
import { ethers } from "ethers";
import { Provider, utils } from "zksync-ethers";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const genesisUpgrade = '0xF8c553608927Bde789697D28784aa2EB4E8FC5c7';
const validatorTimelockDeployTx = '0xf68ca3fbae59c78806275435c2aaef879ccc041cbb61e0616a378db6332dc868';
const validatorTimelock = '0x93eea8d6f6580a4AEAD296EE2d975f4732763495';
const upgradeHyperchains = '0x5b87652B3E4f4c9475933EB9E54E06a0b0BCC69f';
const proxyAdmin = '0xE5d2199a0B23F98004bcf6aDAB885De6e4F3C187';

const bridgeHubImpl = '0xDF217D2a1a2AfF81b726D5b4CCDB3d368bF58dD2';
const bridgeHub = '0x5E4b0dd107a6a9DB8c4a40135D88Bbfd6aD71907';

const executorFacet = '0x9ef4C650010CE13F53b8ec4592A8238D3ABF1574';
const mailboxFacetDeployTx = '0x7f3c98ee50a03c9672af770d80947ab6ebbcb398a0d4795ecc16224b11429d86';
const mailboxFacet = '0xfB1D39FD6535aB499B8857993445Cd27e9904797';
const gettersFacet = '0x1cFc9B11e82FBfe7C3cb3CD04061bD5b133B22A6';
const adminFacet = '0xf03F9A728355102297E5E1b68d488215Ff1572e1';

const verifier = '0xa6BdDC3Ec5ED82C24e1d3246D388F518CF9938cB';

const stmImplDeployTx = '0xf3bcb674d41bed3c73fc299f41e7f0d78f93ac2ab473e0d197dad63c14957004';
const stmImpl = '0x0126A5dF4939bA05f7887B643DEFe8C6657a4eD5';
const stm = '0x21e9230F3bfE4c3BbEaC8EbaaE7caFA2E92D74f9';

const legacyBridgeImplDeployTx = '0x603b973fdc6997082861e1d7e092e03c38dba9468d04f5af59ffe29c631ac456';
const legacyBridgeImpl = '0x1A5D16e838d7C508d738B562355F198d4B6F59Fa';

const sharedBridgeImplDeployTx = '0x45e76c1574a8989de898cf16b3506f71be0c87baeb40d175ce46c5564032b839';
const sharedBridgeImpl = '0x54C7a61A9E578301E4eB85fFBf5d6678cB364252';
const sharedBridgeProxy = '0x5f1BD8EaD8246f488D54E9B267b2B9E872EFA45D';

const expectedL1WethAddress = '0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9';
const expectedOwner = '0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7';
const expectedDelay = 0;
const eraChainId = 270;
const expectedSalt = '0x0000000000000000000000000000000000000000000000000000000000000001';
const expectedHyperchainAddr = '0x6d6e010A2680E2E5a3b097ce411528b36d880EF6';
const maxNumberOfHyperchains = 100;
const expectedStoredBatchHashZero = '0x53dc316f108d1b64412be840e0ab89193e94ba6c4af8b9ca57d39ad4d782e0f4';
const expectedL2BridgeAddress = '0xCEB8d4888d2025aEaAD0272175281e0CaFC33152';
const expectedL1LegacyBridge = '0x7303B5Ce64f1ADB0558572611a0b90620b6dd5F4';

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
    [expectedOwner, expectedDelay, eraChainId]
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

  // TODO: add check for initCutHash
  console.log('STM is correct!');
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


async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-consistency-checker").description("upgrade shared bridge for era diamond proxy");

  program
    .action(async (cmd) => {
      await checkIdenticalBytecode(genesisUpgrade, 'GenesisUpgrade');
      await checkIdenticalBytecode(upgradeHyperchains, 'UpgradeHyperchains');
      await checkIdenticalBytecode(proxyAdmin, 'ProxyAdmin');
      await checkIdenticalBytecode(executorFacet, "ExecutorFacet");
      await checkIdenticalBytecode(gettersFacet, "GettersFacet");
      await checkIdenticalBytecode(adminFacet, "AdminFacet");
      await checkIdenticalBytecode(bridgeHubImpl, "Bridgehub");
      await checkIdenticalBytecode(verifier, "TestnetVerifier");

      await checkMailbox();

      await checkValidatorTimelock();
      await checkBridgehub();

      await checkSTMImpl();
      await checkSTM();

      await checkL1SharedBridgeImpl();
      await checkSharedBridge();

      await checkLegacyBridge();
    });


  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
