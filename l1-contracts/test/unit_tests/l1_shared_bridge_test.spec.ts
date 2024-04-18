import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import { Interface } from "ethers/lib/utils";
import * as hardhat from "hardhat";
import type { L1SharedBridge, Bridgehub, WETH9 } from "../../typechain";
import { L1SharedBridgeFactory, BridgehubFactory, WETH9Factory, TestnetERC20TokenFactory } from "../../typechain";

import { getTokens } from "../../src.ts/deploy-token";
import { ADDRESS_ONE, ethTestConfig } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";
import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";

import { getCallRevertReason, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

describe("Shared Bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let bridgehub: Bridgehub;
  let l1SharedBridge: L1SharedBridge;
  let l1SharedBridgeInterface: Interface;
  let l1Weth: WETH9;
  let erc20TestToken: ethers.Contract;
  const functionSignature = "0x6c0960f9";
  const ERC20functionSignature = "0x11a2ccc1";

  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

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

    // note we can use initialTestnetDeploymentProcess so we don't go into deployment details here
    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, []);

    chainId = deployer.chainId;
    // prepare the bridge

    l1SharedBridge = L1SharedBridgeFactory.connect(deployer.addresses.Bridges.SharedBridgeProxy, deployWallet);
    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    l1SharedBridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1SharedBridge").abi);

    const tokens = getTokens();
    const l1WethTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    l1Weth = WETH9Factory.connect(l1WethTokenAddress, owner);

    const tokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    erc20TestToken = TestnetERC20TokenFactory.connect(tokenAddress, owner);

    await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits("10000", 18));
    await erc20TestToken.connect(randomSigner).approve(l1SharedBridge.address, ethers.utils.parseUnits("10000", 18));
  });

  it("Check should initialize through governance", async () => {
    const upgradeCall = l1SharedBridgeInterface.encodeFunctionData("initializeChainGovernance(uint256,address)", [
      chainId,
      ADDRESS_ONE,
    ]);
    const txHash = await deployer.executeUpgrade(l1SharedBridge.address, 0, upgradeCall);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Should not allow depositing zero erc20 amount", async () => {
    const mintValue = ethers.utils.parseEther("0.01");
    const revertReason = await getCallRevertReason(
      bridgehub.connect(randomSigner).requestL2TransactionTwoBridges(
        {
          chainId,
          mintValue,
          l2Value: 0,
          l2GasLimit: 0,
          l2GasPerPubdataByteLimit: 0,
          refundRecipient: ethers.constants.AddressZero,
          secondBridgeAddress: l1SharedBridge.address,
          secondBridgeValue: 0,
          secondBridgeCalldata: new ethers.utils.AbiCoder().encode(
            ["address", "uint256", "address"],
            [erc20TestToken.address, 0, await randomSigner.getAddress()]
          ),
        },
        { value: mintValue }
      )
    );
    expect(revertReason).equal("6T");
  });

  it("Should deposit successfully", async () => {
    const amount = ethers.utils.parseEther("1");
    const mintValue = ethers.utils.parseEther("2");
    await l1Weth.connect(randomSigner).deposit({ value: amount });
    await (await l1Weth.connect(randomSigner).approve(l1SharedBridge.address, amount)).wait();
    bridgehub.connect(randomSigner).requestL2TransactionTwoBridges(
      {
        chainId,
        mintValue,
        l2Value: amount,
        l2GasLimit: 1000000,
        l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        refundRecipient: ethers.constants.AddressZero,
        secondBridgeAddress: l1SharedBridge.address,
        secondBridgeValue: 0,
        secondBridgeCalldata: new ethers.utils.AbiCoder().encode(
          ["address", "uint256", "address"],
          [l1Weth.address, amount, await randomSigner.getAddress()]
        ),
      },
      { value: mintValue }
    );
  });

  it("Should revert on finalizing a withdrawal with short message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [ethers.constants.HashZero])
    );
    expect(revertReason).equal("ShB wrong msg len");
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(
          chainId,
          0,
          0,
          0,
          ethers.utils.hexConcat([ERC20functionSignature, l1SharedBridge.address, ethers.utils.randomBytes(72 + 4)]),
          [ethers.constants.HashZero]
        )
    );
    expect(revertReason).equal("ShB wrong msg len 2");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("ShB Incorrect message function selector");
  });

  it("Should deposit erc20 token successfully", async () => {
    const amount = ethers.utils.parseEther("0.001");
    const mintValue = ethers.utils.parseEther("0.002");
    await l1Weth.connect(randomSigner).deposit({ value: amount });
    await (await l1Weth.connect(randomSigner).approve(l1SharedBridge.address, amount)).wait();
    bridgehub.connect(randomSigner).requestL2TransactionTwoBridges(
      {
        chainId,
        mintValue,
        l2Value: amount,
        l2GasLimit: 1000000,
        l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        refundRecipient: ethers.constants.AddressZero,
        secondBridgeAddress: l1SharedBridge.address,
        secondBridgeValue: 0,
        secondBridgeCalldata: new ethers.utils.AbiCoder().encode(
          ["address", "uint256", "address"],
          [l1Weth.address, amount, await randomSigner.getAddress()]
        ),
      },
      { value: mintValue }
    );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [ethers.constants.HashZero])
    );
    expect(revertReason).equal("ShB wrong msg len");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(76), [ethers.constants.HashZero])
    );
    expect(revertReason).equal("ShB Incorrect message function selector");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 10, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xx");
  });

  it("Should revert on finalizing a withdrawal with wrong length of proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xc");
  });

  it("Should revert on finalizing a withdrawal with wrong proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, Array(9).fill(ethers.constants.HashZero))
    );
    expect(revertReason).equal("ShB withd w proof");
  });
});
