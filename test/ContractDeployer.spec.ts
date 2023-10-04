import { expect } from 'chai';
import {
    ContractDeployer,
    ContractDeployer__factory,
    NonceHolder,
    NonceHolder__factory,
    Deployable__factory
} from '../typechain-types';
import {
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
    FORCE_DEPLOYER_ADDRESS
} from './shared/constants';
import { Wallet, Contract, utils } from 'zksync-web3';
import { getWallets, deployContract, loadArtifact, setCode, getCode, publishBytecode } from './shared/utils';
import { network, ethers } from 'hardhat';
import { ZkSyncArtifact } from '@matterlabs/hardhat-zksync-deploy/dist/types';

describe('ContractDeployer tests', function () {
    let wallet: Wallet;
    let contractDeployer: ContractDeployer;
    let contractDeployerSystemCall: ContractDeployer;
    let contractDeployerNotSystemCall: ContractDeployer;
    let nonceHolder: NonceHolder;
    let deployableArtifact: ZkSyncArtifact;
    let deployerAccount: ethers.Signer;
    let forceDeployer: ethers.Signer;

    const EOA = ethers.utils.getAddress('0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef');
    const RANDOM_ADDRESS = ethers.utils.getAddress('0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbee1');
    const RANDOM_ADDRESS_2 = ethers.utils.getAddress('0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbee2');
    const RANDOM_ADDRESS_3 = ethers.utils.getAddress('0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbee3');
    const AA_VERSION_NONE = 0;
    const AA_VERSION_1 = 1;
    const NONCE_ORDERING_SEQUENTIAL = 0;
    const NONCE_ORDERING_ARBITRARY = 1;

    let _contractDeployerCode: string;

    before(async () => {
        wallet = getWallets()[0];

        _contractDeployerCode = await getCode(DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
        let contractDeployerArtifact = await loadArtifact('ContractDeployer');
        await setCode(DEPLOYER_SYSTEM_CONTRACT_ADDRESS, contractDeployerArtifact.bytecode);
        contractDeployer = ContractDeployer__factory.connect(DEPLOYER_SYSTEM_CONTRACT_ADDRESS, wallet);

        nonceHolder = NonceHolder__factory.connect(NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, wallet);

        let contractDeployerSystemCallContract = await deployContract('SystemCaller', [contractDeployer.address]);
        contractDeployerSystemCall = new Contract(
            contractDeployerSystemCallContract.address,
            contractDeployerArtifact.abi,
            wallet
        ) as ContractDeployer;

        let contractDeployerNotSystemCallContract = await deployContract('NotSystemCaller', [contractDeployer.address]);
        contractDeployerNotSystemCall = new Contract(
            contractDeployerNotSystemCallContract.address,
            contractDeployerArtifact.abi,
            wallet
        ) as ContractDeployer;

        deployableArtifact = await loadArtifact('Deployable');
        await publishBytecode(deployableArtifact.bytecode);

        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [DEPLOYER_SYSTEM_CONTRACT_ADDRESS]
        });
        await network.provider.request({
            method: 'hardhat_impersonateAccount',
            params: [FORCE_DEPLOYER_ADDRESS]
        });
        deployerAccount = await ethers.getSigner(DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
        forceDeployer = await ethers.getSigner(FORCE_DEPLOYER_ADDRESS);
    });

    after(async () => {
        await network.provider.request({
            method: 'hardhat_stopImpersonatingAccount',
            params: [DEPLOYER_SYSTEM_CONTRACT_ADDRESS]
        });
        await network.provider.request({
            method: 'hardhat_stopImpersonatingAccount',
            params: [FORCE_DEPLOYER_ADDRESS]
        });
        await setCode(DEPLOYER_SYSTEM_CONTRACT_ADDRESS, _contractDeployerCode);
    });

    describe('updateAccountVersion', function () {
        it('non system call failed', async () => {
            await expect(contractDeployer.updateAccountVersion(AA_VERSION_NONE)).to.be.revertedWith(
                'This method require system call flag'
            );
        });

        it('from none to version1', async () => {
            expect(
                (await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion
            ).to.be.eq(AA_VERSION_NONE);
            await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_1);
            expect(
                (await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion
            ).to.be.eq(AA_VERSION_1);
        });

        it('from version1 to none', async () => {
            expect(
                (await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion
            ).to.be.eq(AA_VERSION_1);
            await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_NONE);
            expect(
                (await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).supportedAAVersion
            ).to.be.eq(AA_VERSION_NONE);
        });
    });

    describe('updateNonceOrdering', function () {
        it('non system call failed', async () => {
            await expect(contractDeployer.updateNonceOrdering(NONCE_ORDERING_SEQUENTIAL)).to.be.revertedWith(
                'This method require system call flag'
            );
        });

        it('success from sequential to arbitrary', async () => {
            expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).nonceOrdering).to.be.eq(
                NONCE_ORDERING_SEQUENTIAL
            );
            await contractDeployerSystemCall.updateNonceOrdering(NONCE_ORDERING_ARBITRARY);
            expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).nonceOrdering).to.be.eq(
                NONCE_ORDERING_ARBITRARY
            );
        });

        it('failed from arbitrary to sequential', async () => {
            expect((await contractDeployer.getAccountInfo(contractDeployerSystemCall.address)).nonceOrdering).to.be.eq(
                NONCE_ORDERING_ARBITRARY
            );
            await expect(contractDeployerSystemCall.updateNonceOrdering(NONCE_ORDERING_SEQUENTIAL)).to.be.revertedWith(
                'It is only possible to change from sequential to arbitrary ordering'
            );
        });
    });

    describe('getAccountInfo', function () {
        it('success', async () => {
            let accountInfo = await contractDeployer.getAccountInfo(RANDOM_ADDRESS);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('extendedAccountVersion', function () {
        it('account abstraction contract', async () => {
            await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_1);
            expect(await contractDeployer.extendedAccountVersion(contractDeployerSystemCall.address)).to.be.eq(
                AA_VERSION_1
            );
            await contractDeployerSystemCall.updateAccountVersion(AA_VERSION_NONE);
        });

        it('EOA', async () => {
            expect(await contractDeployer.extendedAccountVersion(EOA)).to.be.eq(AA_VERSION_1);
        });

        it('not AA', async () => {
            expect(await contractDeployer.extendedAccountVersion(contractDeployerSystemCall.address)).to.be.eq(
                AA_VERSION_NONE
            );
        });
    });

    describe('getNewAddressCreate2', function () {
        it('success', async () => {
            expect(
                await contractDeployer.getNewAddressCreate2(
                    RANDOM_ADDRESS,
                    '0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF',
                    '0x0000000022000000000123812381283812831823812838912389128938912893',
                    '0x'
                )
            ).to.be.eq(
                utils.create2Address(
                    RANDOM_ADDRESS,
                    '0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF',
                    '0x0000000022000000000123812381283812831823812838912389128938912893',
                    '0x'
                )
            );
        });
    });

    describe('getNewAddressCreate', function () {
        it('success', async () => {
            expect(await contractDeployer.getNewAddressCreate(RANDOM_ADDRESS, 3223233)).to.be.eq(
                utils.createAddress(RANDOM_ADDRESS, 3223233)
            );
        });
    });

    // TODO: some other things can be tested:
    // - check other contracts (like known codes storage)
    // - cases with the kernel space address (not possible in production)
    // - twice on the same address for create (not possible in production)
    // - constructor behavior (failed, invalid immutables array)
    // - more cases for force deployments
    describe('createAccount', function () {
        it('non system call failed', async () => {
            await expect(
                contractDeployerNotSystemCall.createAccount(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('This method require system call flag');
        });

        it('zero bytecode hash failed', async () => {
            await expect(
                contractDeployerSystemCall.createAccount(
                    ethers.constants.HashZero,
                    ethers.constants.HashZero,
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('BytecodeHash cannot be zero');
        });

        it('not known bytecode hash failed', async () => {
            await expect(
                contractDeployerSystemCall.createAccount(
                    ethers.constants.HashZero,
                    '0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF',
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('The code hash is not known');
        });

        it('successfully deployed', async () => {
            let nonce = await nonceHolder.getDeploymentNonce(wallet.address);
            let expectedAddress = utils.createAddress(wallet.address, nonce);
            await expect(
                contractDeployer.createAccount(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0xdeadbeef',
                    AA_VERSION_NONE
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(0, '0xdeadbeef');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });

        it('non-zero value deployed', async () => {
            let nonce = await nonceHolder.getDeploymentNonce(wallet.address);
            let expectedAddress = utils.createAddress(wallet.address, nonce);
            await expect(
                contractDeployer.createAccount(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x',
                    AA_VERSION_NONE,
                    { value: 11111111 }
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(11111111, '0x');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('create2Account', function () {
        it('non system call failed', async () => {
            await expect(
                contractDeployerNotSystemCall.create2Account(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('This method require system call flag');
        });

        it('zero bytecode hash failed', async () => {
            await expect(
                contractDeployerSystemCall.create2Account(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    ethers.constants.HashZero,
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('BytecodeHash cannot be zero');
        });

        it('not known bytecode hash failed', async () => {
            await expect(
                contractDeployerSystemCall.create2Account(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    '0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF',
                    '0x',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('The code hash is not known');
        });

        it('successfully deployed', async () => {
            let expectedAddress = utils.create2Address(
                wallet.address,
                utils.hashBytecode(deployableArtifact.bytecode),
                '0x1234567891234567891234512222122167891123456789123456787654323456',
                '0xdeadbeef'
            );
            await expect(
                contractDeployer.create2Account(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0xdeadbeef',
                    AA_VERSION_NONE
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(0, '0xdeadbeef');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });

        it('already deployed failed', async () => {
            await expect(
                contractDeployer.create2Account(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0xdeadbeef',
                    AA_VERSION_NONE
                )
            ).to.be.revertedWith('Code hash is non-zero');
        });

        it('non-zero value deployed', async () => {
            let expectedAddress = utils.create2Address(
                wallet.address,
                utils.hashBytecode(deployableArtifact.bytecode),
                ethers.constants.HashZero,
                '0x'
            );
            await expect(
                contractDeployer.create2Account(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x',
                    AA_VERSION_NONE,
                    { value: 5555 }
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(5555, '0x');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('create', function () {
        it('non system call failed', async () => {
            await expect(
                contractDeployerNotSystemCall.create(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x'
                )
            ).to.be.revertedWith('This method require system call flag');
        });

        it('successfully deployed', async () => {
            let nonce = await nonceHolder.getDeploymentNonce(wallet.address);
            let expectedAddress = utils.createAddress(wallet.address, nonce);
            await expect(
                contractDeployer.create(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x12'
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(0, '0x12');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('create2', function () {
        it('non system call failed', async () => {
            await expect(
                contractDeployerNotSystemCall.create2(
                    ethers.constants.HashZero,
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0x'
                )
            ).to.be.revertedWith('This method require system call flag');
        });

        it('successfully deployed', async () => {
            let expectedAddress = utils.create2Address(
                wallet.address,
                utils.hashBytecode(deployableArtifact.bytecode),
                '0x1234567891234567891234512222122167891123456789123456787654323456',
                '0xab'
            );
            await expect(
                contractDeployer.create2(
                    '0x1234567891234567891234512222122167891123456789123456787654323456',
                    utils.hashBytecode(deployableArtifact.bytecode),
                    '0xab'
                )
            )
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), expectedAddress)
                .to.emit(Deployable__factory.connect(expectedAddress, wallet), 'Deployed')
                .withArgs(0, '0xab');
            let accountInfo = await contractDeployer.getAccountInfo(expectedAddress);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('forceDeployOnAddress', function () {
        it('not from self call failed', async () => {
            let deploymentData = {
                bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                newAddress: RANDOM_ADDRESS,
                callConstructor: false,
                value: 0,
                input: '0x'
            };
            await expect(contractDeployer.forceDeployOnAddress(deploymentData, wallet.address)).to.be.revertedWith(
                'Callable only by self'
            );
        });

        it('not known bytecode hash failed', async () => {
            let deploymentData = {
                bytecodeHash: '0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF',
                newAddress: RANDOM_ADDRESS,
                callConstructor: false,
                value: 0,
                input: '0x'
            };
            await expect(
                contractDeployer.connect(deployerAccount).forceDeployOnAddress(deploymentData, wallet.address)
            ).to.be.revertedWith('The code hash is not known');
        });

        it('successfully deployed', async () => {
            let deploymentData = {
                bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                newAddress: RANDOM_ADDRESS,
                callConstructor: false,
                value: 0,
                input: '0x'
            };
            await expect(contractDeployer.connect(deployerAccount).forceDeployOnAddress(deploymentData, wallet.address))
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(wallet.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS)
                .to.not.emit(Deployable__factory.connect(RANDOM_ADDRESS, wallet), 'Deployed');
            let accountInfo = await contractDeployer.getAccountInfo(RANDOM_ADDRESS);
            expect(accountInfo.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });

    describe('forceDeployOnAddresses', function () {
        it('not allowed to call', async () => {
            let deploymentData = [
                {
                    bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                    newAddress: RANDOM_ADDRESS_2,
                    callConstructor: true,
                    value: 0,
                    input: '0x'
                },
                {
                    bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                    newAddress: RANDOM_ADDRESS_3,
                    callConstructor: false,
                    value: 0,
                    input: '0xab'
                }
            ];
            await expect(contractDeployer.forceDeployOnAddresses(deploymentData)).to.be.revertedWith(
                'Can only be called by FORCE_DEPLOYER or COMPLEX_UPGRADER_CONTRACT'
            );
        });

        it('successfully deployed', async () => {
            let deploymentData = [
                {
                    bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                    newAddress: RANDOM_ADDRESS_2,
                    callConstructor: true,
                    value: 0,
                    input: '0x'
                },
                {
                    bytecodeHash: utils.hashBytecode(deployableArtifact.bytecode),
                    newAddress: RANDOM_ADDRESS_3,
                    callConstructor: false,
                    value: 0,
                    input: '0xab'
                }
            ];
            await expect(contractDeployer.connect(forceDeployer).forceDeployOnAddresses(deploymentData))
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(forceDeployer.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS_2)
                .to.emit(contractDeployer, 'ContractDeployed')
                .withArgs(forceDeployer.address, utils.hashBytecode(deployableArtifact.bytecode), RANDOM_ADDRESS_3)
                .to.emit(Deployable__factory.connect(RANDOM_ADDRESS_2, wallet), 'Deployed')
                .withArgs(0, '0x')
                .to.not.emit(Deployable__factory.connect(RANDOM_ADDRESS_3, wallet), 'Deployed');

            let accountInfo1 = await contractDeployer.getAccountInfo(RANDOM_ADDRESS_2);
            expect(accountInfo1.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo1.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);

            let accountInfo2 = await contractDeployer.getAccountInfo(RANDOM_ADDRESS_3);
            expect(accountInfo2.supportedAAVersion).to.be.eq(AA_VERSION_NONE);
            expect(accountInfo2.nonceOrdering).to.be.eq(NONCE_ORDERING_SEQUENTIAL);
        });
    });
});
