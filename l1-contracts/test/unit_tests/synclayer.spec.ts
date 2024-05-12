import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { Bridgehub, StateTransitionManager } from "../../typechain";
import { BridgehubFactory, StateTransitionManagerFactory } from "../../typechain";

import { registerHyperchain } from "../../src.ts/deploy-process";
import { initialTestnetDeploymentProcess, defaultDeployerForTests } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";

import type { Deployer } from "../../src.ts/deploy";

describe("Synclayer", function () {
  let bridgehub: Bridgehub;
  let stateTransition: StateTransitionManager;
  let owner: ethers.Signer;
  let deployer: Deployer;
  let deployer2: Deployer;
  // const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
  // const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
  // let forwarder: Forwarder;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

  before(async () => {
    [owner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    const gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: await owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, []);

    chainId = deployer.chainId;

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    stateTransition = StateTransitionManagerFactory.connect(
      deployer.addresses.StateTransition.StateTransitionProxy,
      deployWallet
    );

    deployer2 = await defaultDeployerForTests(deployWallet, ownerAddress);
    deployer2.chainId = 10;
    await registerHyperchain(deployer2, false, [], gasPrice, undefined, deployer2.chainId.toString());

    // For tests, the chainId is 9
    deployer.chainId = 9;
  });

  it("Check register synclayer", async () => {
    await deployer2.registerSyncLayer();
  });

  it("Check move chain to synclayer", async () => {
    await deployer.moveChainToSyncLayer(deployer2.chainId);
  });
});
