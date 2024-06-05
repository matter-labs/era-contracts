// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import * as path from "path";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish } from "ethers";
import { ethers } from "ethers";

import type { Deployer } from "./deploy";

import type { ITransparentUpgradeableProxy } from "../typechain/ITransparentUpgradeableProxy";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";
import { StateTransitionManagerFactory, L1SharedBridgeFactory, ValidatorTimelockFactory } from "../typechain";

import { Interface } from "ethers/lib/utils";
import { ADDRESS_ONE, getAddressFromEnv, readBytecode } from "./utils";

import {
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  applyL1ToL2Alias,
  hashL2Bytecode,
} from "../../l2-contracts/src/utils";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";

const contractArtifactsPath = path.join(process.env.ZKSYNC_HOME as string, "contracts/l2-contracts/artifacts-zk/");
const openzeppelinBeaconProxyArtifactsPath = path.join(contractArtifactsPath, "@openzeppelin/contracts/proxy/beacon");
export const BEACON_PROXY_BYTECODE = readBytecode(openzeppelinBeaconProxyArtifactsPath, "BeaconProxy");

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

  if (deployer.verbose) {
    console.log("Setting Validator timelock in STM");
  }
  const stm = StateTransitionManagerFactory.connect(
    deployer.addresses.StateTransition.StateTransitionProxy,
    deployer.deployWallet
  );
  const tx3 = await stm.setValidatorTimelock(deployer.addresses.ValidatorTimeLock);
  await tx3.wait();

  if (deployer.verbose) {
    console.log("Setting dummy STM in Validator timelock");
  }

  const ethTxOptions: ethers.providers.TransactionRequest = {};
  ethTxOptions.gasLimit ??= 10_000_000;
  const migrationSTMAddress = await deployer.deployViaCreate2(
    "MigrationSTM",
    [deployer.deployWallet.address],
    create2Salt,
    ethTxOptions
  );
  console.log("Migration STM address", migrationSTMAddress);

  const validatorTimelock = ValidatorTimelockFactory.connect(
    deployer.addresses.ValidatorTimeLock,
    deployer.deployWallet
  );
  const tx4 = await validatorTimelock.setStateTransitionManager(migrationSTMAddress);
  await tx4.wait();

  const validatorOneAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
  const validatorTwoAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR");
  const tx5 = await validatorTimelock.addValidator(deployer.chainId, validatorOneAddress, { gasPrice });
  const receipt5 = await tx5.wait();
  const tx6 = await validatorTimelock.addValidator(deployer.chainId, validatorTwoAddress, { gasPrice });
  const receipt6 = await tx6.wait();

  const tx7 = await validatorTimelock.setStateTransitionManager(
    deployer.addresses.StateTransition.StateTransitionProxy
  );
  const receipt7 = await tx7.wait();
  if (deployer.verbose) {
    console.log(
      "Validators added, stm transferred back",
      receipt5.transactionHash,
      receipt6.transactionHash,
      receipt7.transactionHash
    );
  }
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
  await upgradeL2Bridge(deployer, gasPrice, printFileName);

  if (deployer.verbose) {
    console.log("Transferring L1 ERC20 bridge to proxy admin");
  }
  await transferERC20BridgeToProxyAdmin(deployer, gasPrice, printFileName);

  if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
    if (deployer.verbose) {
      console.log("Upgrading L1 ERC20 bridge");
    }
    await upgradeL1ERC20Bridge(deployer, gasPrice, printFileName);
  }
}

// This sets the Shared Bridge parameters. We need to do this separately, as these params will be known after the upgrade
export async function upgradeToHyperchains3(deployer: Deployer, printFileName?: string) {
  const sharedBridge = L1SharedBridgeFactory.connect(
    deployer.addresses.Bridges.SharedBridgeProxy,
    deployer.deployWallet
  );
  const data2 = sharedBridge.interface.encodeFunctionData("setEraPostDiamondUpgradeFirstBatch", [
    process.env.CONTRACTS_ERA_POST_DIAMOND_UPGRADE_FIRST_BATCH,
  ]);
  const data3 = sharedBridge.interface.encodeFunctionData("setEraPostLegacyBridgeUpgradeFirstBatch", [
    process.env.CONTRACTS_ERA_POST_LEGACY_BRIDGE_UPGRADE_FIRST_BATCH,
  ]);
  const data4 = sharedBridge.interface.encodeFunctionData("setEraLegacyBridgeLastDepositTime", [
    process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_BATCH,
    process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_TX_NUMBER,
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

  await deployer.deployValidatorTimelock(create2Salt, { gasPrice });

  await deployer.deployHyperchainsUpgrade(create2Salt, {
    gasPrice,
  });
  await deployer.deployVerifier(create2Salt, { gasPrice });

  if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
    await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  }
  // console.log("Proxy admin is already deployed (not via Create2)", deployer.addresses.TransparentProxyAdmin);
  // console.log("CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR=0xf2c1d17441074FFb18E9A918db81A17dB1752146");
  await deployer.deployBridgehubContract(create2Salt, gasPrice);

  await deployer.deployStateTransitionManagerContract(create2Salt, [], gasPrice);
  await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

  await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
  await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
}

async function upgradeL2Bridge(deployer: Deployer, gasPrice: BigNumberish, printFileName?: string) {
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
  // console.log("kl todo", l2BridgeImplementationAddress, l2BridgeCalldata)
  const factoryDeps = [];
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

async function upgradeL1ERC20Bridge(deployer: Deployer, gasPrice: BigNumberish, printFileName?: string) {
  if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
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

export async function transferERC20BridgeToProxyAdmin(
  deployer: Deployer,
  gasPrice: BigNumberish,
  printFileName?: string
) {
  const bridgeProxy: ITransparentUpgradeableProxy = ITransparentUpgradeableProxyFactory.connect(
    deployer.addresses.Bridges.ERC20BridgeProxy,
    deployer.deployWallet
  );
  const data1 = await bridgeProxy.interface.encodeFunctionData("changeAdmin", [
    deployer.addresses.TransparentProxyAdmin,
  ]);

  await deployer.executeUpgrade(deployer.addresses.Bridges.ERC20BridgeProxy, 0, data1, printFileName);

  if (deployer.verbose) {
    console.log("ERC20Bridge ownership transfer sent");
  }
}

export async function transferTokens(deployer: Deployer, token: string) {
  const sharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  const tx = await sharedBridge.safeTransferFundsFromLegacy(
    token,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    "324",
    "300000",
    { gasLimit: 25_000_000 }
  );
  await tx.wait();
  console.log("Receipt", tx.hash);
}
