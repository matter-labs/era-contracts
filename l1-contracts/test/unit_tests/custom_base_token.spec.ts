import { expect } from "chai";
import * as hardhat from "hardhat";
import { ethers, Wallet } from "ethers";
import { Interface } from "ethers/lib/utils";

import type { TestnetERC20Token } from "../../typechain";
import { TestnetERC20TokenFactory } from "../../typechain";
import type { IBridgehub } from "../../typechain/IBridgehub";
import { IBridgehubFactory } from "../../typechain/IBridgehubFactory";
import type { IL1SharedBridge } from "../../typechain/IL1SharedBridge";
import { IL1SharedBridgeFactory } from "../../typechain/IL1SharedBridgeFactory";

import { getTokens } from "../../src.ts/deploy-token";
import type { Deployer } from "../../src.ts/deploy";
import { ADDRESS_ONE, ethTestConfig } from "../../src.ts/utils";
import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";

import { getCallRevertReason, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

describe("Custom base token chain and bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let l1SharedBridge: IL1SharedBridge;
  let bridgehub: IBridgehub;
  let baseToken: TestnetERC20Token;
  let baseTokenAddress: string;
  let altTokenAddress: string;
  let altToken: TestnetERC20Token;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID ? parseInt(process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID) : 270;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic4, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    const gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);
    // note we can use initialDeployment so we don't go into deployment details here
    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [], "BAT");
    chainId = deployer.chainId;
    bridgehub = IBridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    const tokens = getTokens();
    baseTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "BAT")!.address;
    baseToken = TestnetERC20TokenFactory.connect(baseTokenAddress, owner);

    altTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    altToken = TestnetERC20TokenFactory.connect(altTokenAddress, owner);

    // prepare the bridge
    l1SharedBridge = IL1SharedBridgeFactory.connect(deployer.addresses.Bridges.SharedBridgeProxy, deployWallet);
  });

  it("Should have correct base token", async () => {
    // we should still be able to deploy the erc20 bridge
    const baseTokenAddressInBridgehub = await bridgehub.baseToken(chainId);
    expect(baseTokenAddress).equal(baseTokenAddressInBridgehub);
  });

  it("Check should initialize through governance", async () => {
    const l1SharedBridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1SharedBridge").abi);
    const upgradeCall = l1SharedBridgeInterface.encodeFunctionData("initializeChainGovernance(uint256,address)", [
      chainId,
      ADDRESS_ONE,
    ]);

    const txHash = await deployer.executeUpgrade(l1SharedBridge.address, 0, upgradeCall);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Should not allow direct legacy deposits", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .depositLegacyErc20Bridge(
          await randomSigner.getAddress(),
          await randomSigner.getAddress(),
          baseTokenAddress,
          0,
          0,
          0,
          ethers.constants.AddressZero
        )
    );

    expect(revertReason).equal("ShB not legacy bridge");
  });

  it("Should deposit base token successfully direct via bridgehub", async () => {
    await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), ethers.utils.parseUnits("800", 18));
    await (
      await baseToken.connect(randomSigner).approve(l1SharedBridge.address, ethers.utils.parseUnits("800", 18))
    ).wait();
    await bridgehub.connect(randomSigner).requestL2TransactionDirect({
      chainId,
      l2Contract: await randomSigner.getAddress(),
      mintValue: ethers.utils.parseUnits("800", 18),
      l2Value: 1,
      l2Calldata: "0x",
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: [],
      refundRecipient: await randomSigner.getAddress(),
    });
  });

  it("Should deposit alternative token successfully twoBridges method", async () => {
    const altTokenAmount = ethers.utils.parseUnits("800", 18);
    const baseTokenAmount = ethers.utils.parseUnits("800", 18);

    await altToken.connect(randomSigner).mint(await randomSigner.getAddress(), altTokenAmount);
    await (await altToken.connect(randomSigner).approve(l1SharedBridge.address, altTokenAmount)).wait();

    await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), baseTokenAmount);
    await (await baseToken.connect(randomSigner).approve(l1SharedBridge.address, baseTokenAmount)).wait();
    await bridgehub.connect(randomSigner).requestL2TransactionTwoBridges({
      chainId,
      mintValue: baseTokenAmount,
      l2Value: 1,
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      refundRecipient: await randomSigner.getAddress(),
      secondBridgeAddress: l1SharedBridge.address,
      secondBridgeValue: 0,
      secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "address"],
        [altTokenAddress, altTokenAmount, await randomSigner.getAddress()]
      ),
    });
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("ShB wrong msg len");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("ShB Incorrect message function selector");
  });
});
