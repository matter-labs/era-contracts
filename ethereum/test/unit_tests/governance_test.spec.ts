import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { GovernanceFacetTest, GovernanceFacetTestFactory } from '../../typechain';
import { getCallRevertReason } from './utils';
import * as ethers from 'ethers';

function randomAddress() {
    return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}

describe('Governance facet tests', function () {
    let governanceTest: GovernanceFacetTest;
    let randomSigner: ethers.Signer;

    before(async () => {
        const contractFactory = await hardhat.ethers.getContractFactory('GovernanceFacetTest');
        const contract = await contractFactory.deploy();
        governanceTest = GovernanceFacetTestFactory.connect(contract.address, contract.signer);
        randomSigner = (await hardhat.ethers.getSigners())[1];
    });

    it('governor successfully set validator', async () => {
        const validatorAddress = randomAddress();
        await governanceTest.setValidator(validatorAddress, true);

        const isValidator = await governanceTest.isValidator(validatorAddress);
        expect(isValidator).to.equal(true);
    });

    it('random account fails to set validator', async () => {
        const validatorAddress = randomAddress();
        const revertReason = await getCallRevertReason(
            governanceTest.connect(randomSigner).setValidator(validatorAddress, true)
        );
        expect(revertReason).equal('1g');
    });

    describe('change governor', function () {
        let newGovernor: ethers.Signer;

        before(async () => {
            newGovernor = (await hardhat.ethers.getSigners())[2];
        });

        it('set pending governor', async () => {
            const proposedGovernor = await randomSigner.getAddress();
            await governanceTest.setPendingGovernor(proposedGovernor);

            const pendingGovernor = await governanceTest.getPendingGovernor();
            expect(pendingGovernor).equal(proposedGovernor);
        });

        it('reset pending governor', async () => {
            const proposedGovernor = await newGovernor.getAddress();
            await governanceTest.setPendingGovernor(proposedGovernor);

            const pendingGovernor = await governanceTest.getPendingGovernor();
            expect(pendingGovernor).equal(proposedGovernor);
        });

        it('failed to accept governor from not proposed account', async () => {
            const revertReason = await getCallRevertReason(governanceTest.connect(randomSigner).acceptGovernor());
            expect(revertReason).equal('n4');
        });

        it('accept governor from proposed account', async () => {
            await governanceTest.connect(newGovernor).acceptGovernor();

            const governor = await governanceTest.getGovernor();
            expect(governor).equal(await newGovernor.getAddress());
        });
    });
});
