import { expect } from "chai";
import { ethers } from "ethers";
import * as hardhat from "hardhat";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-ethers/build/src/utils";
import type { IZkSync } from "zksync-ethers/build/typechain";
import { IZkSync__factory } from "zksync-ethers/build/typechain";
import { Action, diamondCut, facetCut } from "../../src.ts/diamondCut";
import type { AllowList, L1ERC20Bridge, TestnetERC20Token } from "../../typechain-types";
import {
  AllowList__factory,
  DiamondInit__factory,
  GettersFacet__factory,
  MailboxFacet__factory,
  TestnetERC20Token__factory,
} from "../../typechain-types";
import type { IL1Bridge } from "../../typechain-types";
import { IL1Bridge__factory } from "../../typechain-types";
import { AccessMode, getCallRevertReason } from "./utils";

describe("L1ERC20Bridge tests", function () {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let allowList: AllowList;
  let l1ERC20Bridge: IL1Bridge;
  let erc20TestToken: TestnetERC20Token;
  let testnetERC20TokenContract: TestnetERC20Token;
  let l1Erc20BridgeContract: L1ERC20Bridge;
  let zksyncContract: IZkSync;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    const gettersFactory = await hardhat.ethers.getContractFactory("GettersFacet");
    const gettersContract = await gettersFactory.deploy();
    const gettersFacet = GettersFacet__factory.connect(await gettersContract.getAddress(), gettersContract.runner);

    const mailboxFactory = await hardhat.ethers.getContractFactory("MailboxFacet");
    const mailboxContract = await mailboxFactory.deploy();
    const mailboxFacet = MailboxFacet__factory.connect(await mailboxContract.getAddress(), mailboxContract.runner);

    const allowListFactory = await hardhat.ethers.getContractFactory("AllowList");
    const allowListContract = await allowListFactory.deploy(owner);
    allowList = AllowList__factory.connect(await allowListContract.getAddress(), allowListContract.runner);

    const diamondInitFactory = await hardhat.ethers.getContractFactory("DiamondInit");
    const diamondInitContract = await diamondInitFactory.deploy();
    const diamondInit = DiamondInit__factory.connect(await diamondInitContract.getAddress(), diamondInitContract.runner);

    const dummyHash = new Uint8Array(32);
    dummyHash.set([1, 0, 0, 1]);
    const dummyAddress = ethers.hexlify(ethers.randomBytes(20));
    const diamondInitData = diamondInit.interface.encodeFunctionData("initialize", [
      {
        verifier: dummyAddress,
        governor: await owner.getAddress(),
        admin: await owner.getAddress(),
        genesisBatchHash: ethers.ZeroHash,
        genesisIndexRepeatedStorageChanges: 0,
        genesisBatchCommitment: ethers.ZeroHash,
        allowList: allowList.getAddress(),
        verifierParams: {
          recursionCircuitsSetVksHash: ethers.ZeroHash,
          recursionLeafLevelVkHash: ethers.ZeroHash,
          recursionNodeLevelVkHash: ethers.ZeroHash,
        },
        zkPorterIsAvailable: false,
        l2BootloaderBytecodeHash: dummyHash,
        l2DefaultAccountBytecodeHash: dummyHash,
        priorityTxMaxGasLimit: 10000000,
        initialProtocolVersion: 0,
      },
    ]);

    const facetCuts = [
      facetCut(await gettersFacet.getAddress(), gettersFacet.interface, Action.Add, false),
      facetCut(await mailboxFacet.getAddress(), mailboxFacet.interface, Action.Add, true),
    ];

    const diamondCutData = diamondCut(facetCuts, await diamondInit.getAddress(), diamondInitData);

    const diamondProxyFactory = await hardhat.ethers.getContractFactory("DiamondProxy");
    const chainId = hardhat.network.config.chainId;
    const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

    const l1Erc20BridgeFactory = await hardhat.ethers.getContractFactory("L1ERC20Bridge");
    l1Erc20BridgeContract = await l1Erc20BridgeFactory.deploy(diamondProxyContract.getAddress(),await allowListContract.getAddress());
    l1ERC20Bridge = IL1Bridge__factory.connect(await l1Erc20BridgeContract.getAddress(), l1Erc20BridgeContract.runner);

    const testnetERC20TokenFactory = await hardhat.ethers.getContractFactory("TestnetERC20Token");
    testnetERC20TokenContract = await testnetERC20TokenFactory.deploy("TestToken", "TT", 18);
    erc20TestToken = TestnetERC20Token__factory.connect(
      await testnetERC20TokenContract.getAddress(),
      testnetERC20TokenContract.runner
    );

    await erc20TestToken.mint(await randomSigner.getAddress(), ethers.parseUnits("10000", 18));
    await erc20TestToken
      .connect(randomSigner)
      .approve(l1Erc20BridgeContract.getAddress(), ethers.parseUnits("10000", 18));

    await (await allowList.setAccessMode(diamondProxyContract.getAddress(), AccessMode.Public)).wait();

    // Exposing the methods of IZkSync to the diamond proxy
    zksyncContract = IZkSync__factory.connect(await diamondProxyContract.getAddress(), diamondProxyContract.runner);
  });

  it("Should not allow an un-whitelisted address to deposit", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .deposit(
          await randomSigner.getAddress(),
          testnetERC20TokenContract.getAddress(),
          0,
          0,
          0,
          ethers.ZeroAddress
        )
    );
    expect(revertReason).equal("nr");

    await (await allowList.setAccessMode(await l1Erc20BridgeContract.getAddress(), AccessMode.Public)).wait();
  });

  it("Should not allow depositing zero amount", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .deposit(
          await randomSigner.getAddress(),
          await testnetERC20TokenContract.getAddress(),
          0,
          0,
          0,
          ethers.ZeroAddress
        )
    );
    expect(revertReason).equal("2T");
  });

  it("Should deposit successfully", async () => {
    const depositorAddress = await randomSigner.getAddress();
    await depositERC20(
      l1ERC20Bridge.connect(randomSigner),
      zksyncContract,
      depositorAddress,
      await testnetERC20TokenContract.getAddress(),
      ethers.parseUnits("800", 18),
      10000000
    );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("kk");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, ethers.randomBytes(76), [])
    );
    expect(revertReason).equal("nt");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.concat([
      functionSignature,
      l1Receiver,
      await testnetERC20TokenContract.getAddress(),
      ethers.ZeroHash,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(10, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xx");
  });

  it("Should revert on finalizing a withdrawal with wrong length of proof", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.concat([
      functionSignature,
      l1Receiver,
      await testnetERC20TokenContract.getAddress(),
      ethers.ZeroHash,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xc");
  });

  it("Should revert on finalizing a withdrawal with wrong proof", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.concat([
      functionSignature,
      l1Receiver,
      await testnetERC20TokenContract.getAddress(),
      ethers.ZeroHash,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .finalizeWithdrawal(0, 0, 0, l2ToL1message, Array(9).fill(ethers.ZeroHash))
    );
    expect(revertReason).equal("nq");
  });
});

async function depositERC20(
  bridge: IL1Bridge,
  zksyncContract: IZkSync,
  l2Receiver: string,
  l1Token: string,
  amount: bigint,
  l2GasLimit: number,
  l2RefundRecipient = ethers.ZeroAddress
) {
  const gasPrice = (await bridge.runner.provider.getFeeData()).gasPrice;
  const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
  const neededValue = await zksyncContract.l2TransactionBaseCost(gasPrice, l2GasLimit, gasPerPubdata);

  await bridge.deposit(
    l2Receiver,
    l1Token,
    amount,
    l2GasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
    l2RefundRecipient,
    {
      value: neededValue,
    }
  );
}
