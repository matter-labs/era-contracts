// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish } from "ethers";
import { BigNumber, ethers } from "ethers";

import type { DiamondCut } from "./diamondCut";
import { getFacetCutsForUpgrade } from "./diamondCut";

import { getTokens } from "./deploy-token";
import { EraLegacyChainId } from "./deploy";
import type { Deployer } from "./deploy";

import { Interface } from "ethers/lib/utils";
import type { L2CanonicalTransaction, ProposedUpgrade, VerifierParams } from "./utils";

import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-web3/build/src/utils";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";

const SYSTEM_UPGRADE_TX_TYPE = 254;
const FORCE_DEPLOYER_ADDRESS = "0x0000000000000000000000000000000000008007";
// const CONTRACT_DEPLOYER_ADDRESS = "0x0000000000000000000000000000000000008006";
// const COMPLEX_UPGRADE_ADDRESS = "0x000000000000000000000000000000000000800f";

export async function upgradeToHyperchains(
  deployer: Deployer,
  gasPrice: BigNumberish,
  create2Salt?: string,
  nonce?: number
) {
  // does not interfere with existing system
  if (deployer.verbose) {
    console.log("Deploying new contracts");
  }
  await deployNewContracts(deployer, gasPrice, create2Salt, nonce);

  // upgrading system contracts on Era only adds setChainId in systemContext, does not interfere with anything
  // we first upgrade the DiamondProxy. the Mailbox is backwards compatible, so the L1ERC20 and other bridges should still work.
  // but this requires the sharedBridge to be deployed.
  // kl to: (is this needed?) disable shared bridge deposits until L2Bridge is upgraded.
  if (deployer.verbose) {
    console.log("Integrating Era into Bridgehub and upgrading L2 system contract");
  }
  await integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer, gasPrice);

  // the L2Bridge and L1ERC20Bridge should be updated relatively in sync, as new messages might not be parsed correctly by the old bridge.
  // however new bridges can parse old messages. L1->L2 messages are faster, so L2 side is upgraded first.
  // until we integrate Era into the Bridgehub, txs will not work.
  if (deployer.verbose) {
    console.log("Upgrading L2 bridge");
  }
  await upgradeL2Bridge(deployer);
  // kl todo add both bridge address to L2Bridge, so that it can receive txs from both bridges
  // kl todo: enable L1SharedBridge deposits if disabled.
  if (deployer.verbose) {
    console.log("Upgrading L1 ERC20 bridge");
  }
  await upgradeL1ERC20Bridge(deployer);
  // // note, withdrawals will not work until this step, but deposits will
  if (deployer.verbose) {
    console.log("Migrating assets from L1 ERC20 bridge and ChainBalance");
  }
  await migrateAssets(deployer);
}

async function deployNewContracts(deployer: Deployer, gasPrice: BigNumberish, create2Salt?: string, nonce?: number) {
  nonce = nonce || (await deployer.deployWallet.getTransactionCount());
  create2Salt = create2Salt || ethers.utils.hexlify(ethers.utils.randomBytes(32));

  // Create2 factory already deployed

  await deployer.deployGenesisUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  await deployer.deployValidatorTimelock(create2Salt, { gasPrice, nonce });
  nonce++;

  // kl todo check if this needs to be redeployed
  await deployer.deployDefaultUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  // kl todo: we will need to deploy the proxyAdmin on mainnet, here it is already deployed
  // await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  await deployer.deployBridgehubContract(create2Salt, gasPrice);

  await deployer.deployStateTransitionManagerContract(create2Salt, [], gasPrice);
  await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

  await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
  await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
}

async function integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer: Deployer, gasPrice: BigNumberish) {
  // era facet cut
  const defaultUpgrade = new Interface(hardhat.artifacts.readArtifactSync("DefaultUpgrade").abi);
  const newProtocolVersion = 24;
  const toAddress: string = ethers.constants.AddressZero;
  const calldata: string = ethers.constants.HashZero;
  const l2ProtocolUpgradeTx: L2CanonicalTransaction = {
    txType: SYSTEM_UPGRADE_TX_TYPE,
    from: FORCE_DEPLOYER_ADDRESS,
    to: toAddress,
    gasLimit: 72_000_000,
    gasPerPubdataByteLimit: REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
    maxFeePerGas: 0,
    maxPriorityFeePerGas: 0,
    paymaster: 0,
    nonce: newProtocolVersion,
    value: 0,
    reserved: [0, 0, 0, 0],
    data: calldata,
    signature: "0x",
    factoryDeps: [],
    paymasterInput: "0x",
    reservedDynamic: "0x",
  };
  const upgradeTimestamp = BigNumber.from(100);
  const verifierParams: VerifierParams = {
    recursionNodeLevelVkHash: ethers.constants.HashZero,
    recursionLeafLevelVkHash: ethers.constants.HashZero,
    recursionCircuitsSetVksHash: ethers.constants.HashZero,
  };
  const proposedUpgrade: ProposedUpgrade = {
    l2ProtocolUpgradeTx,
    factoryDeps: [],
    bootloaderHash: ethers.constants.HashZero,
    defaultAccountHash: ethers.constants.HashZero,
    verifier: ethers.constants.AddressZero,
    verifierParams: verifierParams,
    l1ContractsUpgradeCalldata: ethers.constants.HashZero,
    postUpgradeCalldata: ethers.constants.HashZero,
    upgradeTimestamp: upgradeTimestamp,
    newProtocolVersion: 24,
  };
  const defaultUpgradeData = defaultUpgrade.encodeFunctionData("upgrade", [proposedUpgrade]);

  const facetCuts = await getFacetCutsForUpgrade(
    deployer.deployWallet,
    deployer.addresses.StateTransition.DiamondProxy,
    deployer.addresses.StateTransition.AdminFacet,
    deployer.addresses.StateTransition.GettersFacet,
    deployer.addresses.StateTransition.MailboxFacet,
    deployer.addresses.StateTransition.ExecutorFacet
  ); //.concat(extraFacets ?? []);
  const diamondCut: DiamondCut = {
    facetCuts,
    initAddress: deployer.addresses.StateTransition.DefaultUpgrade,
    initCalldata: defaultUpgradeData,
  };
  //   console.log('kl todo', facetCuts)
  const adminFacet = new Interface(hardhat.artifacts.readArtifactSync("DummyAdminFacet").abi);
  // to test this remove modifier from executeUpgrade
  const data = adminFacet.encodeFunctionData("executeUpgrade2", [diamondCut]); // kl todo calldata might not be "0x"
  await deployer.executeUpgrade(deployer.addresses.StateTransition.DiamondProxy, 0, data);

  // register Era in Bridgehub, STM
  const stateTrasitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);

  const tx0 = await stateTrasitionManager.registerAlreadyDeployedStateTransition(
    EraLegacyChainId,
    deployer.addresses.StateTransition.DiamondProxy
  );
  await tx0.wait();
  const bridgehub = deployer.bridgehubContract(deployer.deployWallet);
  const tx = await bridgehub.createNewChain(
    EraLegacyChainId,
    deployer.addresses.StateTransition.StateTransitionProxy,
    ETH_ADDRESS_IN_CONTRACTS,
    ethers.constants.HashZero,
    deployer.addresses.Governance,
    ethers.constants.HashZero,
    { gasPrice }
  );

  await tx.wait();
}

async function upgradeL2Bridge(deployer: Deployer) {
  // upgrade L2 bridge contract, we do this directly via the L2
  // set initializeChainGovernance in L1SharedBridge
  deployer;
}

async function upgradeL1ERC20Bridge(deployer: Deployer) {
  // upgrade old contracts
  await deployer.upgradeL1ERC20Bridge(true);
}

async function migrateAssets(deployer: Deployer) {
  // migrate assets from L1 ERC20 bridge
  if (deployer.verbose) {
    console.log("transferring Eth");
  }
  const sharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  const ethTransferData = sharedBridge.interface.encodeFunctionData("transferFundsFromLegacy", [
    ETH_ADDRESS_IN_CONTRACTS,
    deployer.addresses.StateTransition.DiamondProxy,
    deployer.chainId,
  ]);
  ethTransferData;
  //   await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, ethTransferData);

  if (deployer.verbose) {
    console.log("transferring Dai");
  }

  const tokens = getTokens();
  const altTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
  const daiTransferData = sharedBridge.interface.encodeFunctionData("transferFundsFromLegacy", [
    altTokenAddress,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    deployer.chainId,
  ]);
  daiTransferData;
  //   await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, daiTransferData);
}
