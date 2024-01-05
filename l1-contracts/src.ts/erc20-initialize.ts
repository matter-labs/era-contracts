import { ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { ADDRESS_ONE, getNumberFromEnv } from "../scripts/utils";

import { applyL1ToL2Alias, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

import {
  L2_ERC20_BRIDGE_PROXY_BYTECODE,
  L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
  L2_STANDARD_ERC20_PROXY_BYTECODE,
  calculateERC20Addresses,
  L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
  L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
} from "./utils-bytecode";
import { TestnetERC20TokenFactory } from "../typechain";

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv("CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT");

export async function initializeErc20Bridge(
  deployer: Deployer,
  deployWallet: Wallet,
  gasPrice: ethers.BigNumberish,
  cmdErc20Bridge: string
) {
  const bridgehub = deployer.bridgehubContract(deployWallet);
  const nonce = await deployWallet.getTransactionCount();

  const erc20Bridge = cmdErc20Bridge
    ? deployer.defaultERC20Bridge(deployWallet).attach(cmdErc20Bridge)
    : deployer.defaultERC20Bridge(deployWallet);

  const l1ProxyAdmin = deployer.addresses.TransparentProxyAdmin;
  const l1GovernorAddress = deployer.addresses.Governance;

  const l2ProxyAdminAddress = applyL1ToL2Alias(l1ProxyAdmin);
  // Governor should always be smart contract (except for unit tests)
  const l2GovernorAddress = applyL1ToL2Alias(l1GovernorAddress);

  const { l2TokenFactoryAddr, l2ERC20BridgeProxyAddr } = calculateERC20Addresses(
    l2ProxyAdminAddress,
    l2GovernorAddress,
    erc20Bridge
  );

  const tx1 = await erc20Bridge.initialize();
  const tx2 = await erc20Bridge.initializeV2(
    [L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE, L2_ERC20_BRIDGE_PROXY_BYTECODE, L2_STANDARD_ERC20_PROXY_BYTECODE],
    l2TokenFactoryAddr,
    l2ERC20BridgeProxyAddr,
    l1GovernorAddress,
    { nonce: nonce + 1, gasPrice }
  );

  const txs = [tx1, tx2];
  if (deployer.verbose) {
    for (const tx of txs) {
      console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);
    }
  }
  const receipts = await Promise.all(txs.map((tx) => tx.wait(1)));
  if (deployer.verbose) {
    console.log(`ERC20 bridge initialized on L1, gasUsed: ${receipts[0].gasUsed.toString()}`);
  }
}

export async function startInitializeChain(
  deployer: Deployer,
  deployWallet: Wallet,
  chainId: string,
  nonce: number,
  gasPrice: ethers.BigNumberish,
  erc20BridgeAddress?: string
) {
  const bridgehub = deployer.bridgehubContract(deployWallet);
  const erc20Bridge = erc20BridgeAddress
    ? deployer.defaultERC20Bridge(deployWallet).attach(erc20BridgeAddress)
    : deployer.defaultERC20Bridge(deployWallet);
  const ethIsBaseToken = ADDRESS_ONE == deployer.addresses.BaseToken;

  const priorityTxMaxGasLimit = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");

  // There will be two deployments done during the initial initialization
  const requiredValueToInitializeBridge = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const requiredValueToPublishBytecodes = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  if (!ethIsBaseToken) {
    const erc20 = deployer.baseTokenContract(deployWallet);
    const testErc20 = TestnetERC20TokenFactory.connect(deployer.addresses.BaseToken, deployWallet);
    const mintTx = await testErc20.mint(
      deployWallet.address,
      requiredValueToPublishBytecodes.add(requiredValueToInitializeBridge.mul(2))
    );
    await mintTx.wait(1);

    const approveTx = await erc20.approve(
      deployer.addresses.Bridges.BaseTokenBridge,
      requiredValueToPublishBytecodes.add(requiredValueToInitializeBridge.mul(2))
    );
    await approveTx.wait(1);
  }
  nonce = await deployWallet.getTransactionCount();

  const tx1 = await bridgehub.requestL2Transaction(
    {
      chainId,
      payer: deployWallet.address,
      l2Contract: ethers.constants.AddressZero,
      mintValue: requiredValueToPublishBytecodes,
      l2Value: 0,
      l2Calldata: "0x",
      l2GasLimit: priorityTxMaxGasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: [L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE, L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE],
      refundRecipient: deployWallet.address,
    },
    { gasPrice, nonce, value: ethIsBaseToken ? requiredValueToPublishBytecodes : 0 }
  );
  const tx2 = await erc20Bridge.startInitializeChain(
    chainId,
    requiredValueToInitializeBridge.mul(2),
    [L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE, L2_ERC20_BRIDGE_PROXY_BYTECODE, L2_STANDARD_ERC20_PROXY_BYTECODE],
    requiredValueToInitializeBridge,
    requiredValueToInitializeBridge,
    {
      gasPrice,
      nonce: nonce + 1,
      value: ethIsBaseToken ? requiredValueToInitializeBridge.mul(2) : 0,
    }
  );

  const txs = [tx1, tx2];

  if (deployer.verbose) {
    for (const tx of txs) {
      console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);
    }
  }
  const receipts = await Promise.all(txs.map((tx) => tx.wait(1)));
  if (deployer.verbose) {
    console.log(`ERC20 bridge deploy tx sent to hyperchain, gasUsed: ${receipts[1].gasUsed.toString()}`);
    console.log(`CONTRACTS_L2_ERC20_BRIDGE_ADDR=${await erc20Bridge.l2BridgeStandardAddress()}`);
  }
}
