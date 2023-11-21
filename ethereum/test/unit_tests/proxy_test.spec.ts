import { expect } from "chai";
import * as ethers from "ethers";
import * as hardhat from "hardhat";
import { Action, facetCut, diamondCut, getAllSelectors } from "../../src.ts/diamondCut";
import type {
  DiamondProxy,
  DiamondProxyTest,
  AdminFacet,
  GettersFacet,
  MailboxFacet,
  DiamondInit,
} from "../../typechain";
import {
  DiamondProxyFactory,
  DiamondProxyTestFactory,
  AdminFacetFactory,
  GettersFacetFactory,
  MailboxFacetFactory,
  DiamondInitFactory,
  TestnetERC20TokenFactory,
} from "../../typechain";
import { defaultFeeParams, getCallRevertReason } from "./utils";

describe("Diamond proxy tests", function () {
  let proxy: DiamondProxy;
  let diamondInit: DiamondInit;
  let adminFacet: AdminFacet;
  let gettersFacet: GettersFacet;
  let mailboxFacet: MailboxFacet;
  let diamondProxyTest: DiamondProxyTest;
  let governor: ethers.Signer;
  let governorAddress: string;

  before(async () => {
    [governor] = await hardhat.ethers.getSigners();
    governorAddress = await governor.getAddress();

    const diamondInitFactory = await hardhat.ethers.getContractFactory("DiamondInit");
    const diamondInitContract = await diamondInitFactory.deploy();
    diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

    const adminFactory = await hardhat.ethers.getContractFactory("AdminFacet");
    const adminContract = await adminFactory.deploy();
    adminFacet = AdminFacetFactory.connect(adminContract.address, adminContract.signer);

    const gettersFacetFactory = await hardhat.ethers.getContractFactory("GettersFacet");
    const gettersFacetContract = await gettersFacetFactory.deploy();
    gettersFacet = GettersFacetFactory.connect(gettersFacetContract.address, gettersFacetContract.signer);

    const mailboxFacetFactory = await hardhat.ethers.getContractFactory("MailboxFacet");
    const mailboxFacetContract = await mailboxFacetFactory.deploy();
    mailboxFacet = MailboxFacetFactory.connect(mailboxFacetContract.address, mailboxFacetContract.signer);

    const diamondProxyTestFactory = await hardhat.ethers.getContractFactory("DiamondProxyTest");
    const diamondProxyTestContract = await diamondProxyTestFactory.deploy();
    diamondProxyTest = DiamondProxyTestFactory.connect(
      diamondProxyTestContract.address,
      diamondProxyTestContract.signer
    );

    const facetCuts = [
      facetCut(adminFacet.address, adminFacet.interface, Action.Add, false),
      facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
      facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true),
    ];

    const dummyVerifierParams = {
      recursionNodeLevelVkHash: ethers.constants.HashZero,
      recursionLeafLevelVkHash: ethers.constants.HashZero,
      recursionCircuitsSetVksHash: ethers.constants.HashZero,
    };
    const diamondInitCalldata = diamondInit.interface.encodeFunctionData("initialize", [
      {
        verifier: "0x03752D8252d67f99888E741E3fB642803B29B155",
        governor: governorAddress,
        admin: governorAddress,
        genesisBatchHash: "0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21",
        genesisIndexRepeatedStorageChanges: 0,
        genesisBatchCommitment: ethers.constants.HashZero,
        verifierParams: dummyVerifierParams,
        zkPorterIsAvailable: false,
        l2BootloaderBytecodeHash: "0x0100000000000000000000000000000000000000000000000000000000000000",
        l2DefaultAccountBytecodeHash: "0x0100000000000000000000000000000000000000000000000000000000000000",
        priorityTxMaxGasLimit: 500000,
        initialProtocolVersion: 0,
        feeParams: defaultFeeParams(),
      },
    ]);

    const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitCalldata);

    const proxyFactory = await hardhat.ethers.getContractFactory("DiamondProxy");
    const chainId = hardhat.network.config.chainId;
    const proxyContract = await proxyFactory.deploy(chainId, diamondCutData);
    proxy = DiamondProxyFactory.connect(proxyContract.address, proxyContract.signer);
  });

  it("check added selectors", async () => {
    const proxyAsGettersFacet = GettersFacetFactory.connect(proxy.address, proxy.signer);

    const dummyFacetSelectors = getAllSelectors(gettersFacet.interface);
    for (const selector of dummyFacetSelectors) {
      const addr = await proxyAsGettersFacet.facetAddress(selector);
      const isFreezable = await proxyAsGettersFacet.isFunctionFreezable(selector);
      expect(addr).equal(gettersFacet.address);
      expect(isFreezable).equal(false);
    }

    const diamondCutSelectors = getAllSelectors(adminFacet.interface);
    for (const selector of diamondCutSelectors) {
      const addr = await proxyAsGettersFacet.facetAddress(selector);
      const isFreezable = await proxyAsGettersFacet.isFunctionFreezable(selector);
      expect(addr).equal(adminFacet.address);
      expect(isFreezable).equal(false);
    }
  });

  it("check that proxy reject non-added selector", async () => {
    const proxyAsERC20 = TestnetERC20TokenFactory.connect(proxy.address, proxy.signer);

    const revertReason = await getCallRevertReason(proxyAsERC20.transfer(proxyAsERC20.address, 0));
    expect(revertReason).equal("F");
  });

  it("check that proxy reject data with no selector", async () => {
    const dataWithoutSelector = "0x1122";

    const revertReason = await getCallRevertReason(proxy.fallback({ data: dataWithoutSelector }));
    expect(revertReason).equal("Ut");
  });

  it("should freeze the diamond storage", async () => {
    const proxyAsGettersFacet = GettersFacetFactory.connect(proxy.address, proxy.signer);

    const diamondProxyTestCalldata = diamondProxyTest.interface.encodeFunctionData("setFreezability", [true]);
    const diamondCutInitData = diamondCut([], diamondProxyTest.address, diamondProxyTestCalldata);

    const adminFacetExecuteCalldata = adminFacet.interface.encodeFunctionData("executeUpgrade", [diamondCutInitData]);
    await proxy.fallback({ data: adminFacetExecuteCalldata });

    expect(await proxyAsGettersFacet.isDiamondStorageFrozen()).equal(true);
  });

  it("should not revert on executing a proposal when diamondStorage is frozen", async () => {
    const facetCuts = [
      {
        facet: adminFacet.address,
        selectors: ["0x000000aa"],
        action: Action.Add,
        isFreezable: false,
      },
    ];
    const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, "0x");

    const adminFacetExecuteCalldata = adminFacet.interface.encodeFunctionData("executeUpgrade", [diamondCutData]);
    await proxy.fallback({ data: adminFacetExecuteCalldata });
  });

  it("should revert on calling a freezable faucet when diamondStorage is frozen", async () => {
    const mailboxFacetSelector0 = getAllSelectors(mailboxFacet.interface)[0];
    const revertReason = await getCallRevertReason(proxy.fallback({ data: mailboxFacetSelector0 }));
    expect(revertReason).equal("q1");
  });

  it("should be able to call an unfreezable faucet when diamondStorage is frozen", async () => {
    const gettersFacetSelector1 = getAllSelectors(gettersFacet.interface)[1];
    await proxy.fallback({ data: gettersFacetSelector1 });
  });
});
