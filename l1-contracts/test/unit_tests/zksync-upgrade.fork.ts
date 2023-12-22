import * as hardhat from "hardhat";
import { expect } from "chai";
import { facetCut, Action, getAllSelectors } from "../../src.ts/diamondCut";

import { 
  IOldDiamondCut__factory,
  IOldDiamondCut,
  IExecutor__factory,
  IExecutor,
  IGetters__factory,
  IGetters,
  IGovernance__factory,
  IGovernance,
  IMailbox__factory,
  IMailbox,
  IZkSync__factory,
  IZkSync,
} from "../../typechain-types";

import { ethers } from "ethers";

// TODO: change to the mainet config
const DIAMOND_PROXY_ADDRESS = "0x1908e2BF4a88F91E4eF0DC72f02b8Ea36BEa2319";

describe("Diamond proxy upgrade fork test", function () {
  let governor: ethers.Signer;
  let diamondProxy: IZkSync;

  let newDiamondCutFacet: IOldDiamondCut;
  let newExecutorFacet: IExecutor;
  let newGettersFacet: IGetters;
  let newGovernanceFacet: IGovernance;
  let newMailboxFacet: IMailbox;

  let diamondCutData;

  before(async () => {
    const signers = await hardhat.ethers.getSigners();
    diamondProxy = IZkSync__factory.connect(DIAMOND_PROXY_ADDRESS, signers[0]);
    const governorAddress = await diamondProxy.getGovernor();

    await hardhat.network.provider.request({ method: "hardhat_impersonateAccount", params: [governorAddress] });
    governor = await hardhat.ethers.getSigner(governorAddress);

    await hardhat.network.provider.send("hardhat_setBalance", [governorAddress, "0xfffffffffffffffff"]);

    const diamondCutFacetFactory = await hardhat.ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await diamondCutFacetFactory.deploy();
    newDiamondCutFacet = IOldDiamondCut__factory.connect(await diamondCutFacet.getAddress(), diamondCutFacet.runner);

    const executorFacetFactory = await hardhat.ethers.getContractFactory("ExecutorFacet");
    const executorFacet = await executorFacetFactory.deploy();
    newExecutorFacet = IExecutor__factory.connect(executorFacet.address, executorFacet.signer);

    const gettersFacetFactory = await hardhat.ethers.getContractFactory("GettersFacet");
    const gettersFacet = await gettersFacetFactory.deploy();
    newGettersFacet = IGetters__factory.connect(gettersFacet.address, gettersFacet.signer);

    const governanceFacetFactory = await hardhat.ethers.getContractFactory("GovernanceFacet");
    const governanceFacet = await governanceFacetFactory.deploy();
    newGovernanceFacet = IGovernance__factory.connect(await governanceFacet.getAddress(), governanceFacet.runner);

    const mailboxFacetFactory = await hardhat.ethers.getContractFactory("MailboxFacet");
    const mailboxFacet = await mailboxFacetFactory.deploy();
    newMailboxFacet = IMailbox__factory.connect(mailboxFacet.address, mailboxFacet.signer);

    // If the upgrade is already running, then cancel it to start upgrading over.
    const currentUpgradeStatus = await diamondProxy.getUpgradeProposalState();
    if (currentUpgradeStatus != 0) {
      const upgradeProposalHash = await diamondProxy.getProposedUpgradeHash();
      await diamondProxy.connect(governorAddress).cancelUpgradeProposal(upgradeProposalHash);
    }

    // Prepare diamond cut for upgrade
    let facetCuts;
    {
      const getters = await hardhat.ethers.getContractAt("GettersFacet", newGettersFacet.address);
      const diamondCutFacet = await hardhat.ethers.getContractAt("DiamondCutFacet", newDiamondCutFacet.address);
      const executor = await hardhat.ethers.getContractAt("ExecutorFacet", newExecutorFacet.address);
      const governance = await hardhat.ethers.getContractAt("GovernanceFacet", newGovernanceFacet.address);
      const mailbox = await hardhat.ethers.getContractAt("MailboxFacet", newMailboxFacet.address);

      const oldFacets = await diamondProxy.facets();
      const selectorsToRemove = [];
      for (let i = 0; i < oldFacets.length; ++i) {
        selectorsToRemove.push(...oldFacets[i].selectors);
      }

      facetCuts = [
        // Remove old facets
        {
          facet: ethers.ZeroAddress,
          selectors: selectorsToRemove,
          action: Action.Remove,
          isFreezable: false,
        },
        // Add new facets
        facetCut(await diamondCutFacet.getAddress(), diamondCutFacet.interface, Action.Add, false),
        facetCut(getters.address, getters.interface, Action.Add, false),
        facetCut(mailbox.address, mailbox.interface, Action.Add, true),
        facetCut(executor.address, executor.interface, Action.Add, true),
        facetCut(await governance.getAddress(), governance.interface, Action.Add, true),
      ];
    }
    diamondCutData = {
      facetCuts,
      initAddress: ethers.ZeroAddress,
      initCalldata: [],
    };
  });

  it("should start upgrade", async () => {
    const upgradeStatusBefore = await diamondProxy.getUpgradeProposalState();

    const expectedProposalId = await diamondProxy.getCurrentProposalId();
    await diamondProxy.connect(governor).proposeTransparentUpgrade(diamondCutData, expectedProposalId.add(1));

    const upgradeStatusAfter = await diamondProxy.getUpgradeProposalState();

    expect(upgradeStatusBefore).eq(0);
    expect(upgradeStatusAfter).eq(1);
  });

  it("should finish upgrade", async () => {
    const upgradeStatusBefore = await diamondProxy.getUpgradeProposalState();
    await diamondProxy.connect(governor).executeUpgrade(diamondCutData, ethers.ZeroHash);
    const upgradeStatusAfter = await diamondProxy.getUpgradeProposalState();

    expect(upgradeStatusBefore).eq(1);
    expect(upgradeStatusAfter).eq(0);
  });

  it("should start second upgrade", async () => {
    const upgradeStatusBefore = await diamondProxy.getUpgradeProposalState();

    const expectedProposalId = await diamondProxy.getCurrentProposalId();
    await diamondProxy.connect(governor).proposeTransparentUpgrade(diamondCutData, expectedProposalId.add(1));

    const upgradeStatusAfter = await diamondProxy.getUpgradeProposalState();

    expect(upgradeStatusBefore).eq(0);
    expect(upgradeStatusAfter).eq(1);
  });

  it("should finish second upgrade", async () => {
    const upgradeStatusBefore = await diamondProxy.getUpgradeProposalState();
    await diamondProxy.connect(governor).executeUpgrade(diamondCutData, ethers.ZeroHash);
    const upgradeStatusAfter = await diamondProxy.getUpgradeProposalState();

    expect(upgradeStatusBefore).eq(1);
    expect(upgradeStatusAfter).eq(0);
  });

  it("check getters functions", async () => {
    const governorAddr = await diamondProxy.getGovernor();
    expect(governorAddr).to.be.eq(await governor.getAddress());

    const isFrozen = await diamondProxy.isDiamondStorageFrozen();
    expect(isFrozen).to.be.eq(false);

    const getters = await hardhat.ethers.getContractAt("GettersFacet", newGettersFacet.address);
    const diamondCutFacet = await hardhat.ethers.getContractAt("DiamondCutFacet", newDiamondCutFacet.address);
    const executor = await hardhat.ethers.getContractAt("ExecutorFacet", newExecutorFacet.address);
    const governance = await hardhat.ethers.getContractAt("GovernanceFacet", newGovernanceFacet.address);
    const mailbox = await hardhat.ethers.getContractAt("MailboxFacet", newMailboxFacet.address);

    const facets = [...(await await diamondProxy.facets())].sort();
    const expectedFacets = [
      [newDiamondCutFacet.address, getAllSelectors(diamondCutFacet.interface)],
      [newExecutorFacet.address, getAllSelectors(executor.interface)],
      [newGettersFacet.address, getAllSelectors(getters.interface)],
      [newGovernanceFacet.address, getAllSelectors(governance.interface)],
      [newMailboxFacet.address, getAllSelectors(mailbox.interface)],
    ].sort();
    expect(expectedFacets).to.be.eql(facets);
  });
});
