import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { ethers } from 'hardhat';
import { PriorityQueueTest, PriorityQueueTestFactory } from '../../typechain';
import { getCallRevertReason } from './utils';

describe('Priority queue tests', function () {
    let priorityQueueTest: PriorityQueueTest;
    let queue = [];

    before(async () => {
        const contractFactory = await hardhat.ethers.getContractFactory('PriorityQueueTest');
        const contract = await contractFactory.deploy();
        priorityQueueTest = PriorityQueueTestFactory.connect(contract.address, contract.signer);
    });

    describe('on empty queue', function () {
        it('getSize', async () => {
            const size = await priorityQueueTest.getSize();
            expect(size).equal(0);
        });

        it('getFirstUnprocessedPriorityTx', async () => {
            const firstUnprocessedTx = await priorityQueueTest.getFirstUnprocessedPriorityTx();
            expect(firstUnprocessedTx).equal(0);
        });

        it('getTotalPriorityTxs', async () => {
            const totalPriorityTxs = await priorityQueueTest.getTotalPriorityTxs();
            expect(totalPriorityTxs).equal(0);
        });

        it('isEmpty', async () => {
            const isEmpty = await priorityQueueTest.isEmpty();
            expect(isEmpty).equal(true);
        });

        it('failed to get front', async () => {
            const revertReason = await getCallRevertReason(priorityQueueTest.front());
            expect(revertReason).equal('D');
        });

        it('failed to pop', async () => {
            const revertReason = await getCallRevertReason(priorityQueueTest.popFront());
            expect(revertReason).equal('s');
        });
    });

    describe('push operations', function () {
        const NUMBER_OPERATIONS = 10;

        before(async () => {
            for (let i = 0; i < NUMBER_OPERATIONS; ++i) {
                const dummyOp = { canonicalTxHash: ethers.constants.HashZero, expirationTimestamp: i, layer2Tip: i };
                queue.push(dummyOp);
                await priorityQueueTest.pushBack(dummyOp);
            }
        });

        it('front', async () => {
            const frontElement = await priorityQueueTest.front();

            expect(frontElement.canonicalTxHash).equal(queue[0].canonicalTxHash);
            expect(frontElement.expirationTimestamp).equal(queue[0].expirationTimestamp);
            expect(frontElement.layer2Tip).equal(queue[0].layer2Tip);
        });

        it('getSize', async () => {
            const size = await priorityQueueTest.getSize();
            expect(size).equal(queue.length);
        });

        it('getFirstUnprocessedPriorityTx', async () => {
            const firstUnprocessedTx = await priorityQueueTest.getFirstUnprocessedPriorityTx();
            expect(firstUnprocessedTx).equal(0);
        });

        it('getTotalPriorityTxs', async () => {
            const totalPriorityTxs = await priorityQueueTest.getTotalPriorityTxs();
            expect(totalPriorityTxs).equal(queue.length);
        });

        it('isEmpty', async () => {
            const isEmpty = await priorityQueueTest.isEmpty();
            expect(isEmpty).equal(false);
        });
    });

    describe('pop operations', function () {
        const NUMBER_OPERATIONS = 4;

        before(async () => {
            for (let i = 0; i < NUMBER_OPERATIONS; ++i) {
                const frontElement = await priorityQueueTest.front();
                expect(frontElement.canonicalTxHash).equal(queue[0].canonicalTxHash);
                expect(frontElement.expirationTimestamp).equal(queue[0].expirationTimestamp);
                expect(frontElement.layer2Tip).equal(queue[0].layer2Tip);

                await priorityQueueTest.popFront();
                queue.shift();
            }
        });

        it('front', async () => {
            const frontElement = await priorityQueueTest.front();

            expect(frontElement.canonicalTxHash).equal(queue[0].canonicalTxHash);
            expect(frontElement.expirationTimestamp).equal(queue[0].expirationTimestamp);
            expect(frontElement.layer2Tip).equal(queue[0].layer2Tip);
        });

        it('getSize', async () => {
            const size = await priorityQueueTest.getSize();
            expect(size).equal(queue.length);
        });

        it('getFirstUnprocessedPriorityTx', async () => {
            const firstUnprocessedTx = await priorityQueueTest.getFirstUnprocessedPriorityTx();
            expect(firstUnprocessedTx).equal(NUMBER_OPERATIONS);
        });

        it('getTotalPriorityTxs', async () => {
            const totalPriorityTxs = await priorityQueueTest.getTotalPriorityTxs();
            expect(totalPriorityTxs).equal(queue.length + NUMBER_OPERATIONS);
        });

        it('isEmpty', async () => {
            const isEmpty = await priorityQueueTest.isEmpty();
            expect(isEmpty).equal(false);
        });
    });
});
