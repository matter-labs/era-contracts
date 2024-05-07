import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { Bridgehub, StateTransitionManager } from "../../typechain";
import { BridgehubFactory, StateTransitionManagerFactory } from "../../typechain";

import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";

import type { Deployer } from "../../src.ts/deploy";

describe("Initial deployment", function () {
  let bridgehub: Bridgehub;
  let stateTransition: StateTransitionManager;
  let owner: ethers.Signer;
  let deployer: Deployer;
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

    // await deploySharedBridgeOnL2ThroughL1(deployer, chainId.toString(), gasPrice);

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    stateTransition = StateTransitionManagerFactory.connect(
      deployer.addresses.StateTransition.StateTransitionProxy,
      deployWallet
    );
  });

  it("Check addresses", async () => {
    const stateTransitionManagerAddress1 = deployer.addresses.StateTransition.StateTransitionProxy;
    const stateTransitionManagerAddress2 = await bridgehub.stateTransitionManager(chainId);
    expect(stateTransitionManagerAddress1.toLowerCase()).equal(stateTransitionManagerAddress2.toLowerCase());

    const stateTransitionAddress1 = deployer.addresses.StateTransition.DiamondProxy;
    const stateTransitionAddress2 = await stateTransition.getHyperchain(chainId);
    expect(stateTransitionAddress1.toLowerCase()).equal(stateTransitionAddress2.toLowerCase());

    const stateTransitionAddress3 = await bridgehub.getHyperchain(chainId);
    expect(stateTransitionAddress1.toLowerCase()).equal(stateTransitionAddress3.toLowerCase());
  });
});
