import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { AllowList, AllowListFactory } from '../../typechain';
import { AccessMode, getCallRevertReason } from './utils';
import * as ethers from 'ethers';

describe('Allow list tests', function () {
    let allowList: AllowList;
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const contractFactory = await hardhat.ethers.getContractFactory('AllowList');
        const contract = await contractFactory.deploy(await owner.getAddress());
        allowList = AllowListFactory.connect(contract.address, contract.signer);
    });

    describe('Allow list functionality', function () {
        const target = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
        const funcSig = '0x1626ba7e';

        describe('setPermissionToCall on closed contract', function () {
            it('non-owner failed to set permission to call', async () => {
                const revertReason = await getCallRevertReason(
                    allowList.connect(randomSigner).setPermissionToCall(await owner.getAddress(), target, funcSig, true)
                );
                expect(revertReason).equal('Ownable: caller is not the owner');
            });

            it('Check permission before', async () => {
                const hasSpecialAccessToCall = await allowList.hasSpecialAccessToCall(
                    await owner.getAddress(),
                    target,
                    funcSig
                );
                expect(hasSpecialAccessToCall).equal(false);

                const accessMode = await allowList.getAccessMode(target);
                expect(accessMode).equal(AccessMode.Closed);

                const canCall = await allowList.canCall(await owner.getAddress(), target, funcSig);
                expect(canCall).equal(false);
            });

            it('Owner successfully set permission to call', async () => {
                await allowList.setPermissionToCall(await owner.getAddress(), target, funcSig, true);
            });

            it('Successfully set the same permission twice', async () => {
                await allowList.setPermissionToCall(await owner.getAddress(), target, funcSig, true);
            });

            it('Check permission after', async () => {
                const hasSpecialAccessToCall = await allowList.hasSpecialAccessToCall(
                    await owner.getAddress(),
                    target,
                    funcSig
                );
                expect(hasSpecialAccessToCall).equal(true);

                const accessMode = await allowList.getAccessMode(target);
                expect(accessMode).equal(AccessMode.Closed);

                const canCall = await allowList.canCall(await owner.getAddress(), target, funcSig);
                expect(canCall).equal(false);
            });

            it('Successfully remove the permission', async () => {
                await allowList.setPermissionToCall(await owner.getAddress(), target, funcSig, false);
            });

            it('non-owner failed to set batch permission to call', async () => {
                let ownerAddress = await owner.getAddress();
                const revertReason = await getCallRevertReason(
                    allowList
                        .connect(randomSigner)
                        .setBatchPermissionToCall(
                            [ownerAddress, ownerAddress],
                            [target, target],
                            [funcSig, funcSig],
                            [true, true]
                        )
                );
                expect(revertReason).equal('Ownable: caller is not the owner');
            });

            it('Owner successfully set batch permission to call', async () => {
                let ownerAddress = await owner.getAddress();
                await allowList.setBatchPermissionToCall(
                    [ownerAddress, ownerAddress],
                    [target, target],
                    [funcSig, funcSig],
                    [true, true]
                );
            });

            it('Revert on different length in setting batch permission to call', async () => {
                let ownerAddress = await owner.getAddress();

                const revertReason = await getCallRevertReason(
                    allowList.setBatchPermissionToCall(
                        [ownerAddress],
                        [target, target],
                        [funcSig, funcSig],
                        [true, true]
                    )
                );
                expect(revertReason).equal('yw');
            });
        });
    });

    describe('setAccessMode', function () {
        const target = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
        const funcSig = '0xdeadbeaf';

        it('non-owner failed to set public access', async () => {
            const revertReason = await getCallRevertReason(
                allowList.connect(randomSigner).setAccessMode(target, AccessMode.Public)
            );
            expect(revertReason).equal('Ownable: caller is not the owner');
        });

        it('Check permission before', async () => {
            const hasSpecialAccessToCall = await allowList.hasSpecialAccessToCall(
                await owner.getAddress(),
                target,
                funcSig
            );
            expect(hasSpecialAccessToCall).equal(false);

            const accessMode = await allowList.getAccessMode(target);
            expect(accessMode).equal(AccessMode.Closed);

            const canCall = await allowList.canCall(await owner.getAddress(), target, funcSig);
            expect(canCall).equal(false);
        });

        it('Owner successfully set permission to call', async () => {
            await allowList.setAccessMode(target, AccessMode.Public);
        });

        it('Successfully set the same permission twice', async () => {
            await allowList.setAccessMode(target, AccessMode.Public);
        });

        it('Check permission after', async () => {
            const hasSpecialAccessToCall = await allowList.hasSpecialAccessToCall(
                await owner.getAddress(),
                target,
                funcSig
            );
            expect(hasSpecialAccessToCall).equal(false);

            const accessMode = await allowList.getAccessMode(target);
            expect(accessMode).equal(AccessMode.Public);

            const canCall = await allowList.canCall(await owner.getAddress(), target, funcSig);
            expect(canCall).equal(true);
        });

        it('Successfully remove the permission', async () => {
            await allowList.setAccessMode(target, AccessMode.Public);
        });

        it('non-owner failed to set batch public access', async () => {
            const revertReason = await getCallRevertReason(
                allowList
                    .connect(randomSigner)
                    .setBatchAccessMode([target, target], [AccessMode.Public, AccessMode.Public])
            );
            expect(revertReason).equal('Ownable: caller is not the owner');
        });

        it('Owner successfully set batch public access', async () => {
            await allowList.setBatchAccessMode([target, target], [AccessMode.Public, AccessMode.Public]);
        });

        it('Revert on different length in setting batch public access', async () => {
            const revertReason = await getCallRevertReason(
                allowList.setBatchAccessMode([target], [AccessMode.Public, AccessMode.Public])
            );
            expect(revertReason).equal('yg');
        });
    });
    describe('Deposit limit functionality', function () {
        const l1Token = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        it(`Non-owner fails to set deposit limit`, async () => {
            const revertReason = await getCallRevertReason(
                allowList.connect(randomSigner).setDepositLimit(l1Token, true, 1000)
            );
            expect(revertReason).equal('Ownable: caller is not the owner');
        });

        it(`Owner sets deposit limit`, async () => {
            await allowList.setDepositLimit(l1Token, true, 1000);
            let deposit = await allowList.getTokenDepositLimitData(l1Token);
            expect(deposit.depositLimitation).equal(true);
            expect(deposit.depositCap).equal(1000);
        });

        it(`Unlimited-deposit token returns zero`, async () => {
            let unlimitedToken = ethers.utils.hexlify(ethers.utils.randomBytes(20));
            let deposit = await allowList.getTokenDepositLimitData(unlimitedToken);
            expect(deposit.depositLimitation).equal(false);
            expect(deposit.depositCap).equal(0);
        });
    });
});
