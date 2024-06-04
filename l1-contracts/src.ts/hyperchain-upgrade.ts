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

import { L1SharedBridgeFactory, StateTransitionManagerFactory } from "../typechain";

import { Interface } from "ethers/lib/utils";
import { ADDRESS_ONE, getAddressFromEnv } from "./utils";
import type { L2CanonicalTransaction, ProposedUpgrade, VerifierParams } from "./utils";

import {
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  applyL1ToL2Alias,
  hashL2Bytecode,
} from "../../l2-contracts/src/utils";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";

const SYSTEM_UPGRADE_TX_TYPE = 254;
const FORCE_DEPLOYER_ADDRESS = "0x0000000000000000000000000000000000008007";

const BEACON_PROXY_BYTECODE = ethers.constants.HashZero;

/// In the hardhat tests we do the upgrade all at once.
/// On localhost/stage/.. we will call the components and send the calldata to Governance manually
export async function upgradeToHyperchains(
  deployer: Deployer,
  gasPrice: BigNumberish,
  create2Salt?: string,
  nonce?: number
) {
  await upgradeToHyperchains1(deployer, gasPrice, create2Salt, nonce);
  await upgradeToHyperchains2(deployer, gasPrice);
  await upgradeToHyperchains3(deployer);
}

/// this just deploys the contract ( we do it here instead of using the protocol-upgrade tool, since we are deploying more than just facets, the Bridgehub, STM, etc.)
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
  await deployNewContracts(deployer, gasPrice, create2Salt, nonce);
}

// this simulates the main part of the upgrade, the diamond cut, registration into the Bridgehub and STM, and the bridge upgrade
// before we call this we need to generate the facet cuts using the protocol upgrade tool, on hardhat we test the dummy diamondCut
export async function upgradeToHyperchains2(deployer: Deployer, gasPrice: BigNumberish) {
  // upgrading system contracts on Era only adds setChainId in systemContext, does not interfere with anything
  // we first upgrade the DiamondProxy. the Mailbox is backwards compatible, so the L1ERC20 and other bridges should still work.
  // this requires the sharedBridge to be deployed.
  // In theory, the L1SharedBridge deposits should be disabled until the L2Bridge is upgraded.
  // However, without the Portal, UI being upgraded it does not matter (nobody will call it, they will call the legacy bridge)
  if (deployer.verbose) {
    console.log("Integrating Era into Bridgehub and upgrading L2 system contract");
  }
  await integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer, gasPrice); // details for L2 system contract upgrade are part of the infrastructure/protocol_upgrade tool

  // the L2Bridge and L1ERC20Bridge should be updated relatively in sync, as new messages might not be parsed correctly by the old bridge.
  // however new bridges can parse old messages. L1->L2 messages are faster, so L2 side is upgraded first.
  if (deployer.verbose) {
    console.log("Upgrading L2 bridge");
  }
  await upgradeL2Bridge(deployer);

  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    if (deployer.verbose) {
      console.log("Upgrading L1 ERC20 bridge");
    }
    await upgradeL1ERC20Bridge(deployer);
  }

  // note, withdrawals will not work until this step, but deposits will
  if (deployer.verbose) {
    console.log("Migrating assets from L1 ERC20 bridge and ChainBalance");
  }
  await migrateAssets(deployer);
}

// This sets the Shared Bridge parameters. We need to do this separately, as these params will be known after the upgrade
export async function upgradeToHyperchains3(deployer: Deployer) {
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
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data2);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data3);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data4);
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
  await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });
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
    const adminFacet = new Interface(hardhat.artifacts.readArtifactSync("DummyAdminFacetNoOverlap").abi);

    const data = adminFacet.encodeFunctionData("executeUpgradeNoOverlap", [diamondCut]);
    await deployer.executeUpgrade(deployer.addresses.StateTransition.DiamondProxy, 0, data);
  }
  // register Era in Bridgehub, STM
  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);

  if (deployer.verbose) {
    console.log("Registering Era in stateTransitionManager");
  }
  const registerData = stateTransitionManager.interface.encodeFunctionData("registerAlreadyDeployedHyperchain", [
    deployer.chainId,
    deployer.addresses.StateTransition.DiamondProxy,
  ]);
  await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, registerData);
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
  const data1 = sharedBridge.interface.encodeFunctionData("setL1Erc20Bridge", [
    deployer.addresses.Bridges.ERC20BridgeProxy,
  ]);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data1);
  if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
    if (deployer.verbose) {
      console.log("Initializing l2 bridge in shared bridge");
    }
    const data2 = sharedBridge.interface.encodeFunctionData("initializeChainGovernance", [
      deployer.chainId,
      deployer.addresses.Bridges.L2SharedBridgeProxy,
    ]);
    await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data2);
  }
  if (deployer.verbose) {
    console.log("Setting validators in hyperchain");
  }
  // we have to set it via the STM
  const stm = StateTransitionManagerFactory.connect(
    deployer.addresses.StateTransition.DiamondProxy,
    deployer.deployWallet
  );
  const data3 = stm.interface.encodeFunctionData("setValidator", [
    deployer.chainId,
    deployer.addresses.ValidatorTimeLock,
    true,
  ]);
  await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, data3);

  if (deployer.verbose) {
    console.log("Setting validators in validator timelock");
  }

  // adding to validator timelock
  const validatorOneAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
  const validatorTwoAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR");
  const validatorTimelock = deployer.validatorTimelock(deployer.deployWallet);
  const txRegisterValidator = await validatorTimelock.addValidator(deployer.chainId, validatorOneAddress, {
    gasPrice,
  });
  const receiptRegisterValidator = await txRegisterValidator.wait();
  if (deployer.verbose) {
    console.log(
      `Validator registered, gas used: ${receiptRegisterValidator.gasUsed.toString()}, tx hash: ${
        txRegisterValidator.hash
      }`
    );
  }

  const tx3 = await validatorTimelock.addValidator(deployer.chainId, validatorTwoAddress, {
    gasPrice,
  });
  const receipt3 = await tx3.wait();
  if (deployer.verbose) {
    console.log(`Validator 2 registered, gas used: ${receipt3.gasUsed.toString()}`);
  }
}

async function upgradeL2Bridge(deployer: Deployer) {
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

  if (process.env.CHAIN_ETH_NETWORK === "localhost") {
    // on the main branch the l2SharedBridge governor is incorrectly set to deploy wallet, so we can just make the call
    const hyperchain = deployer.stateTransitionContract(deployer.deployWallet);
    const tx = await hyperchain.requestL2Transaction(
      process.env.CONTRACTS_L2_ERC20_BRIDGE_ADDR,
      0,
      l2ProxyCalldata,
      priorityTxMaxGasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps,
      deployer.deployWallet.address,
      { value: requiredValueForL2Tx.mul(10) }
    );
    await tx.wait();
  } else {
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
      requiredValueForL2Tx.mul(10),
      mailboxCalldata
    );
  }
}

async function upgradeL1ERC20Bridge(deployer: Deployer) {
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

    await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, data1);

    if (deployer.verbose) {
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
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, ethTransferData);

  const tokens = getTokens();
  const altTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
  if (deployer.verbose) {
    console.log("transferring Dai, ", altTokenAddress);
  }

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
