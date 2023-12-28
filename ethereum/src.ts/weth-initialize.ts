import { ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { applyL1ToL2Alias, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

import {
  L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
  L2_WETH_BRIDGE_PROXY_BYTECODE,
  L2_WETH_PROXY_BYTECODE,
  L2_WETH_IMPLEMENTATION_BYTECODE,
  calculateWethAddresses
} from "./utils-bytecode";


import {
  getNumberFromEnv
} from "../scripts/utils";

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv("CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT");

import { IBridgehubFactory } from "../typechain/IBridgehubFactory";

export async function initializeWethBridge(deployer: Deployer, deployWallet: Wallet, gasPrice: ethers.BigNumberish) {
    const bridgehub = deployer.bridgehubContract(deployWallet);
    const l1WethBridge = deployer.defaultWethBridge(deployWallet);
    const nonce = await deployWallet.getTransactionCount();
    

    const l1ProxyAdmin = deployer.addresses.TransparentProxyAdmin;
    const l1GovernorAddress = deployer.addresses.Governance;

    const l2ProxyAdminAddress = applyL1ToL2Alias(l1ProxyAdmin);
    // Note governor can not be EOA
    const l2GovernorAddress = applyL1ToL2Alias(l1GovernorAddress);
  
    const l1WethAddress = await l1WethBridge.l1WethAddress();
    const { l2WethImplAddress, l2WethProxyAddress, l2WethBridgeProxyAddress } = calculateWethAddresses(
      l2ProxyAdminAddress,
      l2GovernorAddress,
      l1WethBridge.address,
      l1WethAddress
    );
  
    const tx1 = await l1WethBridge.initialize();
    const tx2 = await l1WethBridge.initializeV2(
        [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
        ["0x00", "0x00"],
        l2WethProxyAddress,
        l2WethBridgeProxyAddress,
        l1GovernorAddress,
        0,
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

      console.log(`WETH bridge initialized, gasUsed: ${receipts[1].gasUsed.toString()}`);
      console.log(`CONTRACTS_L2_WETH_TOKEN_IMPL_ADDR=${l2WethImplAddress}`);
      console.log(`CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR=${l2WethProxyAddress}`);
    }

  }



  export async function startInitializeChain(deployer: Deployer, deployWallet: Wallet, chainId: string, nonce:number, gasPrice: ethers.BigNumber) {
    const bridgehub = deployer.bridgehubContract(deployWallet);
    const l1WethBridge = deployer.defaultWethBridge(deployWallet);

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

    
    const tx1 = await bridgehub.requestL2Transaction(
        chainId,
        ethers.constants.AddressZero,
        0,
        0,
        "0x",
        priorityTxMaxGasLimit,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        [L2_WETH_PROXY_BYTECODE, L2_WETH_IMPLEMENTATION_BYTECODE],
        deployWallet.address,
        { gasPrice, nonce, value: requiredValueToPublishBytecodes }
      );
   const tx2 =  await  l1WethBridge.startInitializeChain(
        chainId,
        requiredValueToInitializeBridge.mul(2),
        [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
        requiredValueToInitializeBridge,
        requiredValueToInitializeBridge,
        {
          gasPrice,
          nonce: nonce + 1,
          value: requiredValueToInitializeBridge.mul(2),
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
    }
  }