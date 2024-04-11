// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
// import * as path from "path";

import type { BigNumberish } from "ethers";
import { BigNumber, ethers } from "ethers";

import type { DiamondCut } from "./diamondCut";
import { getFacetCutsForUpgrade } from "./diamondCut";

import { getTokens } from "./deploy-token";
import type { Deployer } from "./deploy";

import type { ITransparentUpgradeableProxy } from "../typechain/ITransparentUpgradeableProxy";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";

import { Interface } from "ethers/lib/utils";
import { ADDRESS_ONE } from "./utils";
import type { L2CanonicalTransaction, ProposedUpgrade, VerifierParams } from "./utils";

import {
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  applyL1ToL2Alias,
  hashL2Bytecode,
} from "../../l2-contracts/src/utils";

const SYSTEM_UPGRADE_TX_TYPE = 254;
const FORCE_DEPLOYER_ADDRESS = "0x0000000000000000000000000000000000008007";

const BEACON_PROXY_BYTECODE = ethers.constants.HashZero;

/// this deploys the contracts
export async function upgradeToHyperchains1(
  deployer: Deployer,
  gasPrice: BigNumberish,
  create2Salt?: string,
  nonce?: number
) {
  // does not interfere with existing system
  // note other contract were already deployed
  if (deployer.verbose) {
    console.log("Deploying new contracts");
  }
  // const deployFacets = process.env.CHAIN_ETH_NETWORK === "hardhat";
  await deployNewContracts(deployer, gasPrice, create2Salt, nonce); //done
}

// this simulates the main part of the upgrade, the diamond cut, registration into the Bridgehub and STM, and the bridge upgrade
// this has to be done atomically.
// before we call this we need to generate the facet cuts using the protocol upgrade tool, on hardhat we test the dummy diamondCut
export async function upgradeToHyperchains2(deployer: Deployer, gasPrice: BigNumberish) {
  // upgrading system contracts on Era only adds setChainId in systemContext, does not interfere with anything
  // we first upgrade the DiamondProxy. the Mailbox is backwards compatible, so the L1ERC20 and other bridges should still work.
  // this requires the sharedBridge to be deployed.
  // In theory, the L1SharedBridge deposits should be disabled until the L2Bridge is upgraded.
  // However, without the Portal, UI being upgraded it does not matter (nobody will call it)
  if (deployer.verbose) {
    console.log("Integrating Era into Bridgehub and upgrading L2 system contract");
  }
  await integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer, gasPrice); // details for L2 system contract upgrade not finished

  // the L2Bridge and L1ERC20Bridge should be updated relatively in sync, as new messages might not be parsed correctly by the old bridge.
  // however new bridges can parse old messages. L1->L2 messages are faster, so L2 side is upgraded first.
  if (deployer.verbose) {
    console.log("Upgrading L2 bridge");
  }
  await upgradeL2Bridge(deployer); // mostly finished

  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    if (deployer.verbose) {
      console.log("Upgrading L1 ERC20 bridge");
    }
    await upgradeL1ERC20Bridge(deployer); // done
  }

  // note, withdrawals will not work until this step, but deposits will
  if (deployer.verbose) {
    console.log("Migrating assets from L1 ERC20 bridge and ChainBalance");
  }
  await migrateAssets(deployer); // done
}

export async function upgradeToHyperchains(
  deployer: Deployer,
  gasPrice: BigNumberish,
  create2Salt?: string,
  nonce?: number
) {
  await upgradeToHyperchains1(deployer, gasPrice, create2Salt, nonce);
  await upgradeToHyperchains2(deployer, gasPrice);
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

  await deployer.deployHyperchainsUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  // kl todo: we will need to deploy the proxyAdmin on mainnet, here it is already deployed
  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  }
  await deployer.deployBridgehubContract(create2Salt, gasPrice);

  await deployer.deployStateTransitionManagerContract(create2Salt, [], gasPrice);
  await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

  await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
  await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
  await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });
  await deployer.updateSharedBridge();
}

async function integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer: Deployer, gasPrice: BigNumberish) {
  // publish L2 system contracts
  if (process.env.CHAIN_ETH_NETWORK === "hardhat") {
    // era facet cut
    const newProtocolVersion = 24;
    const toAddress: string = ethers.constants.AddressZero;
    const calldata: string = ethers.constants.HashZero;
    const l2ProtocolUpgradeTx: L2CanonicalTransaction = {
      txType: SYSTEM_UPGRADE_TX_TYPE,
      from: FORCE_DEPLOYER_ADDRESS,
      to: toAddress,
      gasLimit: 72_000_000,
      gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
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
    const postUpgradeCalldata = new ethers.utils.AbiCoder().encode(
      ["uint256", "address", "address", "address"],
      [
        deployer.chainId,
        deployer.addresses.Bridgehub.BridgehubProxy,
        deployer.addresses.StateTransition.StateTransitionProxy,
        deployer.addresses.Bridges.SharedBridgeProxy,
      ]
    );
    const proposedUpgrade: ProposedUpgrade = {
      l2ProtocolUpgradeTx,
      factoryDeps: [],
      bootloaderHash: ethers.constants.HashZero,
      defaultAccountHash: ethers.constants.HashZero,
      verifier: ethers.constants.AddressZero,
      verifierParams: verifierParams,
      l1ContractsUpgradeCalldata: ethers.constants.HashZero,
      postUpgradeCalldata: postUpgradeCalldata,
      upgradeTimestamp: upgradeTimestamp,
      newProtocolVersion: 24,
    };
    const upgradeHyperchains = new Interface(hardhat.artifacts.readArtifactSync("UpgradeHyperchains").abi);
    const defaultUpgradeData = upgradeHyperchains.encodeFunctionData("upgrade", [proposedUpgrade]);

    const facetCuts = await getFacetCutsForUpgrade(
      deployer.deployWallet,
      deployer.addresses.StateTransition.DiamondProxy,
      deployer.addresses.StateTransition.AdminFacet,
      deployer.addresses.StateTransition.GettersFacet,
      deployer.addresses.StateTransition.MailboxFacet,
      deployer.addresses.StateTransition.ExecutorFacet
    );
    const diamondCut: DiamondCut = {
      facetCuts,
      initAddress: deployer.addresses.StateTransition.DefaultUpgrade,
      initCalldata: defaultUpgradeData,
    };
    const adminFacet = new Interface(hardhat.artifacts.readArtifactSync("DummyAdminFacet2").abi);

    const data = adminFacet.encodeFunctionData("executeUpgrade2", [diamondCut]); // kl todo calldata might not be "0x"
    await deployer.executeUpgrade(deployer.addresses.StateTransition.DiamondProxy, 0, data);
  }
  // register Era in Bridgehub, STM
  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);

  if (deployer.verbose) {
    console.log("registering Era in stateTransitionManager");
  }
  const registerData = stateTransitionManager.interface.encodeFunctionData("registerAlreadyDeployedHyperchain", [
    deployer.chainId,
    deployer.addresses.StateTransition.DiamondProxy,
  ]);
  await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, registerData);
  const bridgehub = deployer.bridgehubContract(deployer.deployWallet);
  if (deployer.verbose) {
    console.log("registering Era in Bridgehub");
  }
  const tx = await bridgehub.createNewChain(
    deployer.chainId,
    deployer.addresses.StateTransition.StateTransitionProxy,
    ADDRESS_ONE,
    ethers.constants.HashZero,
    deployer.addresses.Governance,
    ethers.constants.HashZero,
    { gasPrice }
  );

  await tx.wait();
}

async function upgradeL2Bridge(deployer: Deployer) {
  // todo deploy l2 bridge here
  // L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE
  const l2BridgeImplementationAddress = ADDRESS_ONE; // todo

  // upgrade from L1 governance. This has to come from governacne on L1.
  const l2BridgeAbi = ["function initialize(address, address, bytes32, address)"];
  const l2BridgeContract = new ethers.Contract(ADDRESS_ONE, l2BridgeAbi, deployer.deployWallet);
  const l2Bridge = l2BridgeContract.interface; //L2_SHARED_BRIDGE_INTERFACE;
  const l2BridgeCalldata = l2Bridge.encodeFunctionData("initialize", [
    deployer.addresses.Bridges.SharedBridgeProxy,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    hashL2Bytecode(BEACON_PROXY_BYTECODE),
    applyL1ToL2Alias(deployer.addresses.Governance),
  ]);
  const bridgeProxy: ITransparentUpgradeableProxy = ITransparentUpgradeableProxyFactory.connect(
    ADDRESS_ONE,
    deployer.deployWallet
  ); // we just need the interface, so wrong address

  const l2ProxyCalldata = bridgeProxy.interface.encodeFunctionData("upgradeToAndCall", [
    l2BridgeImplementationAddress,
    l2BridgeCalldata,
  ]);

  const mailboxFacet = new Interface(hardhat.artifacts.readArtifactSync("MailboxFacet").abi);
  const factoryDeps = [];
  const mailboxCalldata = mailboxFacet.encodeFunctionData("requestL2Transaction", [
    process.env.CONTRACTS_L2_SHARED_BRIDGE_ADDR,
    0,
    l2ProxyCalldata,
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    deployer.deployWallet.address,
  ]);
  const gasPrice = await deployer.deployWallet.getGasPrice();
  const requiredValueForL2Tx = await deployer
    .bridgehubContract(deployer.deployWallet)
    .l2TransactionBaseCost(deployer.chainId, gasPrice, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA); //"1000000000000000000";

  await deployer.executeUpgrade(
    deployer.addresses.StateTransition.DiamondProxy,
    requiredValueForL2Tx.mul(10),
    mailboxCalldata
  );
}

async function upgradeL1ERC20Bridge(deployer: Deployer) {
  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    // we need to wait here for a new block
    await new Promise((resolve) => setTimeout(resolve, 5000));
    const proxyAdminInterface = new Interface(hardhat.artifacts.readArtifactSync("ProxyAdmin").abi);
    const calldata = proxyAdminInterface.encodeFunctionData("upgrade(address,address)", [
      deployer.addresses.Bridges.ERC20BridgeProxy,
      deployer.addresses.Bridges.ERC20BridgeImplementation,
    ]);
    await deployer.executeUpgrade(this.addresses.TransparentProxyAdmin, 0, calldata);
    if (this.verbose) {
      console.log("L1ERC20Bridge upgrade sent");
    }
  }
}

async function migrateAssets(deployer: Deployer) {
  // migrate assets from L1 ERC20 bridge
  if (deployer.verbose) {
    console.log("transferring Eth");
  }
  const sharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  const ethTransferData = sharedBridge.interface.encodeFunctionData("transferFundsFromLegacy", [
    ADDRESS_ONE,
    deployer.addresses.StateTransition.DiamondProxy,
    deployer.chainId,
  ]);
  // ethTransferData;
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, ethTransferData);

  if (deployer.verbose) {
    console.log("transferring Dai");
  }

  const tokens = getTokens();
  const altTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;

  // Mint some tokens
  const l1Erc20ABI = ["function mint(address to, uint256 amount)"];
  const l1Erc20Contract = new ethers.Contract(altTokenAddress, l1Erc20ABI, deployer.deployWallet);
  const mintTx = await l1Erc20Contract.mint(
    deployer.addresses.Bridges.ERC20BridgeProxy,
    ethers.utils.parseEther("10000.0")
  );
  await mintTx.wait();

  const daiTransferData = sharedBridge.interface.encodeFunctionData("transferFundsFromLegacy", [
    altTokenAddress,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    deployer.chainId,
  ]);
  // daiTransferData;
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, daiTransferData);
}
