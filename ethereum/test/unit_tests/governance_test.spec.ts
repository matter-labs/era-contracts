import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { AdminFacetTest, AdminFacetTestFactory, GovernanceFactory } from '../../typechain';
import { getCallRevertReason } from './utils';
import * as ethers from 'ethers';

function randomAddress() {
    return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}

describe('Admin facet tests', function () {
    let adminFacetTest: AdminFacetTest;
    let randomSigner: ethers.Signer;

    before(async () => {
        const contractFactory = await hardhat.ethers.getContractFactory('AdminFacetTest');
        const contract = await contractFactory.deploy();
        adminFacetTest = AdminFacetTestFactory.connect(contract.address, contract.signer);

        const governanceFactory = await hardhat.ethers.getContractFactory('Governance');
        const governanceContract = await contractFactory.deploy();
        const governance = GovernanceFactory.connect(governanceContract.address, governanceContract.signer);
        await adminFacetTest.setPendingGovernor(governance.address);

        randomSigner = (await hardhat.ethers.getSigners())[1];
    });

    it('governor successfully set validator', async () => {
        const validatorAddress = randomAddress();
        await adminFacetTest.setValidator(validatorAddress, true);

        const isValidator = await adminFacetTest.isValidator(validatorAddress);
        expect(isValidator).to.equal(true);
    });

    it('random account fails to set validator', async () => {
        const validatorAddress = randomAddress();
        const revertReason = await getCallRevertReason(
            adminFacetTest.connect(randomSigner).setValidator(validatorAddress, true)
        );
        expect(revertReason).equal('Only by governor or admin');
    });

    it('governor successfully set porter availability', async () => {
        await adminFacetTest.setPorterAvailability(true);

        const porterAvailability = await adminFacetTest.getPorterAvailability();
        expect(porterAvailability).to.equal(true);
    });

    it('random account fails to set porter availability', async () => {
        const revertReason = await getCallRevertReason(
            adminFacetTest.connect(randomSigner).setPorterAvailability(false)
        );
        expect(revertReason).equal('1g');
    });

    it('governor successfully set priority transaction max gas limit', async () => {
        const gasLimit = '12345678';
        await adminFacetTest.setPriorityTxMaxGasLimit(gasLimit);

        const newGasLimit = await adminFacetTest.getPriorityTxMaxGasLimit();
        expect(newGasLimit).to.equal(gasLimit);
    });

    it('random account fails to priority transaction max gas limit', async () => {
        const gasLimit = '123456789';
        const revertReason = await getCallRevertReason(
            adminFacetTest.connect(randomSigner).setPriorityTxMaxGasLimit(gasLimit)
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
            await adminFacetTest.setPendingGovernor(proposedGovernor);

            const pendingGovernor = await adminFacetTest.getPendingGovernor();
            expect(pendingGovernor).equal(proposedGovernor);
        });

        it('reset pending governor', async () => {
            const proposedGovernor = await newGovernor.getAddress();
            await adminFacetTest.setPendingGovernor(proposedGovernor);

            const pendingGovernor = await adminFacetTest.getPendingGovernor();
            expect(pendingGovernor).equal(proposedGovernor);
        });

        it('failed to accept governor from not proposed account', async () => {
            const revertReason = await getCallRevertReason(adminFacetTest.connect(randomSigner).acceptGovernor());
            expect(revertReason).equal('n4');
        });

        it('accept governor from proposed account', async () => {
            await adminFacetTest.connect(newGovernor).acceptGovernor();

            const governor = await adminFacetTest.getGovernor();
            expect(governor).equal(await newGovernor.getAddress());
        });
    });
});
