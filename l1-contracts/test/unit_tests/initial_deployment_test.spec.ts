import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type {
  Bridgehub,
  StateTransitionManager,
  L1NativeTokenVault,
  L1AssetRouter,
  L1Nullifier,
} from "../../typechain";
import {
  BridgehubFactory,
  StateTransitionManagerFactory,
  L1NativeTokenVaultFactory,
  L1AssetRouterFactory,
  L1NullifierFactory,
} from "../../typechain";

import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";

import type { Deployer } from "../../src.ts/deploy";

describe("Initial deployment test", function () {
  let bridgehub: Bridgehub;
  let stateTransitionManager: StateTransitionManager;
  let owner: ethers.Signer;
  let deployer: Deployer;
  // const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
  // const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
  // let forwarder: Forwarder;
  let l1NativeTokenVault: L1NativeTokenVault;
  let l1AssetRouter: L1AssetRouter;
  let l1Nullifier: L1Nullifier;
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
    stateTransitionManager = StateTransitionManagerFactory.connect(
      deployer.addresses.StateTransition.StateTransitionProxy,
      deployWallet
    );
    l1NativeTokenVault = L1NativeTokenVaultFactory.connect(
      deployer.addresses.Bridges.NativeTokenVaultProxy,
      deployWallet
    );
    l1AssetRouter = L1AssetRouterFactory.connect(deployer.addresses.Bridges.SharedBridgeProxy, deployWallet);
    l1Nullifier = L1NullifierFactory.connect(deployer.addresses.Bridges.L1NullifierProxy, deployWallet);
  });

  it("Check addresses", async () => {
    const bridgehubAddress1 = deployer.addresses.Bridgehub.BridgehubProxy;
    const bridgehubAddress2 = await l1AssetRouter.BRIDGE_HUB();
    const bridgehubAddress3 = await stateTransitionManager.BRIDGE_HUB();
    expect(bridgehubAddress1.toLowerCase()).equal(bridgehubAddress2.toLowerCase());
    expect(bridgehubAddress1.toLowerCase()).equal(bridgehubAddress3.toLowerCase());

    const stateTransitionManagerAddress1 = deployer.addresses.StateTransition.StateTransitionProxy;
    const stateTransitionManagerAddress2 = await bridgehub.stateTransitionManager(chainId);
    expect(stateTransitionManagerAddress1.toLowerCase()).equal(stateTransitionManagerAddress2.toLowerCase());

    const stateTransitionAddress1 = deployer.addresses.StateTransition.DiamondProxy;
    const stateTransitionAddress2 = await stateTransitionManager.getHyperchain(chainId);
    const stateTransitionAddress3 = await bridgehub.getHyperchain(chainId);
    expect(stateTransitionAddress1.toLowerCase()).equal(stateTransitionAddress2.toLowerCase());
    expect(stateTransitionAddress1.toLowerCase()).equal(stateTransitionAddress3.toLowerCase());

    const assetRouterAddress1 = deployer.addresses.Bridges.SharedBridgeProxy;
    const assetRouterAddress2 = await bridgehub.sharedBridge();
    const assetRouterAddress3 = await l1NativeTokenVault.ASSET_ROUTER();
    const assetRouterAddress4 = await l1Nullifier.l1AssetRouter();
    expect(assetRouterAddress1.toLowerCase()).equal(assetRouterAddress2.toLowerCase());
    expect(assetRouterAddress1.toLowerCase()).equal(assetRouterAddress3.toLowerCase());
    expect(assetRouterAddress1.toLowerCase()).equal(assetRouterAddress4.toLowerCase());

    const ntvAddress1 = deployer.addresses.Bridges.NativeTokenVaultProxy;
    const ntvAddress2 = await l1Nullifier.l1NativeTokenVault();
    const ntvAddress3 = await l1AssetRouter.nativeTokenVault();
    expect(ntvAddress1.toLowerCase()).equal(ntvAddress2.toLowerCase());
    expect(ntvAddress1.toLowerCase()).equal(ntvAddress3.toLowerCase());
  });
});
