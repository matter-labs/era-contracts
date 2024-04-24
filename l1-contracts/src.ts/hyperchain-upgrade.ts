// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish } from "ethers";
import { ethers } from "ethers";

import type { Deployer } from "./deploy";

import type { ITransparentUpgradeableProxy } from "../typechain/ITransparentUpgradeableProxy";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";

import { L1SharedBridgeFactory } from "../typechain";

import { Interface } from "ethers/lib/utils";
import { ADDRESS_ONE } from "./utils";

import {
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  applyL1ToL2Alias,
  hashL2Bytecode,
} from "../../l2-contracts/src/utils";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";

const BEACON_PROXY_BYTECODE = ethers.constants.HashZero;

/// In the hardhat tests we do the upgrade all at once.
/// On localhost/stage/.. we will call the components and send the calldata to Governance manually
export async function upgradeToHyperchains(
  deployer: Deployer,
  gasPrice: BigNumberish,
  printFileName?: string,
  create2Salt?: string,
  nonce?: number
) {
  await upgradeToHyperchains1(deployer, gasPrice, create2Salt, nonce);
  await upgradeToHyperchains2(deployer, gasPrice, printFileName);
  await upgradeToHyperchains3(deployer, printFileName);
}

/// this just deploys the contract ( we do it here instead of using the protocol-upgrade tool, since we are deploying more than just facets, the Bridgehub, STM, etc.)
export async function upgradeToHyperchains1(
  deployer: Deployer,
  gasPrice: BigNumberish,
  create2Salt?: string,
  nonce?: number
) {
  /// we manually override the governance address so that we can set the variables
  deployer.addresses.Governance = deployer.deployWallet.address;
  // does not interfere with existing system
  // note other contract were already deployed
  if (deployer.verbose) {
    console.log("Deploying new contracts");
  }
  await deployNewContracts(deployer, gasPrice, create2Salt, nonce);

  // register Era in Bridgehub, STM
  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);

  if (deployer.verbose) {
    console.log("Registering Era in stateTransitionManager");
  }
  const txRegister = await stateTransitionManager.registerAlreadyDeployedHyperchain(
    deployer.chainId,
    deployer.addresses.StateTransition.DiamondProxy
  );

  await txRegister.wait();

  const bridgehub = deployer.bridgehubContract(deployer.deployWallet);
  if (deployer.verbose) {
    console.log("Registering Era in Bridgehub");
  }

  const tx = await bridgehub.createNewChain(
    deployer.chainId,
    deployer.addresses.StateTransition.StateTransitionProxy,
    ETH_ADDRESS_IN_CONTRACTS,
    ethers.constants.HashZero,
    deployer.addresses.Governance,
    ethers.constants.HashZero,
    { gasPrice }
  );
  await tx.wait();

  if (deployer.verbose) {
    console.log("Setting L1Erc20Bridge data in shared bridge");
  }
  const sharedBridge = L1SharedBridgeFactory.connect(
    deployer.addresses.Bridges.SharedBridgeProxy,
    deployer.deployWallet
  );
  const tx1 = await sharedBridge.setL1Erc20Bridge(deployer.addresses.Bridges.ERC20BridgeProxy);
  await tx1.wait();

  if (deployer.verbose) {
    console.log("Initializing l2 bridge in shared bridge", deployer.addresses.Bridges.L2SharedBridgeProxy);
  }
  const tx2 = await sharedBridge.initializeChainGovernance(
    deployer.chainId,
    deployer.addresses.Bridges.L2SharedBridgeProxy
  );
  await tx2.wait();
}

// this should be called after the diamond cut has been proposed and executed
// this simulates the main part of the upgrade, registration into the Bridgehub and STM, and the bridge upgrade
export async function upgradeToHyperchains2(deployer: Deployer, gasPrice: BigNumberish, printFileName?: string) {
  // upgrading system contracts on Era only adds setChainId in systemContext, does not interfere with anything
  // we first upgrade the DiamondProxy. the Mailbox is backwards compatible, so the L1ERC20 and other bridges should still work.
  // this requires the sharedBridge to be deployed.
  // In theory, the L1SharedBridge deposits should be disabled until the L2Bridge is upgraded.
  // However, without the Portal, UI being upgraded it does not matter (nobody will call it, they will call the legacy bridge)

  // the L2Bridge and L1ERC20Bridge should be updated relatively in sync, as new messages might not be parsed correctly by the old bridge.
  // however new bridges can parse old messages. L1->L2 messages are faster, so L2 side is upgraded first.
  if (deployer.verbose) {
    console.log("Upgrading L2 bridge");
  }
  await upgradeL2Bridge(deployer, printFileName);

  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    if (deployer.verbose) {
      console.log("Upgrading L1 ERC20 bridge");
    }
    await upgradeL1ERC20Bridge(deployer, printFileName);
  }

  // note, withdrawals will not work until this step, but deposits will
  // if (deployer.verbose) {
  //   console.log("Migrating assets from L1 ERC20 bridge and ChainBalance");
  // }
  // await migrateAssets(deployer, printFileName);
}

// This sets the Shared Bridge parameters. We need to do this separately, as these params will be known after the upgrade
export async function upgradeToHyperchains3(deployer: Deployer, printFileName?: string) {
  const sharedBridge = L1SharedBridgeFactory.connect(
    deployer.addresses.Bridges.SharedBridgeProxy,
    deployer.deployWallet
  );
  const data2 = sharedBridge.interface.encodeFunctionData("setEraPostDiamondUpgradeFirstBatch", [
    process.env.CONTRACTS_ERA_POST_DIAMOND_UPGRADE_FIRST_BATCH ?? 1,
  ]);
  const data3 = sharedBridge.interface.encodeFunctionData("setEraPostLegacyBridgeUpgradeFirstBatch", [
    process.env.CONTRACTS_ERA_POST_LEGACY_BRIDGE_UPGRADE_FIRST_BATCH ?? 1,
  ]);
  const data4 = sharedBridge.interface.encodeFunctionData("setEraLegacyBridgeLastDepositTime", [
    process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_BATCH ?? 1,
    process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_TX_NUMBER ?? 0,
  ]);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data2, printFileName);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data3, printFileName);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data4, printFileName);
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
  await deployer.deployVerifier(create2Salt, { gasPrice, nonce });

  if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
    await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  }
  await deployer.deployBridgehubContract(create2Salt, gasPrice);

  await deployer.deployStateTransitionManagerContract(create2Salt, [], gasPrice);
  await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

  await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
  await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
  // await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });
}

async function upgradeL2Bridge(deployer: Deployer, printFileName?: string) {
  const l2BridgeImplementationAddress = process.env.CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR!;

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
  const factoryDeps = [];
  const gasPrice = await deployer.deployWallet.getGasPrice();
  const requiredValueForL2Tx = await deployer
    .bridgehubContract(deployer.deployWallet)
    .l2TransactionBaseCost(deployer.chainId, gasPrice, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA); //"1000000000000000000";

  const mailboxFacet = new Interface(hardhat.artifacts.readArtifactSync("MailboxFacet").abi);
  const mailboxCalldata = mailboxFacet.encodeFunctionData("requestL2Transaction", [
    process.env.CONTRACTS_L2_ERC20_BRIDGE_ADDR,
    0,
    l2ProxyCalldata,
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    deployer.deployWallet.address,
  ]);

  await deployer.executeUpgrade(
    deployer.addresses.StateTransition.DiamondProxy,
    requiredValueForL2Tx,
    mailboxCalldata,
    printFileName
  );
}

async function upgradeL1ERC20Bridge(deployer: Deployer, printFileName?: string) {
  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    // we need to wait here for a new block
    await new Promise((resolve) => setTimeout(resolve, 5000));
    // upgrade ERC20.
    const proxyAdminAbi = ["function upgrade(address, address)"];
    const proxyAdmin = new ethers.Contract(
      deployer.addresses.TransparentProxyAdmin,
      proxyAdminAbi,
      deployer.deployWallet
    );
    const data1 = await proxyAdmin.interface.encodeFunctionData("upgrade", [
      deployer.addresses.Bridges.ERC20BridgeProxy,
      deployer.addresses.Bridges.ERC20BridgeImplementation,
    ]);

    await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, data1, printFileName);

    if (deployer.verbose) {
      console.log("L1ERC20Bridge upgrade sent");
    }
  }
}
