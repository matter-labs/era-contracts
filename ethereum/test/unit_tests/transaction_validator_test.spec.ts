import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { TransactionValidatorTestFactory, TransactionValidatorTest } from '../../typechain';
import { getCallRevertReason } from './utils';
import * as ethers from 'ethers';

describe('TransactionValidator tests', function () {
    let tester: TransactionValidatorTest;
    before(async () => {
        const testerFactory = await hardhat.ethers.getContractFactory('TransactionValidatorTest');
        const testerContract = await testerFactory.deploy();
        tester = TransactionValidatorTestFactory.connect(testerContract.address, testerContract.signer);
    });

    describe('validateL1ToL2Transaction', function () {
        it('Should not revert when all parameters are valid', async () => {
            await tester.validateL1ToL2Transaction(createTestTransaction({}), 500000);
        });

        it('Should revert when provided gas limit doesnt cover transaction overhead', async () => {
            const result = await getCallRevertReason(
                tester.validateL1ToL2Transaction(
                    createTestTransaction({
                        gasLimit: 0
                    }),
                    500000
                )
            );
            expect(result).equal('my');
        });

        it('Should revert when needed gas is higher than the max', async () => {
            const result = await getCallRevertReason(tester.validateL1ToL2Transaction(createTestTransaction({}), 0));
            expect(result).equal('ui');
        });

        it('Should revert when transaction can output more pubdata than processable', async () => {
            const result = await getCallRevertReason(
                tester.validateL1ToL2Transaction(
                    createTestTransaction({
                        gasPerPubdataByteLimit: 1
                    }),
                    500000
                )
            );
            expect(result).equal('uk');
        });

        it('Should revert when transaction gas doesnt pay the minimum costs', async () => {
            const result = await getCallRevertReason(
                tester.validateL1ToL2Transaction(
                    createTestTransaction({
                        gasLimit: 200000
                    }),
                    500000
                )
            );
            expect(result).equal('up');
        });
    });

    describe('validateUpgradeTransaction', function () {
        it('Should not revert when all parameters are valid', async () => {
            await tester.validateUpgradeTransaction(createTestTransaction({}));
        });

        it('Should revert when from is too large', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        from: ethers.BigNumber.from(2).pow(16)
                    })
                )
            );
            expect(result).equal('ua');
        });

        it('Should revert when to is too large', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        to: ethers.BigNumber.from(2).pow(161)
                    })
                )
            );
            expect(result).equal('ub');
        });

        it('Should revert when paymaster is non-zero', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        paymaster: 1
                    })
                )
            );
            expect(result).equal('uc');
        });

        it('Should revert when value is non-zero', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        value: 1
                    })
                )
            );
            expect(result).equal('ud');
        });

        it('Should revert when reserved[0] is non-zero', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        reserved: [1, 0, 0, 0]
                    })
                )
            );
            expect(result).equal('ue');
        });

        it('Should revert when reserved[1] is too large', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        reserved: [0, ethers.BigNumber.from(2).pow(161), 0, 0]
                    })
                )
            );
            expect(result).equal('uf');
        });

        it('Should revert when reserved[2] is non-zero', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        reserved: [0, 0, 1, 0]
                    })
                )
            );
            expect(result).equal('ug');
        });

        it('Should revert when reserved[3] is non-zero', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        reserved: [0, 0, 0, 1]
                    })
                )
            );
            expect(result).equal('uo');
        });

        it('Should revert when signature has non-zero length', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        signature: '0xaa'
                    })
                )
            );
            expect(result).equal('uh');
        });

        it('Should revert when paymaster input has non-zero length', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        paymasterInput: '0xaa'
                    })
                )
            );
            expect(result).equal('ul');
        });

        it('Should revert when reserved dynamic field has non-zero length', async () => {
            const result = await getCallRevertReason(
                tester.validateUpgradeTransaction(
                    createTestTransaction({
                        reservedDynamic: '0xaa'
                    })
                )
            );
            expect(result).equal('um');
        });
    });
});

function createTestTransaction(overrides) {
    return Object.assign(
        {
            txType: 0,
            from: ethers.BigNumber.from(2).pow(16).sub(1),
            to: 0,
            gasLimit: 500000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: 0,
            nonce: 0,
            value: 0,
            reserved: [0, 0, 0, 0],
            data: '0x',
            signature: '0x',
            factoryDeps: [],
            paymasterInput: '0x',
            reservedDynamic: '0x'
        },
        overrides
    );
}
