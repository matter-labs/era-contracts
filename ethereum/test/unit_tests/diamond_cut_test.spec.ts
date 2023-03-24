import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { Action, facetCut, diamondCut, getAllSelectors } from '../../src.ts/diamondCut';
import {
    MailboxFacet,
    MailboxFacetFactory,
    DiamondCutTest,
    DiamondCutTestFactory,
    DiamondCutFacet,
    DiamondCutFacetFactory,
    ExecutorFacet,
    ExecutorFacetFactory,
    GettersFacet,
    GettersFacetFactory,
    DiamondProxy,
    DiamondInit,
    DiamondInitFactory,
    DiamondProxyFactory
} from '../../typechain';
import { getCallRevertReason } from './utils';
import * as ethers from 'ethers';

describe('Diamond proxy tests', function () {
    let diamondCutTest: DiamondCutTest;

    before(async () => {
        const contractFactory = await hardhat.ethers.getContractFactory('DiamondCutTest');
        const contract = await contractFactory.deploy();
        diamondCutTest = DiamondCutTestFactory.connect(contract.address, contract.signer);
    });

    describe('facetCuts', function () {
        let mailboxFacet: MailboxFacet;
        let gettersFacet: GettersFacet;
        let executorFacet1: ExecutorFacet;
        let executorFacet2: ExecutorFacet;

        before(async () => {
            const mailboxFactory = await hardhat.ethers.getContractFactory('MailboxFacet');
            const mailboxContract = await mailboxFactory.deploy();
            mailboxFacet = MailboxFacetFactory.connect(mailboxContract.address, mailboxContract.signer);

            const gettersFactory = await hardhat.ethers.getContractFactory('GettersFacet');
            const gettersContract = await gettersFactory.deploy();
            gettersFacet = GettersFacetFactory.connect(gettersContract.address, gettersContract.signer);

            const executorFactory = await hardhat.ethers.getContractFactory('ExecutorFacet');
            const executorContract1 = await executorFactory.deploy();
            const executorContract2 = await executorFactory.deploy();
            executorFacet1 = ExecutorFacetFactory.connect(executorContract1.address, executorContract1.signer);
            executorFacet2 = ExecutorFacetFactory.connect(executorContract2.address, executorContract2.signer);
        });

        it('should add facets for free selectors', async () => {
            const facetCuts = [
                facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, false),
                facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
                facetCut(executorFacet1.address, executorFacet1.interface, Action.Add, false)
            ];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');

            const numberOfFacetsBeforeAdd = (await diamondCutTest.facetAddresses()).length;
            await diamondCutTest.diamondCut(diamondCutData);
            const numberOfFacetsAfterAdd = (await diamondCutTest.facetAddresses()).length;

            expect(numberOfFacetsAfterAdd).equal(numberOfFacetsBeforeAdd + facetCuts.length);
        });

        it('should revert on add facet for occupied selector', async () => {
            const facetCuts = [facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('J');
        });

        it('should revert on add facet with zero address', async () => {
            const facetCuts = [facetCut(ethers.constants.AddressZero, mailboxFacet.interface, Action.Add, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('G');
        });

        it('should revert on replace facets for free selector', async () => {
            const facetCuts = [
                {
                    facet: mailboxFacet.address,
                    selectors: ['0x00000001'],
                    action: Action.Replace,
                    isFreezable: false
                }
            ];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('L');
        });

        it('should revert on remove facet for free selector', async () => {
            const facetCuts = [
                {
                    facet: mailboxFacet.address,
                    selectors: ['0x00000001'],
                    action: Action.Remove,
                    isFreezable: false
                }
            ];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('a1');
        });

        it('should replace facet for occupied selector', async () => {
            const facetCuts = [facetCut(executorFacet2.address, executorFacet2.interface, Action.Replace, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            await diamondCutTest.diamondCut(diamondCutData);
        });

        it('should remove facet for occupied selector', async () => {
            const facetCuts = [facetCut(ethers.constants.AddressZero, executorFacet2.interface, Action.Remove, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const numberOfFacetsBeforeRemove = (await diamondCutTest.facetAddresses()).length;
            await diamondCutTest.diamondCut(diamondCutData);
            const numberOfFacetsAfterRemove = (await diamondCutTest.facetAddresses()).length;

            expect(numberOfFacetsAfterRemove).equal(numberOfFacetsBeforeRemove - facetCuts.length);
        });

        it('should add facet after removing', async () => {
            const facetCuts = [facetCut(executorFacet2.address, executorFacet2.interface, Action.Add, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const numberOfFacetsBeforeAdd = (await diamondCutTest.facetAddresses()).length;
            await diamondCutTest.diamondCut(diamondCutData);
            const numberOfFacetsAfterAdd = (await diamondCutTest.facetAddresses()).length;

            expect(numberOfFacetsAfterAdd).equal(numberOfFacetsBeforeAdd + facetCuts.length);
        });

        it('should replace a selector faucet with itself', async () => {
            const facetCuts1 = [
                {
                    facet: '0x000000000000000000000000000000000000000a',
                    selectors: ['0x00000005'],
                    action: Action.Add,
                    isFreezable: true
                }
            ];
            const facetCuts2 = [
                {
                    facet: '0x000000000000000000000000000000000000000a',
                    selectors: ['0x00000005'],
                    action: Action.Replace,
                    isFreezable: false
                }
            ];
            const diamondCutData1 = diamondCut(facetCuts1, ethers.constants.AddressZero, '0x');
            await diamondCutTest.diamondCut(diamondCutData1);
            const numberOfFacetsAfterAdd = (await diamondCutTest.facetAddresses()).length;
            const diamondCutData2 = diamondCut(facetCuts2, ethers.constants.AddressZero, '0x');
            await diamondCutTest.diamondCut(diamondCutData2);
            const numberOfFacetsAfterReplace = (await diamondCutTest.facetAddresses()).length;
            expect(numberOfFacetsAfterAdd).equal(numberOfFacetsAfterReplace);
        });

        it('should revert on adding a faucet with different freezability', async () => {
            const facetCuts = [
                {
                    facet: mailboxFacet.address,
                    selectors: ['0x00000002'],
                    action: Action.Add,
                    isFreezable: true
                }
            ];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('J1');
        });

        it('should revert on replacing a faucet with different freezability', async () => {
            const facetCuts = [facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('J1');
        });

        it('should change the freezibility of a faucet', async () => {
            let facetCuts = [facetCut(ethers.constants.AddressZero, mailboxFacet.interface, Action.Remove, false)];
            let diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            await diamondCutTest.diamondCut(diamondCutData);
            facetCuts = [facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true)];
            diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            await diamondCutTest.diamondCut(diamondCutData);
        });
    });

    describe('initialization', function () {
        let revertFallbackAddress;
        let returnSomethingAddress;
        let EOA_Address;

        before(async () => {
            const contractFactoryRevertFallback = await hardhat.ethers.getContractFactory('RevertFallback');
            const contractRevertFallback = await contractFactoryRevertFallback.deploy();
            revertFallbackAddress = contractRevertFallback.address;

            const contractFactoryReturnSomething = await hardhat.ethers.getContractFactory('ReturnSomething');
            const contractReturnSomething = await contractFactoryReturnSomething.deploy();
            returnSomethingAddress = contractReturnSomething.address;

            const [signer] = await hardhat.ethers.getSigners();
            EOA_Address = signer.address;
        });

        it('should revert on delegatecall to failed contract', async () => {
            const diamondCutData = diamondCut([], revertFallbackAddress, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('I');
        });

        it('should revert on delegatecall to EOA', async () => {
            const diamondCutData = diamondCut([], EOA_Address, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('lp');
        });

        it('should revert on initializing diamondCut with zero-address and nonzero-data', async () => {
            const diamondCutData = diamondCut([], ethers.constants.AddressZero, '0x11');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('H');
        });

        it('should revert on delegatecall to a contract with wrong return', async () => {
            const diamondCutData = diamondCut([], returnSomethingAddress, '0x');
            const revertReason = await getCallRevertReason(diamondCutTest.diamondCut(diamondCutData));
            expect(revertReason).equal('lp1');
        });
    });

    describe('testing upgrade logic', function () {
        let proxy: DiamondProxy;
        let diamondInit: DiamondInit;
        let diamondCutFacet: DiamondCutFacet;
        let proxyAsDiamondCut: DiamondCutFacet;
        let gettersFacet: GettersFacet;
        let proxyAsGetters: GettersFacet;
        let governor, randomSigner: ethers.Signer;
        let governorAddress: string;

        before(async () => {
            [governor, randomSigner] = await hardhat.ethers.getSigners();
            governorAddress = await governor.getAddress();

            const diamondInitFactory = await hardhat.ethers.getContractFactory('DiamondInit');
            const diamondInitContract = await diamondInitFactory.deploy();
            diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

            const diamondCutFactory = await hardhat.ethers.getContractFactory('DiamondCutFacet');
            const diamondCutContract = await diamondCutFactory.deploy();
            diamondCutFacet = DiamondCutFacetFactory.connect(diamondCutContract.address, diamondCutContract.signer);

            const gettersFacetFactory = await hardhat.ethers.getContractFactory('GettersFacet');
            const gettersFacetContract = await gettersFacetFactory.deploy();
            gettersFacet = GettersFacetFactory.connect(gettersFacetContract.address, gettersFacetContract.signer);

            const facetCuts = [
                facetCut(diamondCutFacet.address, diamondCutFacet.interface, Action.Add, false),
                facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, true)
            ];
            const dummyVerifierParams = {
                recursionNodeLevelVkHash: ethers.constants.HashZero,
                recursionLeafLevelVkHash: ethers.constants.HashZero,
                recursionCircuitsSetVksHash: ethers.constants.HashZero
            };
            const diamondInitCalldata = diamondInit.interface.encodeFunctionData('initialize', [
                '0x03752D8252d67f99888E741E3fB642803B29B155',
                governorAddress,
                '0x02c775f0a90abf7a0e8043f2fdc38f0580ca9f9996a895d05a501bfeaa3b2e21',
                0,
                '0x0000000000000000000000000000000000000000000000000000000000000000',
                '0x70a0F165d6f8054d0d0CF8dFd4DD2005f0AF6B55',
                dummyVerifierParams,
                false,
                '0x0100000000000000000000000000000000000000000000000000000000000000',
                '0x0100000000000000000000000000000000000000000000000000000000000000',
                500000 // priority tx max L2 gas limit
            ]);

            const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitCalldata);

            const proxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
            const chainId = hardhat.network.config.chainId;
            const proxyContract = await proxyFactory.deploy(chainId, diamondCutData);
            proxy = DiamondProxyFactory.connect(proxyContract.address, proxyContract.signer);

            proxyAsDiamondCut = DiamondCutFacetFactory.connect(proxy.address, governor);
            proxyAsGetters = GettersFacetFactory.connect(proxy.address, governor);
        });

        it('should revert emergency freeze when unauthorized governor', async () => {
            const proxyAsDiamondCutByRandomSigner = DiamondCutFacetFactory.connect(proxy.address, randomSigner);
            const revertReason = await getCallRevertReason(proxyAsDiamondCutByRandomSigner.freezeDiamond());
            expect(revertReason).equal('1g');
        });

        it('should emergency freeze and unfreeze when authorized governor', async () => {
            await proxyAsDiamondCut.freezeDiamond();
            const doubleFreezeRevertReason = await getCallRevertReason(proxyAsDiamondCut.freezeDiamond());
            expect(doubleFreezeRevertReason).equal('a9');
            await proxyAsDiamondCut.unfreezeDiamond();
        });

        it('should revert on unfreezing when it is not freezed', async () => {
            const revertReason = await getCallRevertReason(proxyAsDiamondCut.unfreezeDiamond());
            expect(revertReason).equal('a7');
        });

        it('should revert on executing an unapproved proposal when diamondStorage is frozen', async () => {
            await proxyAsDiamondCut.freezeDiamond();

            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');

            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, 1);
            const notPossibleToExecuteRevertReason = await getCallRevertReason(
                proxyAsDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero)
            );

            expect(notPossibleToExecuteRevertReason).equal('f3');
            await proxyAsDiamondCut.unfreezeDiamond();
        });

        it('should revert on executing a proposal with different initAddress', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const proposedDiamondCutData = diamondCut(facetCuts, '0x0000000000000000000000000000000000000000', '0x');
            const executedDiamondCutData = diamondCut(facetCuts, '0x0000000000000000000000000000000000000001', '0x');

            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(proposedDiamondCutData, nextProposalId);
            const invalidInitAddressRevertReason = await getCallRevertReason(
                proxyAsDiamondCut.executeUpgrade(executedDiamondCutData, ethers.constants.HashZero)
            );

            expect(invalidInitAddressRevertReason).equal('a4');
            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });

        it('should revert on executing a proposal with different facetCut', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const invalidFacetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, false)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const invalidDiamondCutData = diamondCut(invalidFacetCuts, ethers.constants.AddressZero, '0x');

            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);
            const invalidFacetCutRevertReason = await getCallRevertReason(
                proxyAsDiamondCut.executeUpgrade(invalidDiamondCutData, ethers.constants.HashZero)
            );

            expect(invalidFacetCutRevertReason).equal('a4');
            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });

        it('should revert when canceling empty proposal', async () => {
            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            const revertReason = await getCallRevertReason(proxyAsDiamondCut.cancelUpgradeProposal(proposalHash));
            expect(revertReason).equal('a3');
        });

        it('should propose and execute diamond cut', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');

            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);
            await proxyAsDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);

            const gettersFacetToUpgradeSelectors = getAllSelectors(gettersFacet.interface);
            for (const selector of gettersFacetToUpgradeSelectors) {
                const addr = await proxyAsGetters.facetAddress(selector);
                const isFreezable = await proxyAsGetters.isFunctionFreezable(selector);
                expect(addr).equal(gettersFacet.address);
                expect(isFreezable).equal(true);
            }
        });

        it('should revert on executing a proposal two times', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);
            await proxyAsDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);

            const secondFacetCutExecutionRevertReason = await getCallRevertReason(
                proxyAsDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero)
            );
            expect(secondFacetCutExecutionRevertReason).equal('ab');
        });

        it(`Should revert on proposing when an upgrade is already proposed`, async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);

            const reverReason = await getCallRevertReason(
                proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId)
            );
            expect(reverReason).equal(`a8`);

            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });

        it('should revert on executing unapproved shadow upgrade', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            const salt = ethers.utils.randomBytes(32);

            const executingProposalHash = await proxyAsDiamondCut.upgradeProposalHash(
                diamondCutData,
                nextProposalId,
                salt
            );
            await proxyAsDiamondCut.proposeShadowUpgrade(executingProposalHash, nextProposalId);

            const revertReason = await getCallRevertReason(proxyAsDiamondCut.executeUpgrade(diamondCutData, salt));
            expect(revertReason).equal('av');

            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });

        it(`Should revert on proposing a shadow upgrade with zero proposal hash`, async () => {
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            const revertReason = await getCallRevertReason(
                proxyAsDiamondCut.proposeShadowUpgrade(ethers.constants.HashZero, nextProposalId)
            );
            expect(revertReason).equal('mi');
        });

        it(`Should revert on proposing a shadow upgrade with wrong proposal id`, async () => {
            const currentProposalId = await proxyAsGetters.getCurrentProposalId();
            const revertReason = await getCallRevertReason(
                proxyAsDiamondCut.proposeShadowUpgrade(ethers.utils.randomBytes(32), currentProposalId)
            );
            expect(revertReason).equal('ya');
        });

        it(`Should revert on proposing a transparent upgrade with wrong proposal id`, async () => {
            const currentProposalId = await proxyAsGetters.getCurrentProposalId();
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const revertReason = await getCallRevertReason(
                proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, currentProposalId)
            );
            expect(revertReason).equal('yb');
        });

        it(`Should revert on cancelling an upgrade proposal with wrong hash`, async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);

            const reverReason = await getCallRevertReason(
                proxyAsDiamondCut.cancelUpgradeProposal(ethers.utils.randomBytes(32))
            );
            expect(reverReason).equal(`rx`);

            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });

        it('should revert on executing a transparent upgrade with nonzero salt', async () => {
            const facetCuts = [facetCut(gettersFacet.address, gettersFacet.interface, Action.Replace, true)];
            const diamondCutData = diamondCut(facetCuts, ethers.constants.AddressZero, '0x');
            const nextProposalId = (await proxyAsGetters.getCurrentProposalId()).add(1);
            await proxyAsDiamondCut.proposeTransparentUpgrade(diamondCutData, nextProposalId);

            const revertReason = await getCallRevertReason(
                proxyAsDiamondCut.executeUpgrade(diamondCutData, ethers.utils.randomBytes(32))
            );
            expect(revertReason).equal('po');

            const proposalHash = await proxyAsGetters.getProposedUpgradeHash();
            await proxyAsDiamondCut.cancelUpgradeProposal(proposalHash);
        });
    });
});
