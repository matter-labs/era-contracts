import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { expect } from "chai";
import { ethers } from "ethers";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-web3";
import type { L2Weth } from "../typechain/L2Weth";
import type { L2WethBridge } from "../typechain/L2WethBridge";
import { L2WethBridgeFactory } from "../typechain/L2WethBridgeFactory";
import { L2WethFactory } from "../typechain/L2WethFactory";

const richAccount = {
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
  privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
};

const eth18 = ethers.utils.parseEther("18");

describe("WETH token & WETH bridge", function () {
  const provider = new Provider(hre.config.networks.localhost.url);
  const wallet = new Wallet(richAccount.privateKey, provider);
  let wethToken: L2Weth;
  let wethBridge: L2WethBridge;

  before("Deploy token and bridge", async function () {
    const deployer = new Deployer(hre, wallet);
    const wethTokenImpl = await deployer.deploy(await deployer.loadArtifact("L2Weth"));
    const wethBridgeImpl = await deployer.deploy(await deployer.loadArtifact("L2WethBridge"));
    const randomAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));

    const wethTokenProxy = await deployer.deploy(await deployer.loadArtifact("TransparentUpgradeableProxy"), [
      wethTokenImpl.address,
      randomAddress,
      "0x",
    ]);
    const wethBridgeProxy = (await deployer.deploy(await deployer.loadArtifact("TransparentUpgradeableProxy"), [
      wethBridgeImpl.address,
      randomAddress,
      "0x",
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ])) as any;

    wethToken = L2WethFactory.connect(wethTokenProxy.address, wallet);
    wethBridge = L2WethBridgeFactory.connect(wethBridgeProxy.address, wallet);

    await wethToken.initialize("Wrapped Ether", "WETH");
    await wethToken.initializeV2(wethBridge.address, randomAddress);

    await wethBridge.initialize(randomAddress, randomAddress, wethToken.address);
  });

  it("Should deposit WETH by calling deposit()", async function () {
    await wethToken.deposit({ value: eth18 }).then((tx) => tx.wait());
    expect(await wethToken.balanceOf(wallet.address)).to.equal(eth18);
  });

  it("Should deposit WETH by sending", async function () {
    await wallet
      .sendTransaction({
        to: wethToken.address,
        value: eth18,
      })
      .then((tx) => tx.wait());
    expect(await wethToken.balanceOf(wallet.address)).to.equal(eth18.mul(2));
  });

  it("Should fail depositing with random calldata", async function () {
    await expect(
      wallet.sendTransaction({
        data: ethers.utils.randomBytes(36),
        to: wethToken.address,
        value: eth18,
        gasLimit: 100_000,
      })
    ).to.be.reverted;
  });

  it("Should withdraw WETH to L2 ETH", async function () {
    await wethToken.withdraw(eth18).then((tx) => tx.wait());
    expect(await wethToken.balanceOf(wallet.address)).to.equal(eth18);
  });

  it("Should withdraw WETH to L1 ETH", async function () {
    await expect(wethBridge.withdraw(wallet.address, wethToken.address, eth18.div(2)))
      .to.emit(wethBridge, "WithdrawalInitiated")
      .and.to.emit(wethToken, "BridgeBurn");
    expect(await wethToken.balanceOf(wallet.address)).to.equal(eth18.div(2));
  });

  it("Should deposit WETH to another account", async function () {
    const anotherWallet = new Wallet(ethers.utils.randomBytes(32), provider);
    await wethToken.depositTo(anotherWallet.address, { value: eth18 }).then((tx) => tx.wait());
    expect(await wethToken.balanceOf(anotherWallet.address)).to.equal(eth18);
  });

  it("Should withdraw WETH to another account", async function () {
    const anotherWallet = new Wallet(ethers.utils.randomBytes(32), provider);
    await wethToken.withdrawTo(anotherWallet.address, eth18.div(2)).then((tx) => tx.wait());
    expect(await anotherWallet.getBalance()).to.equal(eth18.div(2));
    expect(await wethToken.balanceOf(wallet.address)).to.equal(0);
  });

  it("Should fail withdrawing with insufficient balance", async function () {
    await expect(wethToken.withdraw(1, { gasLimit: 100_000 })).to.be.reverted;
  });

  it("Should fail depositing directly to WETH bridge", async function () {
    await expect(
      wallet.sendTransaction({
        to: wethBridge.address,
        value: eth18,
        gasLimit: 100_000,
      })
    ).to.be.reverted;
  });

  it("Should fail calling bridgeMint()", async function () {
    await expect(wethToken.bridgeMint(wallet.address, eth18, { gasLimit: 100_000 })).to.be.revertedWith(
      /Use deposit\/depositTo methods instead/
    );
  });

  it("Should fail calling bridgeBurn() directly", async function () {
    await expect(wethToken.bridgeBurn(wallet.address, eth18, { gasLimit: 100_000 })).to.be.reverted;
  });
});
