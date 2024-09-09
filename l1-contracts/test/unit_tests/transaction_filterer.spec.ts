import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { TransactionFilterer } from "../../typechain";
import { TransactionFiltererFactory } from "../../typechain";

import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";

import { getCallRevertReason, randomAddress } from "./utils";

describe("Transaction Filterer test", function () {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployer: Deployer;
  let transactionFilterer: TransactionFilterer;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

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

    transactionFilterer = TransactionFiltererFactory.connect(
      deployer.addresses.TransactionFilterer.TxFiltererProxy,
      deployWallet
    );
  });

  it("Random address should not be whitelisted", async () => {
    const sender = randomAddress();

    const revertReason = await getCallRevertReason(transactionFilterer.revokeWhitelist(sender));
    expect(revertReason).contains("NotWhitelisted");
  });

  it("Only owner should be able to grant or revoke whitelist", async () => {
    const sender = randomAddress();

    let revertReason = await getCallRevertReason(transactionFilterer.connect(randomSigner).grantWhitelist(sender));
    expect(revertReason).contains("Ownable: caller is not the owner");

    revertReason = await getCallRevertReason(transactionFilterer.connect(randomSigner).revokeWhitelist(sender));
    expect(revertReason).contains("Ownable: caller is not the owner");
  });

  it("Grant whitelist called by owner should succeed", async () => {
    const sender = randomAddress();

    await transactionFilterer.grantWhitelist(sender);

    const isWhitelisted = await transactionFilterer.whitelistedSenders(sender);
    expect(isWhitelisted).to.equal(true);
  });

  it("Filterer should not allow transactions for sender, which is not whitelisted", async () => {
    const sender = randomAddress();

    const isTxAllowed = await transactionFilterer.isTransactionAllowed(sender, sender, 0, 0, "0x", sender);
    expect(isTxAllowed).to.equal(false);
  });

  it("Filterer should allow transactions from whitelisted senders", async () => {
    const sender = randomAddress();

    await transactionFilterer.grantWhitelist(sender);

    const isTxAllowed = await transactionFilterer.isTransactionAllowed(sender, sender, 0, 0, "0x", sender);
    expect(isTxAllowed).to.equal(true);
  });
});
