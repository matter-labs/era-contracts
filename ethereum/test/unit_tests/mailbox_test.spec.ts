import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { Action, facetCut, diamondCut } from '../../src.ts/diamondCut';
import { MailboxFacet, MailboxFacetFactory, DiamondInitFactory, AllowListFactory, AllowList } from '../../typechain';
import { DEFAULT_REVERT_REASON, getCallRevertReason, AccessMode, DEFAULT_L2_GAS_PRICE_PER_PUBDATA } from './utils';
import * as ethers from 'ethers';

describe('Mailbox tests', function () {
    let mailbox: MailboxFacet;
    let allowList: AllowList;
    let diamondProxyContract: ethers.Contract;
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
    const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const mailboxFactory = await hardhat.ethers.getContractFactory('MailboxFacet');
        const mailboxContract = await mailboxFactory.deploy();
        const mailboxFacet = MailboxFacetFactory.connect(mailboxContract.address, mailboxContract.signer);

        const allowListFactory = await hardhat.ethers.getContractFactory('AllowList');
        const allowListContract = await allowListFactory.deploy(await allowListFactory.signer.getAddress());
        allowList = AllowListFactory.connect(allowListContract.address, allowListContract.signer);

        // Note, that while this testsuit is focused on testing MailboxFaucet only,
        // we still need to initialize its storage via DiamondProxy
        const diamondInitFactory = await hardhat.ethers.getContractFactory('DiamondInit');
        const diamondInitContract = await diamondInitFactory.deploy();
        const diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

        const dummyHash = new Uint8Array(32);
        dummyHash.set([1, 0, 0, 1]);
        const dummyAddress = ethers.utils.hexlify(await ethers.utils.randomBytes(20));
        const diamondInitData = diamondInit.interface.encodeFunctionData('initialize', [
            dummyAddress,
            dummyAddress,
            ethers.constants.AddressZero,
            ethers.constants.HashZero,
            0,
            ethers.constants.HashZero,
            allowList.address,
            {
                recursionCircuitsSetVksHash: ethers.constants.HashZero,
                recursionLeafLevelVkHash: ethers.constants.HashZero,
                recursionNodeLevelVkHash: ethers.constants.HashZero
            },
            false,
            dummyHash,
            dummyHash,
            100000000000
        ]);

        const facetCuts = [facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, false)];
        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

        await (await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Public)).wait();

        mailbox = MailboxFacetFactory.connect(diamondProxyContract.address, mailboxContract.signer);
    });

    it('Should accept correctly formatted bytecode', async () => {
        const revertReason = await getCallRevertReason(
            mailbox.requestL2Transaction(
                ethers.constants.AddressZero,
                0,
                '0x',
                1000000,
                DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(32)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal(DEFAULT_REVERT_REASON);
    });

    it('Should not accept bytecode is not chunkable', async () => {
        const revertReason = await getCallRevertReason(
            mailbox.requestL2Transaction(
                ethers.constants.AddressZero,
                0,
                '0x',
                100000,
                DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(63)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('po');
    });

    it('Should not accept bytecode of even length in words', async () => {
        const revertReason = await getCallRevertReason(
            mailbox.requestL2Transaction(
                ethers.constants.AddressZero,
                0,
                '0x',
                100000,
                DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(64)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pr');
    });

    it('Should not accept bytecode that is too long', async () => {
        const revertReason = await getCallRevertReason(
            mailbox.requestL2Transaction(
                ethers.constants.AddressZero,
                0,
                '0x',
                100000,
                DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                [
                    // "+64" to keep the length in words odd and bytecode chunkable
                    new Uint8Array(MAX_CODE_LEN_BYTES + 64)
                ],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pp');
    });

    describe('Deposit and Withdrawal limit functionality', function () {
        it('Should not accept depositing more than the deposit limit', async () => {
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, ethers.utils.parseEther('10'));

            const revertReason = await getCallRevertReason(
                mailbox.requestL2Transaction(
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther('12'),
                    '0x',
                    1000000,
                    DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { value: ethers.utils.parseEther('12') }
                )
            );

            expect(revertReason).equal(`d2`);
        });

        it('Should accept depositing less than or equal to the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                mailbox.requestL2Transaction(
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther('10'),
                    '0x',
                    1000000,
                    DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { value: ethers.utils.parseEther('10') }
                )
            );

            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });

        it('Should not accept depositing that the accumulation is more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                mailbox.requestL2Transaction(
                    ethers.constants.AddressZero,
                    1,
                    '0x',
                    1000000,
                    DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { value: 1 } // 1 wei
                )
            );

            expect(revertReason).equal(`d2`);
        });

        it(`Should not accept withdrawing more than withdrawal limit`, async () => {
            await allowList.setWithdrawalLimit(ethers.constants.AddressZero, true, 10); // setting the withdrawal limit to %10 of ETH balance

            let functionSignature = `0x6c0960f9`; //finalizeEthWithdrawal
            let value = ethers.utils.hexZeroPad(ethers.utils.parseEther('2').toHexString(), 32); // withdrawing 2 ETH
            let l1Receiver = ethers.utils.hexZeroPad('0x000000000000000000000000000000000000000a', 20);
            let message = ethers.utils.hexConcat([functionSignature, l1Receiver, value]);

            const revertReason = await getCallRevertReason(mailbox.finalizeEthWithdrawal(0, 0, 0, message, []));

            expect(revertReason).equal(`w3`);
        });
    });

    describe(`Access mode functionality`, function () {
        it(`Should not allow an un-whitelisted address to call`, async () => {
            await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Closed);
            const revertReason = await getCallRevertReason(
                mailbox
                    .connect(randomSigner)
                    .requestL2Transaction(
                        ethers.constants.AddressZero,
                        0,
                        '0x',
                        1000000,
                        DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                        [new Uint8Array(32)],
                        ethers.constants.AddressZero
                    )
            );
            expect(revertReason).equal(`nr`);
        });

        it(`Should allow the whitelisted address to call`, async () => {
            await allowList.setAccessMode(diamondProxyContract.address, AccessMode.SpecialAccessOnly);
            await allowList.setPermissionToCall(
                await owner.getAddress(),
                diamondProxyContract.address,
                `0xeb672419`,
                true
            );
            const revertReason = await getCallRevertReason(
                mailbox
                    .connect(owner)
                    .requestL2Transaction(
                        ethers.constants.AddressZero,
                        0,
                        '0x',
                        1000000,
                        DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                        [new Uint8Array(32)],
                        ethers.constants.AddressZero
                    )
            );
            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });
    });
});
