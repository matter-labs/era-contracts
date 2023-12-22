import { expect } from "chai";
import { ethers, Interface } from "ethers";
import * as hardhat from "hardhat";
import { hashL2Bytecode } from "../../scripts/utils";
import { Action, diamondCut, facetCut } from "../../src.ts/diamondCut";
import type { AllowList, L1WethBridge, WETH9 } from "../../typechain-types";
import {
  AllowList__factory,
  DiamondInit__factory,
  GettersFacet__factory,
  L1WethBridge__factory,
  MailboxFacet__factory,
  WETH9__factory,
} from "../../typechain-types";
import type { IZkSync } from "../../typechain-types";
import { AccessMode, getCallRevertReason } from "./utils";

import type { Address } from "zksync-ethers/build/src/types";

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export async function create2DeployFromL1(
  zkSync: IZkSync,
  walletAddress: Address,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish
) {
  const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);
  const gasPrice = (await zkSync.runner.provider.getFeeData()).gasPrice;
  const expectedCost = await zkSync.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

  await zkSync.requestL2Transaction(
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    0,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    [bytecode],
    walletAddress,
    { value: expectedCost, gasPrice }
  );
}

describe("WETH Bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let allowList: AllowList;
  let bridgeProxy: L1WethBridge;
  let l1Weth: WETH9;
  const functionSignature = "0x6c0960f9";

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    // prepare the diamond

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
        allowList: await allowList.getAddress(),
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

    await (await allowList.setAccessMode(await diamondProxyContract.getAddress(), AccessMode.Public)).wait();

    l1Weth = WETH9__factory.connect(await (await (await hardhat.ethers.getContractFactory("WETH9")).deploy()).getAddress(), owner);

    // prepare the bridge

    const bridge = await (
      await hardhat.ethers.getContractFactory("L1WethBridge")
    ).deploy(l1Weth.getAddress(), await  diamondProxyContract.getAddress(), await allowListContract.getAddress());

    // we don't test L2, so it is ok to give garbage factory deps and L2 address
    const garbageBytecode = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const garbageAddress = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F";

    const bridgeInitData = bridge.interface.encodeFunctionData("initialize", [
      [garbageBytecode, garbageBytecode],
      garbageAddress,
      await owner.getAddress(),
      ethers.WeiPerEther,
      ethers.WeiPerEther,
    ]);
    const _bridgeProxy = await (
      await hardhat.ethers.getContractFactory("ERC1967Proxy")
    ).deploy(bridge.getAddress(), bridgeInitData, { value: ethers.WeiPerEther*2n });

    bridgeProxy = L1WethBridge__factory.connect(await _bridgeProxy.getAddress(), _bridgeProxy.runner);
  });

  it("Should not allow an un-whitelisted address to deposit", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .deposit(await randomSigner.getAddress(), ethers.ZeroAddress, 0, 0, 0, ethers.ZeroAddress)
    );

    expect(revertReason).equal("nr");

    // This is only so the following tests don't need whitelisting
    await (await allowList.setAccessMode(bridgeProxy.getAddress(), AccessMode.Public)).wait();
  });

  it("Should not allow depositing zero WETH", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .deposit(
          await randomSigner.getAddress(),
          await bridgeProxy.l1WethAddress(),
          0,
          0,
          0,
          ethers.ZeroAddress
        )
    );

    expect(revertReason).equal("Amount cannot be zero");
  });

  it("Should deposit successfully", async () => {
    await l1Weth.connect(randomSigner).deposit({ value: 100 });
    await (await l1Weth.connect(randomSigner).approve(bridgeProxy.getAddress(), 100)).wait();
    await bridgeProxy
      .connect(randomSigner)
      .deposit(
        await randomSigner.getAddress(),
        l1Weth.getAddress(),
        100,
        1000000,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        await randomSigner.getAddress(),
        { value: ethers.WeiPerEther }
      );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy.connect(randomSigner).finalizeWithdrawal(0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("Incorrect ETH message with additional data length");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy.connect(randomSigner).finalizeWithdrawal(0, 0, 0, ethers.randomBytes(96), [])
    );
    expect(revertReason).equal("Incorrect ETH message function selector");
  });

  it("Should revert on finalizing a withdrawal with wrong receiver", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .finalizeWithdrawal(0, 0, 0, ethers.concat([functionSignature, ethers.randomBytes(92)]), [])
    );
    expect(revertReason).equal("Wrong L1 ETH withdraw receiver");
  });

  it("Should revert on finalizing a withdrawal with wrong L2 sender", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .finalizeWithdrawal(
          0,
          0,
          0,
          ethers.concat([
            functionSignature,
            await bridgeProxy.getAddress(),
            ethers.randomBytes(32),
            ethers.randomBytes(40),
          ]),
          []
        )
    );
    expect(revertReason).equal("The withdrawal was not initiated by L2 bridge");
  });
});
