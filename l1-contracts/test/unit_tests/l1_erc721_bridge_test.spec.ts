import { expect } from "chai";
import { ethers } from "ethers";
import * as hardhat from "hardhat";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-web3/build/src/utils";
import type { IZkSync } from "zksync-web3/build/typechain";
import { IZkSyncFactory } from "zksync-web3/build/typechain";
import { Action, diamondCut, facetCut } from "../../src.ts/diamondCut";
import type { TestnetERC721Token } from "../../typechain";
import {
  DiamondInitFactory,
  GettersFacetFactory,
  MailboxFacetFactory,
  TestnetERC721TokenFactory,
} from "../../typechain";
import type { IL1Bridge } from "../../typechain/IL1Bridge";
import { IL1BridgeFactory } from "../../typechain/IL1BridgeFactory";
import { getCallRevertReason } from "./utils";

describe("L1ERC721Bridge tests", function () {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let l1ERC721Bridge: IL1Bridge;
  let erc721TestToken: TestnetERC721Token;
  let testnetERC721TokenContract: ethers.Contract;
  let l1Erc721BridgeContract: ethers.Contract;
  let zksyncContract: IZkSync;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    const gettersFactory = await hardhat.ethers.getContractFactory("GettersFacet");
    const gettersContract = await gettersFactory.deploy();
    const gettersFacet = GettersFacetFactory.connect(gettersContract.address, gettersContract.signer);

    const mailboxFactory = await hardhat.ethers.getContractFactory("MailboxFacet");
    const mailboxContract = await mailboxFactory.deploy();
    const mailboxFacet = MailboxFacetFactory.connect(mailboxContract.address, mailboxContract.signer);

    const diamondInitFactory = await hardhat.ethers.getContractFactory("DiamondInit");
    const diamondInitContract = await diamondInitFactory.deploy();
    const diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

    const dummyHash = new Uint8Array(32);
    dummyHash.set([1, 0, 0, 1]);
    const dummyAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));
    const diamondInitData = diamondInit.interface.encodeFunctionData("initialize", [
      {
        verifier: dummyAddress,
        governor: await owner.getAddress(),
        admin: await owner.getAddress(),
        genesisBatchHash: ethers.constants.HashZero,
        genesisIndexRepeatedStorageChanges: 0,
        genesisBatchCommitment: ethers.constants.HashZero,
        verifierParams: {
          recursionCircuitsSetVksHash: ethers.constants.HashZero,
          recursionLeafLevelVkHash: ethers.constants.HashZero,
          recursionNodeLevelVkHash: ethers.constants.HashZero,
        },
        zkPorterIsAvailable: false,
        l2BootloaderBytecodeHash: dummyHash,
        l2DefaultAccountBytecodeHash: dummyHash,
        priorityTxMaxGasLimit: 10000000,
        initialProtocolVersion: 0,
      },
    ]);

    const facetCuts = [
      facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
      facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true),
    ];

    const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

    const diamondProxyFactory = await hardhat.ethers.getContractFactory("DiamondProxy");
    const chainId = hardhat.network.config.chainId;
    const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

    const l1Erc721BridgeFactory = await hardhat.ethers.getContractFactory("L1ERC721Bridge");
    l1Erc721BridgeContract = await l1Erc721BridgeFactory.deploy(diamondProxyContract.address);
    l1ERC721Bridge = IL1BridgeFactory.connect(l1Erc721BridgeContract.address, l1Erc721BridgeContract.signer);

    const testnetERC721TokenFactory = await hardhat.ethers.getContractFactory("TestnetERC721Token");
    testnetERC721TokenContract = await testnetERC721TokenFactory.deploy("TestToken", "TT");
    erc721TestToken = TestnetERC721TokenFactory.connect(
      testnetERC721TokenContract.address,
      testnetERC721TokenContract.signer
    );

    await erc721TestToken.mint(await randomSigner.getAddress(), 123);
    await erc721TestToken
      .connect(randomSigner)
      .approve(l1Erc721BridgeContract.address, 123);

    // Exposing the methods of IZkSync to the diamond proxy
    zksyncContract = IZkSyncFactory.connect(diamondProxyContract.address, diamondProxyContract.provider);
  });

  it("Should deposit successfully", async () => {
    const depositorAddress = await randomSigner.getAddress();
    await depositERC721(
      l1ERC721Bridge.connect(randomSigner),
      zksyncContract,
      depositorAddress,
      testnetERC721TokenContract.address,
      ethers.BigNumber.from("123"),
      10000000
    );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC721Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("kk");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC721Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, ethers.utils.randomBytes(76), [])
    );
    expect(revertReason).equal("nt");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      testnetERC721TokenContract.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC721Bridge.connect(randomSigner).finalizeWithdrawal(10, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xx");
  });

  it("Should revert on finalizing a withdrawal with wrong length of proof", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      testnetERC721TokenContract.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC721Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xc");
  });

  it("Should revert on finalizing a withdrawal with wrong proof", async () => {
    const functionSignature = "0x11a2ccc1";
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      testnetERC721TokenContract.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC721Bridge
        .connect(randomSigner)
        .finalizeWithdrawal(0, 0, 0, l2ToL1message, Array(9).fill(ethers.constants.HashZero))
    );
    expect(revertReason).equal("nq");
  });
});

async function depositERC721(
  bridge: IL1Bridge,
  zksyncContract: IZkSync,
  l2Receiver: string,
  l1Token: string,
  tokenId: ethers.BigNumber,
  l2GasLimit: number,
  l2RefundRecipient = ethers.constants.AddressZero
) {
  const gasPrice = await bridge.provider.getGasPrice();
  const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
  const neededValue = await zksyncContract.l2TransactionBaseCost(gasPrice, l2GasLimit, gasPerPubdata);

  await bridge.deposit(
    l2Receiver,
    l1Token,
    tokenId,
    l2GasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
    l2RefundRecipient,
    {
      value: neededValue,
    }
  );
}
