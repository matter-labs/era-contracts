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

import { IERC20Factory } from "../typechain/IERC20Factory";
import { web3Provider } from "../scripts/utils";

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
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data2, !!printFileName);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data3, !!printFileName);
  await deployer.executeUpgrade(deployer.addresses.Bridges.SharedBridgeProxy, 0, data4, !!printFileName);
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
    !!printFileName
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

    await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, data1, !!printFileName);

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

  await deployer.executeUpgrade(deployer.addresses.Bridges.ERC20BridgeProxy, 0, data1, !!printFileName);

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
    "1000000",
    { gasLimit: 25_000_000 }
  );
  await tx.wait();
  console.log("Receipt", tx.hash);
}

export async function upgradeProverFix(deployer: Deployer, create2Salt: string, gasPrice: BigNumberish) {
  await deployer.deployVerifier(create2Salt, { gasPrice });
  await deployer.deployExecutorFacet(create2Salt, { gasPrice });

  // await deployer.deployDefaultUpgrade(create2Salt, { gasPrice });  // Not needed on mainnet
}

export async function upgradeMainnetFix(deployer: Deployer, create2Salt: string, gasPrice: BigNumberish) {
  const stm = deployer.stateTransitionManagerContract(deployer.deployWallet);
  const tx = await stm.setNewVersionUpgrade(
    await deployer.initialZkSyncHyperchainDiamondCut([]),
    103079215104, // = 24* 2**32
    0,
    103079215105 // 24 * 2**32 + 1
  );
  if (create2Salt == gasPrice) {
    console.log("\n");
  }
  await tx.wait();
}

export async function setInitialCutHash(deployer: Deployer) {
  // const diamondCut =
  await deployer.initialZkSyncHyperchainDiamondCut([]);
  // const calldata = deployer
  //   .stateTransitionManagerContract(deployer.deployWallet)
  //   .interface.encodeFunctionData("setInitialCutHash", [diamondCut]);
  // await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, calldata, true);
}

const provider = web3Provider();

export async function transferTokensOnForkedNetwork(deployer: Deployer) {
  // const startToken = 20;
  // const tokens = tokenList.slice(startToken);
  // console.log(`From ${startToken}`, tokens);
  // const tokenList = ["0x5A520e593F89c908cd2bc27D928bc75913C55C42"];
  for (const tokenAddress of tokenList) {
    const erc20contract = IERC20Factory.connect(tokenAddress, provider);
    console.log(`Migrating token ${tokenAddress}`);
    console.log(
      `Balance before: ${await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)}, ${await erc20contract.balanceOf(deployer.addresses.Bridges.SharedBridgeProxy)}`
    );
    await transferTokens(deployer, tokenAddress);
    console.log(
      `Balance after: ${await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)}, ${await erc20contract.balanceOf(deployer.addresses.Bridges.SharedBridgeProxy)}`
    );
  }
  console.log("From 0", tokenList);
  for (const tokenAddress of tokenList) {
    const erc20contract = IERC20Factory.connect(tokenAddress, provider);
    if (!(await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)).eq(0)) {
      console.log(`Failed to transfer all tokens ${tokenAddress}`);
    }
  }
}

export const tokenList = [
  "0xA49d7499271aE71cd8aB9Ac515e6694C755d400c",
  "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  "0xfFffFffF2ba8F66D4e51811C5190992176930278",
  "0xbC396689893D065F41bc2C6EcbeE5e0085233447",
  "0x471Ea49dd8E60E697f4cac262b5fafCc307506e4",
  "0xF655C8567E0f213e6C634CD2A68d992152161dC6",
  "0xba100000625a3754423978a60c9317c58a424e3D",
  "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0",
  "0x95b3497bBcCcc46a8F45F5Cf54b0878b39f8D96C",
  "0xc17272C3e15074C55b810bCebA02ba0C4481cd79",
  "0xF9c53268e9de692AE1b2ea5216E24e1c3ad7CB1E",
  "0x63A3AE78711b52fb75a03aCF9996F18ab611b877",
  "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  "0xcDa4e840411C00a614aD9205CAEC807c7458a0E3",
  "0x5F64Ab1544D28732F0A24F4713c2C8ec0dA089f0",
  "0xA487bF43cF3b10dffc97A9A744cbB7036965d3b9",
  "0x4691937a7508860F876c9c0a2a617E7d9E945D4B",
  "0xeEAA40B28A2d1b0B08f6f97bB1DD4B75316c6107",
  "0xDDdddd4301A082e62E84e43F474f044423921918",
  "0x111111111117dC0aa78b770fA6A738034120C302",
  "0xC63E1F3fDAe49E9eF5951Ab5E84334a6934Ce767",
  "0x108a850856Db3f85d0269a2693D896B394C80325",
  "0x4Fabb145d64652a948d72533023f6E7A623C7C53",
  "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  "0x6982508145454Ce325dDbE47a25d4ec3d2311933",
  "0xd38BB40815d2B0c2d2c866e0c72c5728ffC76dd9",
  "0xD38e031f4529a07996aaB977d2B79f0e00656C56",
  "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  "0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D",
  "0x76054592D1F789eA5958971fb3ba6628334fAa86",
  "0xD33526068D116cE69F19A9ee46F0bd304F21A51f",
  "0xae78736Cd615f374D3085123A210448E74Fc6393",
  "0xBe9895146f7AF43049ca1c1AE358B0541Ea49704",
  "0x459706Cc06a2095266E623a5684126130e74B930",
  "0x1Ed81E03D7DDB67A21755D02ED2f24da71C27C55",
  "0xfAC77A24E52B463bA9857d6b758ba41aE20e31FF",
  "0xA91ac63D040dEB1b7A5E4d4134aD23eb0ba07e14",
  "0xe963e120f818F15420EA3DAD0083289261923C2e",
  "0x4E9e4Ab99Cfc14B852f552f5Fb3Aa68617825B6c",
  "0x21eAD867C8c5181854f6f8Ce71f75b173d2Bc16A",
  "0x3bdffA70f4b4E6985eED50453c7C0D4A15dcEc52",
  "0xc6F5D26e9A9cfA5B917E049139AD9CcF5CDddE6D",
  "0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202",
  "0xC91a71A1fFA3d8B22ba615BA1B9c01b2BBBf55ad",
  "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E",
  "0x8A7aDc1B690E81c758F1BD0F72DFe27Ae6eC56A5",
  "0xC6b50D3c36482Cba08D2b60183Ae17D75b90FdC9",
  "0x7448c7456a97769F6cD04F1E83A4a23cCdC46aBD",
  "0x1571eD0bed4D987fe2b498DdBaE7DFA19519F651",
  "0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E",
  "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE",
  "0xbB94d52B84568Beb26106F5CC66C29f352d85f8d",
  "0x9ad37205d608B8b219e6a2573f922094CEc5c200",
  "0x97e3C21f27182498382f81e32fbe0ea3A0e3D79b",
  "0x5C1d9aA868a30795F92fAe903eDc9eFF269044bf",
  "0x54Ea1C9fe9f3987eB2bc69e2b45aC1F19001406D",
  "0xD41f3D112cb8695c7a8992E4055BD273f3ce8729",
  "0x0a77eF9bf662D62Fbf9BA4cf861EaA83F9CC4FEC",
  "0x423f4e6138E475D85CF7Ea071AC92097Ed631eea",
  "0xe4815AE53B124e7263F08dcDBBB757d41Ed658c6",
  "0x9469D013805bFfB7D3DEBe5E7839237e535ec483",
  "0x72e4f9F808C49A2a61dE9C5896298920Dc4EEEa9",
  "0x6EFF556748Ee452CbDaf31bcb8c76A28651509bd",
  "0xeDCC68Cc8b6Ec3eDE0979f8A52835b238A272027",
  "0xFf5B9f95DCAafc8204d4b6B156Be2851aC7B604f",
  "0xB64ef51C888972c908CFacf59B47C1AfBC0Ab8aC",
  "0x4Bb3205bf648B7F59EF90Dee0F1B62F6116Bc7ca",
  "0x8A9C67fee641579dEbA04928c4BC45F66e26343A",
  "0x0cEC1A9154Ff802e7934Fc916Ed7Ca50bDE6844e",
  "0x5Bec54282A1B57D5d7FdE6330e2D4a78618F0508",
  "0x0386E113221ccC785B0636898d8b379c1A113713",
  "0xBD8FdDa057de7e0162b7A386BeC253844B5E07A5",
  "0x6B175474E89094C44Da98b954EedeAC495271d0F",
  "0x8353b92201f19B4812EeE32EFd325f7EDe123718",
  "0xf0655DcEE37E5C0b70Fffd70D85f88F8eDf0AfF6",
  "0x68592c5c98C4F4A8a4bC6dA2121E65Da3d1c0917",
  "0xB6eD7644C69416d67B522e20bC294A9a9B405B31",
  "0xD533a949740bb3306d119CC777fa900bA034cd52",
  "0x9BE89D2a4cd102D8Fecc6BF9dA793be995C22541",
  "0xea4a1Fc739D8B70d16185950332158eDFa85d3e8",
  "0x600204AE2DB743D15dFA5cbBfB47BBcA2bA0ac3C",
  "0x72aDadb447784dd7AB1F472467750fC485e4cb2d",
  "0x514910771AF9Ca656af840dff83E8264EcF986CA",
  "0x7E743f75C2555A7c29068186feed7525D0fe9195",
  "0x69e5C11a7C30f0bf84A9faECBd5161AA7a94decA",
  "0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1",
  "0xFE3E6a25e6b192A42a44ecDDCd13796471735ACf",
  "0x86715AFA18d9fD7090d5C2e0f8E6E824A8723fBA",
  "0xF629cBd94d3791C9250152BD8dfBDF380E2a3B9c",
  "0xED5464bd5c477b7F71739Ce1d741b43E932b97b0",
  "0xF411903cbC70a74d22900a5DE66A2dda66507255",
  "0xd7C1EB0fe4A30d3B2a846C04aa6300888f087A5F",
  "0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b",
  "0x8A0C816A52e71A1e9b6719580ebE754709C55198",
  "0x9813037ee2218799597d83D4a5B6F3b6778218d9",
  "0x405be842CdB64B69470972Eb83C07C2c0788d864",
  "0x64F80550848eFf3402C5880851B77dD82a1a71F3",
  "0xCeDefE438860D2789dA6419b3a19cEcE2A41038d",
  "0xcfa04B9Bf3c346b2Ac9d3121c1593BA8DD30bCd5",
  "0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6",
  "0x9ee91F9f426fA633d227f7a9b000E28b9dfd8599",
  "0x8c18D6a985Ef69744b9d57248a45c0861874f244",
  "0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4",
  "0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F",
  "0x0f51bb10119727a7e5eA3538074fb341F56B09Ad",
  "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32",
  "0xd1d2Eb1B1e90B638588728b4130137D262C87cae",
  "0xaE86f48c0B00F2a3eaeF4ba4c23d17368f0f63f4",
  "0x10BA1F6604Af42cA96aEAbCa1DF6C26FB0572515",
  "0x44ff8620b8cA30902395A7bD3F2407e1A091BF73",
  "0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30",
  "0x467719aD09025FcC6cF6F8311755809d45a5E5f3",
  "0xD5d86FC8d5C0Ea1aC1Ac5Dfab6E529c9967a45E9",
  "0xD31a59c85aE9D8edEFeC411D448f90841571b89c",
  "0x595832F8FC6BF59c85C527fEC3740A1b7a361269",
  "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0",
  "0xc2E2368D4F3efa84489BF3729C55aFBC2Fa01652",
  "0xb5b2D6acd78Ac99D202a362B50aC3733A47a7C7b",
  "0x9A48BD0EC040ea4f1D3147C025cd4076A2e71e3e",
  "0xBBBbbBBB46A1dA0F0C3F64522c275BAA4C332636",
  "0xFE67A4450907459c3e1FFf623aA927dD4e28c67a",
  "0x7659CE147D0e714454073a5dd7003544234b6Aa0",
  "0x1D4241F7370253C0f12EFC536B7e16E462Fb3526",
  "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
  "0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa",
  "0x22Ee12DFEBc4685bA2240d45893D4e479775b4cf",
  "0xe2353069f71a27bBbe66eEabfF05dE109c7d5E19",
  "0x8f74A5d0A3bA170f2A43b1aBBA16C251F611500D",
  "0xf951E335afb289353dc249e82926178EaC7DEd78",
  "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
  "0xC3f7ac3a68369975CFF21DCbdb303383C5E203CC",
  "0x788DdD6f2c13bDC00426dEB67add5c057de84941",
  "0x4507cEf57C46789eF8d1a19EA45f4216bae2B528",
  "0x57F228e13782554feb8FE180738e12A70717CFAE",
  "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
  "0xB4EFd85c19999D84251304bDA99E90B92300Bd93",
  "0x34Be5b8C30eE4fDe069DC878989686aBE9884470",
  "0xC5190E7FEC4d97a3a3b1aB42dfedac608e2d0793",
  "0xa2B0fDe6D710e201d0d608e924A484d1A5fEd57c",
  "0xE55d97A97ae6A17706ee281486E98A84095d8AAf",
  "0x7bFEBd989ef62f7f794d9936908565dA42Fa6D70",
  "0x0Fb765ddBD4d26AC524AA5990B0643D0Ab6Ac2fE",
  "0xde67d97b8770dC98C746A3FC0093c538666eB493",
  "0x41f7B8b9b897276b7AAE926a9016935280b44E97",
  "0x12970E6868f88f6557B76120662c1B3E50A646bf",
  "0x72577C54b897f2b10a136bF288360B6BAaAD92F2",
  "0xE5F166c0D8872B68790061317BB6CcA04582C912",
  "0x5114616637bEc16B023c9E29632286BcEa670127",
  "0x772c44b5166647B135BB4836AbC4E06c28E94978",
  "0xc834Fa996fA3BeC7aAD3693af486ae53D8aA8B50",
  "0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24",
  "0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7",
  "0xf6AeaF0FE66cf2ef2e738bA465fb531ffE39b4e2",
  "0x9b110Fda4E20DB18Ad7052f8468a455de7449eb6",
  "0x84cA8bc7997272c7CfB4D0Cd3D55cd942B3c9419",
  "0x430EF9263E76DAE63c84292C3409D61c598E9682",
  "0x66a0f676479Cee1d7373f3DC2e2952778BfF5bd6",
  "0x0cF5003a5262E163fDbB26A9DEf389fd468E32CC",
  "0xa41d2f8Ee4F47D3B860A149765A7dF8c3287b7F0",
  "0x562E362876c8Aee4744FC2c6aaC8394C312d215d",
  "0x5D80A8D8CB80696073e82407968600A37e1dd780",
  "0xCdCFc0f66c522Fd086A1b725ea3c0Eeb9F9e8814",
  "0x0a58531518DbA2009BdfBf1AF79602bfD312FdF1",
  "0x5DE8ab7E27f6E7A1fFf3E5B337584Aa43961BEeF",
  "0xda31D0d1Bc934fC34F7189E38A413ca0A5e8b44F",
  "0xa1d0E215a23d7030842FC67cE582a6aFa3CCaB83",
  "0x15e6E0D4ebeAC120F9a97e71FaA6a0235b85ED12",
  "0x9b8e9d523D1D6bC8EB209301c82C7D64D10b219E",
  "0x137dDB47Ee24EaA998a535Ab00378d6BFa84F893",
  "0x88ACDd2a6425c3FaAE4Bc9650Fd7E27e0Bebb7aB",
  "0xb945E3F853B5f8033C8513Cf3cE9F8AD9beBB1c9",
  "0x41EA5d41EEACc2D5c4072260945118a13bb7EbCE",
  "0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39",
  "0x0001A500A6B18995B03f44bb040A5fFc28E45CB0",
  "0x48Fb253446873234F2fEBbF9BdeAA72d9d387f94",
  "0x62D0A8458eD7719FDAF978fe5929C6D342B0bFcE",
  "0x6aDb5216796fD9D4a53F6cC407075C6c075D468A",
  "0x0D8775F648430679A709E98d2b0Cb6250d2887EF",
  "0xb131f4A55907B10d1F0A50d8ab8FA09EC342cd74",
  "0xdc8aF07A7861bedD104B8093Ae3e9376fc8596D2",
  "0x4EE9968393d5ec65b215B9aa61e5598851f384F2",
  "0xc5102fE9359FD9a28f877a67E36B0F050d81a3CC",
  "0x6c249b6F6492864d914361308601A7aBb32E68f8",
  "0x304645590f197d99fAD9fA1d05e7BcDc563E1378",
  "0x805C2077f3ab224D889f9c3992B41B2F4722c787",
  "0x8B5653Ae095529155462eDa8CF664eD96773F557",
  "0xeb2635c62B6b4DdA7943928a1a6189DF654c850e",
  "0x4AaC461C86aBfA71e9d00d9a2cde8d74E4E1aeEa",
  "0x607F4C5BB672230e8672085532f7e901544a7375",
  "0x77F76483399Dc6328456105B1db23e2Aca455bf9",
  "0x0b38210ea11411557c13457D4dA7dC6ea731B88a",
  "0x839e71613f9aA06E5701CF6de63E303616B0DDE3",
  "0xD13c7342e1ef687C5ad21b27c2b65D772cAb5C8c",
  "0x73fBD93bFDa83B111DdC092aa3a4ca77fD30d380",
  "0x66b658b7979abf71d212956f62BdD3630Cc7f309",
  "0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8",
  "0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee",
  "0x8e199473348Eb597d428D4ce950479771a109715",
  "0x83e6f1E41cdd28eAcEB20Cb649155049Fac3D5Aa",
  "0x61a35258107563f6B6f102aE25490901C8760b12",
  "0xbf5495Efe5DB9ce00f80364C8B423567e58d2110",
  "0x8457CA5040ad67fdebbCC8EdCE889A335Bc0fbFB",
  "0x66580f80a00deAfab4519dC33C35BF44d8A12B00",
  "0x869b1F57380aE501d387b19262EFD3C0Eb7501b0",
  "0x000000007a58f5f58E697e51Ab0357BC9e260A04",
  "0x618E75Ac90b12c6049Ba3b27f5d5F8651b0037F6",
  "0x2965395F71B7d97ede251E9B63e44dfA9647cC0A",
  "0x5A520e593F89c908cd2bc27D928bc75913C55C42",
  "0x16AaB4738843FB2d9Eafc8fD261488797bF0df29",
  "0x43Ffdc962DB6c1708e218751e7E8e92009152486",
  "0x4c11249814f11b9346808179Cf06e71ac328c1b5",
  "0xbcD29DA38b66E2b7855C92080ebe82330ED2012a",
  "0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898",
  "0x3007083EAA95497cD6B2b809fB97B6A30bdF53D3",
  "0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd",
  "0xF9Ca9523E5b5A42C3018C62B084Db8543478C400",
  "0x2c489F6c2B728665f56691744f0336A5cC69ba94",
  "0xB627a1BF727f578384ba18B2A2b46f4fb924Ab3b",
  "0x4a0552F34f2237Ce3D15cA69d09F65B7D7aA00bb",
  "0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF",
  "0x178c820f862B14f316509ec36b13123DA19A6054",
  "0xc56c2b7e71B54d38Aab6d52E94a04Cbfa8F604fA",
  "0x5973f93D1efbDcAa91BA2ABc7ae1f6926434bcB6",
  "0xE89C20096b636fFec9fd26d1a623F42A33eaD309",
  "0xC57d533c50bC22247d49a368880fb49a1caA39F7",
  "0x33909C9CE97Ce509daB3A038B3eC7ac3d1Be3231",
  "0xB0c7a3Ba49C7a6EaBa6cD4a96C55a1391070Ac9A",
  "0xE66b3AA360bB78468c00Bebe163630269DB3324F",
  "0x85f138bfEE4ef8e540890CFb48F620571d67Eda3",
  "0xcB77467F6cf5cfC913aC5C757284D914Ed086Cf0",
  "0x7e931f31b742977ed673dE660e54540B45959447",
  "0x175D9Dfd6850AA96460E29bC0cEad05756965E91",
  "0x5d74468b69073f809D4FaE90AfeC439e69Bf6263",
  "0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6",
  "0xF250b1f6193941bB8BFF4152d719EDf1a59C0E69",
  "0xa23C1194d421F252b4e6D5edcc3205F7650a4eBE",
  "0xA8258AbC8f2811dd48EccD209db68F25E3E34667",
  "0x35b0CCC549776e927B8FA7f5fc7afe9f8652472c",
  "0x41B6F91DAa1509bFbe06340D756560C4a1d146Fd",
  "0x5a07EF0B2523fD41F8fE80c3DE1Bc75861d86C51",
  "0xeCbEE2fAE67709F718426DDC3bF770B26B95eD20",
  "0xbDDf3B5A786775F63C2c389B86CDDaDD04d5A7aa",
  "0xD514B77060e04b1Ee7e15f6e1D3b5419e9f32773",
  "0x32a7C02e79c4ea1008dD6564b35F131428673c41",
  "0xD9A442856C234a39a81a089C06451EBAa4306a72",
  "0x207e14389183A94343942de7aFbC607F57460618",
  "0x967da4048cD07aB37855c090aAF366e4ce1b9F48",
  "0x03EE5026c07d85ff8ae791370DD0F4C1aE6C97fc",
  "0x2364BB6DeA9CAcD4F8541aF761D3BcF3d86B26FD",
  "0x750A575284fad07fbF2fCc45Eb26d1111AfeE165",
  "0x6368e1E18c4C419DDFC608A0BEd1ccb87b9250fc",
  "0xFAe103DC9cf190eD75350761e95403b7b8aFa6c0",
  "0x60bE1e1fE41c1370ADaF5d8e66f07Cf1C2Df2268",
  "0xe25bCec5D3801cE3a794079BF94adF1B8cCD802D",
  "0x97AEB5066E1A590e868b511457BEb6FE99d329F5",
  "0x725440512cb7b78bF56B334E50e31707418231CB",
  "0xd9f79Fc56839c696e2E9F63948337F49d164a015",
  "0x516D813bc49b0EB556F9D09549f98443aCDD7D8F",
  "0x54a7cee7B02976ACE1bdd4aFad87273251Ed34Cf",
  "0x8E870D67F660D95d5be530380D0eC0bd388289E1",
  "0x6732Efaf6f39926346BeF8b821a04B6361C4F3e5",
  "0x65E6B60Ea01668634D68D0513Fe814679F925BaD",
  "0xC3ADe5aCe1bBb033CcAE8177C12Ecbfa16bD6A9D",
  "0x9E32b13ce7f2E80A01932B42553652E053D6ed8e",
  "0xf32CEA5d29C060069372AB9385F6E292387d5535",
  "0x4Cf89ca06ad997bC732Dc876ed2A7F26a9E7f361",
  "0xA35b1B31Ce002FBF2058D22F30f95D405200A15b",
  "0xd680ffF1699aD71f52e29CB4C36010feE7b8d61B",
  "0x0E573Ce2736Dd9637A0b21058352e1667925C7a8",
  "0xD973637d6c982a492BdAFE6956cc79163F279B2C",
  "0xfc448180d5254A55846a37c86146407Db48d2a36",
  "0xbc4171f45EF0EF66E76F979dF021a34B46DCc81d",
  "0x163f8C2467924be0ae7B5347228CABF260318753",
  "0x93581991f68DBaE1eA105233b67f7FA0D6BDeE7b",
  "0x9144D8E206B98ED9C38F19D3E4760E278FAAB1C9",
  "0xaE66e13E7ff6F505c6E53aDFE47B2b9082b9E0eA",
  "0xfAc0403a24229d7e2Edd994D50F5940624CBeac2",
  "0x2dE7B02Ae3b1f11d51Ca7b2495e9094874A064c0",
  "0xD101dCC414F310268c37eEb4cD376CcFA507F571",
  "0xCFc006a32a98031C2338BF9d5ff8ED2c0Cae4a9e",
  "0x9D14BcE1dADdf408d77295BB1be9b343814f44DE",
  "0x9fC86c5Afb7b336367B8c1cf1f895dBFDd1CA06d",
  "0xeB8eB73Bbf1B0b3a8eF30e48447F47894Bf6FfdB",
  "0xB7Df0f42FAe30acf30C9A5BA147D6B792b5eB9d9",
  "0xC3D3BCb666588d8b58c921d3d297E04037Ad4665",
  "0xc78B628b060258300218740B1A7a5b3c82b3bd9f",
  "0x8c30bA8e0b776D0B3654B72D737ecd668B26a192",
  "0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d",
  "0xDb82c0d91E057E05600C8F8dc836bEb41da6df14",
  "0x738865301A9b7Dd80Dc3666dD48cF034ec42bdDa",
  "0xC9fE6E1C76210bE83DC1B5b20ec7FD010B0b1D15",
  "0x216c9bb7380cDe431662E37e30098d838d7e1Dc8",
  "0xDa546071DCBcec77E707aCC6ee32328b91607a23",
  "0x2e2364966267B5D7D2cE6CD9A9B5bD19d9C7C6A9",
  "0x2a2550e0A75aCec6D811AE3930732F7f3ad67588",
  "0xf79c694605F29DDF3F0eB41319C38672ab6fA89F",
  "0xAC57De9C1A09FeC648E93EB98875B212DB0d460B",
  "0xF96459323030137703483B46fD59A71D712BF0aa",
  "0x6B3595068778DD592e39A122f4f5a5cF09C90fE2",
  "0x7c9f4C87d911613Fe9ca58b579f737911AAD2D43",
  "0xf2EAb3A2034D3f6B63734D2E08262040E3fF7B48",
  "0x669c01CAF0eDcaD7c2b8Dc771474aD937A7CA4AF",
  "0x828E0EDF347Bd53E57d64426c67F291D8C553a70",
  "0x582d872A1B094FC48F5DE31D3B73F2D9bE47def1",
  "0x8f3470A7388c05eE4e7AF3d01D8C722b0FF52374",
  "0x15f74458aE0bFdAA1a96CA1aa779D715Cc1Eefe4",
  "0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3",
  "0x0000000000ca73A6df4C58b84C5B4b847FE8Ff39",
  "0x025daf950C6e814dEe4c96e13c98D3196D22E60C",
  "0xe2bCA705991ba5F1Bb8a33610dBa10D481379CD3",
  "0xa636Ee3f2C24748e9FC7fd8b577F7A629e879b45",
  "0xf9BD51d756a3caF52348f2901B7EFf9Bd03398E7",
  "0x07150e919B4De5fD6a63DE1F9384828396f25fDC",
  "0x93728F9B63edbb91739f4fbAa84890E5073E3D4f",
  "0x865377367054516e17014CcdED1e7d814EDC9ce4",
  "0xdebe620609674F21B1089042527F420372eA98A5",
  "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
  "0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB",
  "0x726516B20c4692a6beA3900971a37e0cCf7A6BFf",
  "0x4a220E6096B25EADb88358cb44068A3248254675",
  "0x84018071282d4B2996272659D9C01cB08DD7327F",
  "0xc944E90C64B2c07662A292be6244BDf05Cda44a7",
  "0xf65B5C5104c4faFD4b709d9D60a185eAE063276c",
  "0x88dF592F8eb5D7Bd38bFeF7dEb0fBc02cf3778a0",
  "0xCD4b21DeadEEBfCFf202ce73E976012AfAd11361",
  "0x36E66fbBce51e4cD5bd3C62B637Eb411b18949D4",
  "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3",
  "0xdBB7a34Bf10169d6d2D0d02A6cbb436cF4381BFa",
  "0xB8c77482e45F1F44dE1745F52C74426C631bDD52",
  "0x23eC026590d6CCCfEce04097F9B49aE6A442C3BA",
  "0xDA7C0810cE6F8329786160bb3d1734cf6661CA6E",
  "0x72e364F2ABdC788b7E918bc238B21f109Cd634D7",
  "0x1B9eBb707D87fbec93C49D9f2d994Ebb60461B9b",
  "0xd3843c6Be03520f45871874375D618b3C7923019",
  "0xB6ff96B8A8d214544Ca0dBc9B33f7AD6503eFD32",
  "0x2b1D36f5B61AdDAf7DA7ebbd11B35FD8cfb0DE31",
  "0xe8A25C46d623f12B8bA08b583b6fE1bEE3eB31C9",
];
