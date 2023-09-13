import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { Action, facetCut, diamondCut } from '../../src.ts/diamondCut';
import {
    MailboxFacet,
    MailboxFacetFactory,
    DiamondInitFactory,
    AllowListFactory,
    AllowList,
    Forwarder,
    ForwarderFactory
} from '../../typechain';
import {
    DEFAULT_REVERT_REASON,
    getCallRevertReason,
    AccessMode,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    requestExecute
} from './utils';
import * as ethers from 'ethers';

describe('Mailbox tests', function () {
    const chainId = ethers.BigNumber.from(9);
    let mailbox: MailboxFacet;
    let allowList: AllowList;
    let diamondProxyContract: ethers.Contract;
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
    const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
    let forwarder: Forwarder;

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
        const dummyAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        const diamondInitData = diamondInit.interface.encodeFunctionData('initialize', [
            // dummyAddress,
            dummyAddress,
            ethers.constants.HashZero,
            0,
            ethers.constants.HashZero,
            allowList.address,
            // {
            //     recursionCircuitsSetVksHash: ethers.constants.HashZero,
            //     recursionLeafLevelVkHash: ethers.constants.HashZero,
            //     recursionNodeLevelVkHash: ethers.constants.HashZero
            // },
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

        const forwarderFactory = await hardhat.ethers.getContractFactory('Forwarder');
        const forwarderContract = await forwarderFactory.deploy();
        forwarder = ForwarderFactory.connect(forwarderContract.address, forwarderContract.signer);
    });

    it('Should accept correctly formatted bytecode', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                mailbox,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(1000000),
                [new Uint8Array(32)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal(DEFAULT_REVERT_REASON);
    });

    it('Should not accept bytecode is not chunkable', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                mailbox,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(63)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('bl');
    });

    it('Should not accept bytecode of even length in words', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                mailbox,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(64)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pr');
    });

    it('Should not accept bytecode that is too long', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                mailbox,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
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
        const DEPOSIT_LIMIT = ethers.utils.parseEther('10');

        before(async () => {
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, DEPOSIT_LIMIT);
        });

        it('Should not accept depositing more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    mailbox,
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther('12'),
                    '0x',
                    ethers.BigNumber.from(100000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });

        it('Should accept depositing less than or equal to the deposit limit', async () => {
            const gasPrice = await mailbox.provider.getGasPrice();
            const l2GasLimit = ethers.BigNumber.from(1000000);
            const l2Cost = await mailbox.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    mailbox,
                    ethers.constants.AddressZero,
                    DEPOSIT_LIMIT.sub(l2Cost),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { gasPrice }
                )
            );

            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });

        it('Should not accept depositing that the accumulation is more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    mailbox,
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(1),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });
    });

    describe(`Access mode functionality`, function () {
        before(async () => {
            // We still need to set infinite amount of allowed deposit limit in order to ensure that every fee will be accepted
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, ethers.utils.parseEther('2000'));
        });

        it(`Should not allow an un-whitelisted address to call`, async () => {
            await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Closed);

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    mailbox.connect(randomSigner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(100000),
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
                requestExecute(
                    chainId,
                    mailbox.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );
            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });
    });

    let callDirectly, callViaForwarder, callViaConstructorForwarder;

    before(async () => {
        const l2GasLimit = ethers.BigNumber.from(10000000);

        callDirectly = async (refundRecipient) => {
            return {
                transaction: await requestExecute(
                    chainId,
                    mailbox.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    refundRecipient
                ),
                expectedSender: await owner.getAddress()
            };
        };

        const encodeRequest = (refundRecipient) =>
            mailbox.interface.encodeFunctionData('requestL2Transaction', [
                chainId,
                ethers.constants.AddressZero,
                0,
                '0x',
                l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(32)],
                refundRecipient
            ]);

        let overrides: ethers.PayableOverrides = {};
        overrides.gasPrice = await mailbox.provider.getGasPrice();
        overrides.value = await mailbox.l2TransactionBaseCost(
            overrides.gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        overrides.gasLimit = 10000000;

        callViaForwarder = async (refundRecipient) => {
            return {
                transaction: await forwarder.forward(mailbox.address, encodeRequest(refundRecipient), overrides),
                expectedSender: aliasAddress(forwarder.address)
            };
        };

        callViaConstructorForwarder = async (refundRecipient) => {
            const constructorForwarder = await (
                await hardhat.ethers.getContractFactory('ConstructorForwarder')
            ).deploy(mailbox.address, encodeRequest(refundRecipient), overrides);

            return {
                transaction: constructorForwarder.deployTransaction,
                expectedSender: aliasAddress(constructorForwarder.address)
            };
        };
    });

    it('Should only alias externally-owned addresses', async () => {
        const indirections = [callDirectly, callViaForwarder, callViaConstructorForwarder];
        const refundRecipients = [
            [mailbox.address, false],
            [await mailbox.signer.getAddress(), true]
        ];

        for (const sendTransaction of indirections) {
            for (const [refundRecipient, externallyOwned] of refundRecipients) {
                const result = await sendTransaction(refundRecipient);

                const [event] = (await result.transaction.wait()).logs;
                const parsedEvent = mailbox.interface.parseLog(event);
                expect(parsedEvent.name).to.equal('NewPriorityRequest');

                const canonicalTransaction = parsedEvent.args.transaction;
                expect(canonicalTransaction.from).to.equal(result.expectedSender);

                expect(canonicalTransaction.reserved[1]).to.equal(
                    externallyOwned ? refundRecipient : aliasAddress(refundRecipient)
                );
            }
        }
    });
});

function aliasAddress(address) {
    return ethers.BigNumber.from(address)
        .add('0x1111000000000000000000000000000000001111')
        .mask(20 * 8);
}
