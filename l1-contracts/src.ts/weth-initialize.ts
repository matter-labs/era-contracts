import type { Wallet } from "ethers";
import { ethers } from "ethers";
import type { Deployer } from "../src.ts/deploy";
import { applyL1ToL2Alias, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

import {
  calculateWethAddresses,
  L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
  L2_WETH_BRIDGE_PROXY_BYTECODE,
  L2_WETH_IMPLEMENTATION_BYTECODE,
  L2_WETH_PROXY_BYTECODE,
} from "./utils-bytecode";

import { ADDRESS_ONE, getNumberFromEnv } from "../scripts/utils";

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv("CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT");

import { TestnetERC20TokenFactory } from "../typechain";

export async function initializeWethBridge(deployer: Deployer, deployWallet: Wallet, gasPrice: ethers.BigNumberish) {
  deployer.bridgehubContract(deployWallet);
  const l1WethBridge = deployer.defaultWethBridge(deployWallet);
  const nonce = await deployWallet.getTransactionCount();

  const l1GovernorAddress = deployer.addresses.Governance;

  // Note governor can not be EOA
  const l2GovernorAddress = applyL1ToL2Alias(l1GovernorAddress);

  const l1WethAddress = await l1WethBridge.l1WethAddress();
  const {
    l2WethProxyAddress: l2WethProxyAddressEthIsBase,
    l2WethBridgeProxyAddress: l2WethBridgeProxyAddressEthIsBase,
  } = calculateWethAddresses(l2GovernorAddress, l1WethBridge.address, l1WethAddress, true);

  const {
    l2WethProxyAddress: l2WethProxyAddressEthIsNotBase,
    l2WethBridgeProxyAddress: l2WethBridgeProxyAddressEthIsNotBase,
  } = calculateWethAddresses(l2GovernorAddress, l1WethBridge.address, l1WethAddress, false);

  const tx1 = await l1WethBridge.initialize(
    l1GovernorAddress,
    0,
    { nonce: nonce, gasPrice }
  );

  const txs = [tx1];
  if (deployer.verbose) {
    for (const tx of txs) {
      console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);
    }
  }
  const receipts = await Promise.all(txs.map((tx) => tx.wait(1)));
  if (deployer.verbose) {
    console.log(`WETH bridge initialized, gasUsed: ${receipts[0].gasUsed.toString()}`);
    // console.log(`CONTRACTS_L2_WETH_TOKEN_IMPL_ADDR=${l2WethImplAddressEthIsBase}`);
    // console.log(`CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR=${l2WethProxyAddressEthIsBase}`);
    // console.log(`CONTRACTS_L2_WETH_BRIDGE_ADDR=${l2WethBridgeProxyAddressEthIsBase}`);
  }
}

export async function startWethBridgeInitOnChain(
  deployer: Deployer,
  deployWallet: Wallet,
  chainId: string,
  nonce: number,
  gasPrice: ethers.BigNumber
) {
  const bridgehub = deployer.bridgehubContract(deployWallet);
  const l1WethBridge = deployer.defaultWethBridge(deployWallet);
  const ethIsBaseToken = ADDRESS_ONE == deployer.addresses.BaseToken;
  // There will be two deployments done during the initial initialization
  const requiredValueToInitializeBridge = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const priorityTxMaxGasLimit = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");

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

    const approveTx1 = await erc20.increaseAllowance(
      deployer.addresses.Bridges.BaseTokenBridge,
      requiredValueToPublishBytecodes
    );
    await approveTx1.wait(1);

    const approveTx2 = await erc20.increaseAllowance(
      deployer.addresses.Bridges.WethBridgeProxy,
      requiredValueToInitializeBridge.mul(2)
    );
    await approveTx2.wait(1);
  }
  nonce = await deployWallet.getTransactionCount();
  const tx1 = await bridgehub.requestL2Transaction(
    {
      chainId,
      l2Contract: ethers.constants.AddressZero,
      mintValue: requiredValueToPublishBytecodes,
      l2Value: 0,
      l2Calldata: "0x",
      l2GasLimit: priorityTxMaxGasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: [L2_WETH_PROXY_BYTECODE, L2_WETH_IMPLEMENTATION_BYTECODE],
      refundRecipient: deployWallet.address,
    },
    { gasPrice, nonce, value: ethIsBaseToken ? requiredValueToPublishBytecodes : 0 }
  );

  const tx2 = await l1WethBridge.startWethBridgeInitOnChain(
    chainId,
    [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
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
    console.log(`WETH bridge priority tx sent to hyperchain, gasUsed: ${receipts[1].gasUsed.toString()}`);
    console.log(`WETH bridge initialized for chain ${chainId}, gasUsed: ${receipts[1].gasUsed.toString()}`);

    // note we print the CONTRACTS_L2_WETH_BRIDGE_ADDR out here. This is because if we printed it out in
    // finishWETHBridgeInit, then we would have to restart the server
    const l1GovernorAddress = await l1WethBridge.owner();

    // Note governor can not be EOA
    const l2GovernorAddress = applyL1ToL2Alias(l1GovernorAddress);

    const l1WethAddress = await l1WethBridge.l1WethAddress();
    const { l2WethProxyAddress, l2WethBridgeProxyAddress } = calculateWethAddresses(
      l2GovernorAddress,
      l1WethBridge.address,
      l1WethAddress,
      ethIsBaseToken
    );

    console.log(`CONTRACTS_L2_WETH_BRIDGE_ADDR=${l2WethBridgeProxyAddress}`);
    console.log(`CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR=${l2WethProxyAddress}`);
  }
}
