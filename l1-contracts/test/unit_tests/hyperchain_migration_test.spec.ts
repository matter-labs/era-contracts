import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import { initialPreUpgradeContractsDeployment } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";
import type { EraDeployer } from "../../src.ts/deploy-test-process";

import { upgradeToHyperchains } from "../../src.ts/hyperchain-upgrade";

// note this test presumes that it is ok to start out with the new contracts, and upgrade them to themselves
describe("Hyperchain migration test", function () {
  let owner: ethers.Signer;
  let deployer: EraDeployer;
  let gasPrice;

  before(async () => {
    [owner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: await owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    // send some Eth to the diamond Proxy, we do it before it is deployed ( it is hard afterwards)
    const tx2 = {
      from: await owner.getAddress(),
      to: "0xd02a18Ab2d8314a81563d596960673b716383AC7", // the address of the diamondproxy
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx2);

    deployer = await initialPreUpgradeContractsDeployment(deployWallet, ownerAddress, gasPrice, []);
  });

  it("Start upgrade", async () => {
    await upgradeToHyperchains(deployer, gasPrice);
  });
});
