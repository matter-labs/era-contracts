import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { expect } from "chai";
import { ethers } from "ethers";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-ethers";
import { hashBytecode } from "zksync-ethers/build/utils";
import { unapplyL1ToL2Alias, setCode } from "./test-utils";
import type { L2AssetRouter, L2NativeTokenVault, L2StandardERC20 } from "../typechain";
import { L2AssetRouterFactory, L2NativeTokenVaultFactory, L2StandardERC20Factory } from "../typechain";

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
  {
    address: "0xA13c10C0D5bd6f79041B9835c63f91de35A15883",
    privateKey: "0x850683b40d4a740aa6e745f889a6fdc8327be76e122f5aba645a5b02d0248db8",
  },
];

describe("ERC20Bridge", function () {
  const provider = new Provider(hre.config.networks.localhost.url);
  const deployerWallet = new Wallet(richAccount[0].privateKey, provider);
  const governorWallet = new Wallet(richAccount[1].privateKey, provider);
  const proxyAdminWallet = new Wallet(richAccount[3].privateKey, provider);

  // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
  // It is a bit easier to use EOA and it is sufficient for the tests.
  const l1BridgeWallet = new Wallet(richAccount[2].privateKey, provider);

  // We won't actually deploy an L1 token in these tests, but we need some address for it.
  const L1_TOKEN_ADDRESS = "0x1111000000000000000000000000000000001111";
  const L2_ASSET_ROUTER_ADDRESS = "0x0000000000000000000000000000000000010003";
  const L2_NATIVE_TOKEN_VAULT_ADDRESS = "0x0000000000000000000000000000000000010004";

  const testChainId = 9;

  let erc20Bridge: L2AssetRouter;
  let erc20NativeTokenVault: L2NativeTokenVault;
  let erc20Token: L2StandardERC20;
  const contractsDeployedAlready: boolean = false;

  before("Deploy token and bridge", async function () {
    const deployer = new Deployer(hre, deployerWallet);

    // While we formally don't need to deploy the token and the beacon proxy, it is a neat way to have the bytecode published
    const l2TokenImplAddress = await deployer.deploy(await deployer.loadArtifact("L2StandardERC20"));
    const l2Erc20TokenBeacon = await deployer.deploy(await deployer.loadArtifact("UpgradeableBeacon"), [
      l2TokenImplAddress.address,
    ]);
    await deployer.deploy(await deployer.loadArtifact("BeaconProxy"), [l2Erc20TokenBeacon.address, "0x"]);
    const beaconProxyBytecodeHash = hashBytecode((await deployer.loadArtifact("BeaconProxy")).bytecode);
    let constructorArgs = ethers.utils.defaultAbiCoder.encode(
      ["uint256", "uint256", "address", "address"],
      /// note in real deployment we have to transfer ownership of standard deployer here
      [testChainId, 1, unapplyL1ToL2Alias(l1BridgeWallet.address), unapplyL1ToL2Alias(l1BridgeWallet.address)]
    );
    await setCode(
      deployerWallet,
      L2_ASSET_ROUTER_ADDRESS,
      (await deployer.loadArtifact("L2AssetRouter")).bytecode,
      true,
      constructorArgs
    );

    erc20Bridge = L2AssetRouterFactory.connect(L2_ASSET_ROUTER_ADDRESS, deployerWallet);
    const l2NativeTokenVaultArtifact = await deployer.loadArtifact("L2NativeTokenVault");
    constructorArgs = ethers.utils.defaultAbiCoder.encode(
      ["uint256", "bytes32", "address", "bool"],
      /// note in real deployment we have to transfer ownership of standard deployer here
      [1, beaconProxyBytecodeHash, governorWallet.address, contractsDeployedAlready]
    );
    await setCode(
      deployerWallet,
      L2_NATIVE_TOKEN_VAULT_ADDRESS,
      l2NativeTokenVaultArtifact.bytecode,
      true,
      constructorArgs
    );

    erc20NativeTokenVault = L2NativeTokenVaultFactory.connect(L2_NATIVE_TOKEN_VAULT_ADDRESS, l1BridgeWallet);
    const governorNTV = L2NativeTokenVaultFactory.connect(L2_NATIVE_TOKEN_VAULT_ADDRESS, governorWallet);
    await governorNTV.configureL2TokenBeacon(false, ethers.constants.AddressZero);
  });

  it("Should finalize deposit ERC20 deposit", async function () {
    const erc20BridgeWithL1BridgeWallet = L2AssetRouterFactory.connect(erc20Bridge.address, proxyAdminWallet);
    const l1Depositor = ethers.Wallet.createRandom();
    const l2Receiver = ethers.Wallet.createRandom();
    const l1Bridge = await hre.ethers.getImpersonatedSigner(l1BridgeWallet.address);
    const tx = await (
      await erc20BridgeWithL1BridgeWallet.connect(l1Bridge)["finalizeDeposit(address,address,address,uint256,bytes)"](
        // Depositor and l2Receiver can be any here
        l1Depositor.address,
        l2Receiver.address,
        L1_TOKEN_ADDRESS,
        100,
        encodedTokenData("TestToken", "TT", 18)
      )
    ).wait();
    const l2TokenInfo = tx.events.find((event) => event.event === "FinalizeDepositSharedBridge").args.assetId;
    const l2TokenAddress = await erc20NativeTokenVault.tokenAddress(l2TokenInfo);
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
