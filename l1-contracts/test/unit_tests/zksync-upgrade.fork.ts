import * as hardhat from "hardhat";
import { expect } from "chai";
import { facetCut, Action, getAllSelectors } from "../../src.ts/diamondCut";

import { IDiamondCutFactory } from "../../typechain/IDiamondCutFactory";
import type { IDiamondCut } from "../../typechain/IDiamondCut";
import { IExecutorFactory } from "../../typechain/IExecutorFactory";
import type { IExecutor } from "../../typechain/IExecutor";
import { IGettersFactory } from "../../typechain/IGettersFactory";
import type { IGetters } from "../../typechain/IGetters";
import { IGovernanceFactory } from "../../typechain/IGovernanceFactory";
import type { IGovernance } from "../../typechain/IGovernance";
import { IMailboxFactory } from "../../typechain/IMailboxFactory";
import type { IMailbox } from "../../typechain/IMailbox";
import { IBridgehubFactory } from "../../typechain/IBridgehubFactory";
import type { IBridgehub } from "../../typechain/IBridgehub";
import { ethers } from "ethers";

// TODO: change to the mainnet config
const DIAMOND_PROXY_ADDRESS = "0x1908e2BF4a88F91E4eF0DC72f02b8Ea36BEa2319";

describe("Diamond proxy upgrade fork test", function () {
  let governor: ethers.Signer;
  let diamondProxy: IBridgehub;

  let newDiamondCutFacet: IDiamondCut;
  let newExecutorFacet: IExecutor;
  let newGettersFacet: IGetters;
  let newGovernanceFacet: IGovernance;
  let newMailboxFacet: IMailbox;

  let diamondCutData;

  before(async () => {
    const signers = await hardhat.ethers.getSigners();
    diamondProxy = IBridgehubFactory.connect(DIAMOND_PROXY_ADDRESS, signers[0]);
    const governorAddress = await diamondProxy.getAdmin();

    await hardhat.network.provider.request({ method: "hardhat_impersonateAccount", params: [governorAddress] });
    governor = await hardhat.ethers.provider.getSigner(governorAddress);

    await hardhat.network.provider.send("hardhat_setBalance", [governorAddress, "0xfffffffffffffffff"]);

    const diamondCutFacetFactory = await hardhat.ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await diamondCutFacetFactory.deploy();
    newDiamondCutFacet = IDiamondCutFactory.connect(diamondCutFacet.address, diamondCutFacet.signer);

    const executorFacetFactory = await hardhat.ethers.getContractFactory("ExecutorFacet");
    const executorFacet = await executorFacetFactory.deploy();
    newExecutorFacet = IExecutorFactory.connect(executorFacet.address, executorFacet.signer);

    const gettersFacetFactory = await hardhat.ethers.getContractFactory("GettersFacet");
    const gettersFacet = await gettersFacetFactory.deploy();
    newGettersFacet = IGettersFactory.connect(gettersFacet.address, gettersFacet.signer);

    const governanceFacetFactory = await hardhat.ethers.getContractFactory("GovernanceFacet");
    const governanceFacet = await governanceFacetFactory.deploy();
    newGovernanceFacet = IGovernanceFactory.connect(governanceFacet.address, governanceFacet.signer);

    const mailboxFacetFactory = await hardhat.ethers.getContractFactory("Mailbox");
    const mailboxFacet = await mailboxFacetFactory.deploy();
    newMailboxFacet = IMailboxFactory.connect(mailboxFacet.address, mailboxFacet.signer);

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
          facet: ethers.constants.AddressZero,
          selectors: selectorsToRemove,
          action: Action.Remove,
          isFreezable: false,
        },
        // Add new facets
        facetCut(diamondCutFacet.address, diamondCutFacet.interface, Action.Add, false),
        facetCut(getters.address, getters.interface, Action.Add, false),
        facetCut(mailbox.address, mailbox.interface, Action.Add, true),
        facetCut(executor.address, executor.interface, Action.Add, true),
        facetCut(governance.address, governance.interface, Action.Add, true),
      ];
    }
    diamondCutData = {
      facetCuts,
      initAddress: ethers.constants.AddressZero,
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
    await diamondProxy.connect(governor).executeUpgrade(diamondCutData, ethers.constants.HashZero);
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
    await diamondProxy.connect(governor).executeUpgrade(diamondCutData, ethers.constants.HashZero);
    const upgradeStatusAfter = await diamondProxy.getUpgradeProposalState();

    expect(upgradeStatusBefore).eq(1);
    expect(upgradeStatusAfter).eq(0);
  });

  it("check getters functions", async () => {
    const governorAddr = await diamondProxy.getAdmin();
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
