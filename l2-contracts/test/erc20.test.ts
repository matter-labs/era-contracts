import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { expect } from "chai";
import { ethers } from "ethers";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-web3";
import { hashBytecode } from "zksync-web3/build/src/utils";
import { unapplyL1ToL2Alias } from "./test-utils";
import { L2SharedBridgeFactory, L2StandardERC20Factory } from "../typechain";
import type { L2SharedBridge, L2StandardERC20 } from "../typechain";

const richAccount = [
  {
    address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
    privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
  },
  {
    address: "0xa61464658AfeAf65CccaaFD3a512b69A83B77618",
    privateKey: "0xac1e735be8536c6534bb4f17f06f6afc73b2b5ba84ac2cfb12f7461b20c0bbe3",
  },
  {
    address: "0x0D43eB5B8a47bA8900d84AA36656c92024e9772e",
    privateKey: "0xd293c684d884d56f8d6abd64fc76757d3664904e309a0645baf8522ab6366d9e",
  },
];

describe("ERC20Bridge", function () {
  const provider = new Provider(hre.config.networks.localhost.url);
  const deployerWallet = new Wallet(richAccount[0].privateKey, provider);
  const governorWallet = new Wallet(richAccount[1].privateKey, provider);

  // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
  // It is a bit easier to use EOA and it is sufficient for the tests.
  const l1BridgeWallet = new Wallet(richAccount[2].privateKey, provider);

  // We won't actually deploy an L1 token in these tests, but we need some address for it.
  const L1_TOKEN_ADDRESS = "0x1111000000000000000000000000000000001111";

  const testChainId = 9;

  let erc20Bridge: L2SharedBridge;
  let erc20Token: L2StandardERC20;

  before("Deploy token and bridge", async function () {
    const deployer = new Deployer(hre, deployerWallet);

    // While we formally don't need to deploy the token and the beacon proxy, it is a neat way to have the bytecode published
    const l2TokenImplAddress = await deployer.deploy(await deployer.loadArtifact("L2StandardERC20"));
    const l2Erc20TokenBeacon = await deployer.deploy(await deployer.loadArtifact("UpgradeableBeacon"), [
      l2TokenImplAddress.address,
    ]);
    await deployer.deploy(await deployer.loadArtifact("BeaconProxy"), [l2Erc20TokenBeacon.address, "0x"]);

    const beaconProxyBytecodeHash = hashBytecode((await deployer.loadArtifact("BeaconProxy")).bytecode);

    const erc20BridgeImpl = await deployer.deploy(await deployer.loadArtifact("L2SharedBridge"), [testChainId]);
    const bridgeInitializeData = erc20BridgeImpl.interface.encodeFunctionData("initialize", [
      unapplyL1ToL2Alias(l1BridgeWallet.address),
      ethers.constants.AddressZero,
      beaconProxyBytecodeHash,
      governorWallet.address,
    ]);

    const erc20BridgeProxy = await deployer.deploy(await deployer.loadArtifact("TransparentUpgradeableProxy"), [
      erc20BridgeImpl.address,
      governorWallet.address,
      bridgeInitializeData,
    ]);

    erc20Bridge = L2SharedBridgeFactory.connect(erc20BridgeProxy.address, deployerWallet);
  });

  it("Should finalize deposit ERC20 deposit", async function () {
    const erc20BridgeWithL1Bridge = L2SharedBridgeFactory.connect(erc20Bridge.address, l1BridgeWallet);

    const l1Depositor = ethers.Wallet.createRandom();
    const l2Receiver = ethers.Wallet.createRandom();

    const tx = await (
      await erc20BridgeWithL1Bridge.finalizeDeposit(
        // Depositor and l2Receiver can be any here
        l1Depositor.address,
        l2Receiver.address,
        L1_TOKEN_ADDRESS,
        100,
        encodedTokenData("TestToken", "TT", 18)
      )
    ).wait();

    const l2TokenAddress = tx.events.find((event) => event.event === "FinalizeDeposit").args.l2Token;

    // Checking the correctness of the balance:
    erc20Token = L2StandardERC20Factory.connect(l2TokenAddress, deployerWallet);
    expect(await erc20Token.balanceOf(l2Receiver.address)).to.equal(100);
    expect(await erc20Token.totalSupply()).to.equal(100);
    expect(await erc20Token.name()).to.equal("TestToken");
    expect(await erc20Token.symbol()).to.equal("TT");
    expect(await erc20Token.decimals()).to.equal(18);
  });

  it("Governance should be able to reinitialize the token", async () => {
    const erc20TokenWithGovernor = L2StandardERC20Factory.connect(erc20Token.address, governorWallet);

    await (
      await erc20TokenWithGovernor.reinitializeToken(
        {
          ignoreName: false,
          ignoreSymbol: false,
          ignoreDecimals: false,
        },
        "TestTokenNewName",
        "TTN",
        2
      )
    ).wait();

    expect(await erc20Token.name()).to.equal("TestTokenNewName");
    expect(await erc20Token.symbol()).to.equal("TTN");
    // The decimals should stay the same
    expect(await erc20Token.decimals()).to.equal(18);
  });

  it("Governance should not be able to skip initializer versions", async () => {
    const erc20TokenWithGovernor = L2StandardERC20Factory.connect(erc20Token.address, governorWallet);

    await expect(
      erc20TokenWithGovernor.reinitializeToken(
        {
          ignoreName: false,
          ignoreSymbol: false,
          ignoreDecimals: false,
        },
        "TestTokenNewName",
        "TTN",
        20,
        { gasLimit: 10000000 }
      )
    ).to.be.reverted;
  });
});

function encodedTokenData(name: string, symbol: string, decimals: number) {
  const abiCoder = ethers.utils.defaultAbiCoder;
  const encodedName = abiCoder.encode(["string"], [name]);
  const encodedSymbol = abiCoder.encode(["string"], [symbol]);
  const encodedDecimals = abiCoder.encode(["uint8"], [decimals]);

  return abiCoder.encode(["bytes", "bytes", "bytes"], [encodedName, encodedSymbol, encodedDecimals]);
}
