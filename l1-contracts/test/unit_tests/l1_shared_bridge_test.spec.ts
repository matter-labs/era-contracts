import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import * as hardhat from "hardhat";
import type { L1AssetRouter, Bridgehub, L1NativeTokenVault, MockExecutorFacet } from "../../typechain";
import {
  L1AssetRouterFactory,
  BridgehubFactory,
  TestnetERC20TokenFactory,
  MockExecutorFacetFactory,
} from "../../typechain";
import { L1NativeTokenVaultFactory } from "../../typechain/L1NativeTokenVaultFactory";

import { getTokens } from "../../src.ts/deploy-token";
import { Action, facetCut } from "../../src.ts/diamondCut";
import { ethTestConfig } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";
import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";

import { getCallRevertReason, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DUMMY_MERKLE_PROOF_START } from "./utils";

describe("Shared Bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let bridgehub: Bridgehub;
  let l1NativeTokenVault: L1NativeTokenVault;
  let proxyAsMockExecutor: MockExecutorFacet;
  let l1SharedBridge: L1AssetRouter;
  let erc20TestToken: ethers.Contract;
  const mailboxFunctionSignature = "0x6c0960f9";
  const ERC20functionSignature = "0x11a2ccc1";
  const dummyProof = Array(9).fill(ethers.constants.HashZero);
  dummyProof[0] = DUMMY_MERKLE_PROOF_START;

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

    const mockExecutorFactory = await hardhat.ethers.getContractFactory("MockExecutorFacet");
    const mockExecutorContract = await mockExecutorFactory.deploy();
    const extraFacet = facetCut(mockExecutorContract.address, mockExecutorContract.interface, Action.Add, true);

    // note we can use initialTestnetDeploymentProcess so we don't go into deployment details here
    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [extraFacet]);

    chainId = deployer.chainId;
    // prepare the bridge

    proxyAsMockExecutor = MockExecutorFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
      mockExecutorContract.signer
    );

    await (
      await proxyAsMockExecutor.saveL2LogsRootHash(
        0,
        "0x0000000000000000000000000000000000000000000000000000000000000001"
      )
    ).wait();

    l1SharedBridge = L1AssetRouterFactory.connect(deployer.addresses.Bridges.SharedBridgeProxy, deployWallet);
    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    l1NativeTokenVault = L1NativeTokenVaultFactory.connect(
      deployer.addresses.Bridges.NativeTokenVaultProxy,
      deployWallet
    );

    const tokens = getTokens();

    const tokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    erc20TestToken = TestnetERC20TokenFactory.connect(tokenAddress, owner);

    await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits("10000", 18));
    await erc20TestToken
      .connect(randomSigner)
      .approve(l1NativeTokenVault.address, ethers.utils.parseUnits("10000", 18));

    await l1NativeTokenVault.registerToken(erc20TestToken.address);
  });

  it("Should not allow depositing zero erc20 amount", async () => {
    const mintValue = ethers.utils.parseEther("0.01");
    await (await erc20TestToken.connect(randomSigner).approve(l1NativeTokenVault.address, mintValue.mul(10))).wait();

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
    expect(revertReason).contains("EmptyDeposit");
  });

  it("Should deposit successfully legacy encoding", async () => {
    const amount = ethers.utils.parseEther("1");
    const mintValue = ethers.utils.parseEther("2");

    await erc20TestToken.connect(randomSigner).mint(await randomSigner.getAddress(), amount.mul(10));

    const balanceBefore = await erc20TestToken.balanceOf(await randomSigner.getAddress());
    const balanceNTVBefore = await erc20TestToken.balanceOf(l1NativeTokenVault.address);

    await (await erc20TestToken.connect(randomSigner).approve(l1NativeTokenVault.address, amount.mul(10))).wait();
    await bridgehub.connect(randomSigner).requestL2TransactionTwoBridges(
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
          [erc20TestToken.address, amount, await randomSigner.getAddress()]
        ),
      },
      { value: mintValue }
    );
    const balanceAfter = await erc20TestToken.balanceOf(await randomSigner.getAddress());
    expect(balanceAfter).equal(balanceBefore.sub(amount));
    const balanceNTVAfter = await erc20TestToken.balanceOf(l1NativeTokenVault.address);
    expect(balanceNTVAfter).equal(balanceNTVBefore.add(amount));
  });

  it("Should revert on finalizing a withdrawal with short message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, mailboxFunctionSignature, [ethers.constants.HashZero])
    );
    expect(revertReason).contains("L2WithdrawalMessageWrongLength");
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
          ethers.utils.hexConcat([ERC20functionSignature, l1SharedBridge.address, mailboxFunctionSignature]),
          [ethers.constants.HashZero]
        )
    );
    expect(revertReason).contains("L2WithdrawalMessageWrongLength");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).contains("InvalidSelector");
  });

  // it("Should deposit erc20 token successfully", async () => {
  //   const amount = ethers.utils.parseEther("0.001");
  //   const mintValue = ethers.utils.parseEther("0.002");
  //   await l1Weth.connect(randomSigner).deposit({ value: amount });
  //   await (await l1Weth.connect(randomSigner).approve(l1SharedBridge.address, amount)).wait();
  //   bridgehub.connect(randomSigner).requestL2TransactionTwoBridges(
  //     {
  //       chainId,
  //       mintValue,
  //       l2Value: amount,
  //       l2GasLimit: 1000000,
  //       l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  //       refundRecipient: ethers.constants.AddressZero,
  //       secondBridgeAddress: l1SharedBridge.address,
  //       secondBridgeValue: 0,
  //       secondBridgeCalldata: new ethers.utils.AbiCoder().encode(
  //         ["address", "uint256", "address"],
  //         [l1Weth.address, amount, await randomSigner.getAddress()]
  //       ),
  //     },
  //     { value: mintValue }
  //   );
  // });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, mailboxFunctionSignature, [ethers.constants.HashZero])
    );
    expect(revertReason).contains("L2WithdrawalMessageWrongLength");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(76), [ethers.constants.HashZero])
    );
    expect(revertReason).contains("InvalidSelector");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      mailboxFunctionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 10, 0, 0, l2ToL1message, dummyProof)
    );
    expect(revertReason).contains("BatchNotExecuted");
  });

  it("Should revert on finalizing a withdrawal with wrong length of proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      mailboxFunctionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).contains("MerklePathEmpty");
  });

  it("Should revert on finalizing a withdrawal with wrong proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      mailboxFunctionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, [dummyProof[0], dummyProof[1]])
    );
    expect(revertReason).contains("InvalidProof");
  });
});
