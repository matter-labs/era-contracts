import { CONTRACT_DEPLOYER_ADDRESS, hashBytecode } from 'zksync-web3/build/src/utils';
import { KeccakTest, KeccakTest__factory } from '../typechain-types';
import { KECCAK256_CONTRACT_ADDRESS } from './shared/constants';
import { getWallets, loadArtifact, publishBytecode, setCode } from './shared/utils';
import { ethers } from 'hardhat';
import { readYulBytecode } from '../scripts/utils';
import { Language } from '../scripts/constants';
import { Wallet } from 'ethers';
import { expect } from 'chai';

describe('Keccak256 tests', function () {
    let testWallet: Wallet;
    let keccakTest: KeccakTest;

    let correctKeccakCodeHash: string;
    let alwaysRevertCodeHash: string;

    // Kernel space address, needed to enable mimicCall
    const KECCAK_TEST_ADDRESS = '0x0000000000000000000000000000000000009000';

    before(async () => {
        testWallet = getWallets()[0];

        await setCode(
            KECCAK_TEST_ADDRESS,
            (await loadArtifact('KeccakTest')).bytecode
        );

        keccakTest = KeccakTest__factory.connect(KECCAK_TEST_ADDRESS,  getWallets()[0]);
        const correctKeccakCode = readYulBytecode({
            codeName: 'Keccak256',
            path: 'precompiles',
            lang: Language.Yul,
            address: ethers.constants.AddressZero
        });

        const correctContractDeployerCode = (await loadArtifact('ContractDeployer')).bytecode;
        await setCode(CONTRACT_DEPLOYER_ADDRESS, correctContractDeployerCode);

        const emptyContractCode = (await loadArtifact('AlwaysRevert')).bytecode;
        
        await publishBytecode(correctKeccakCode);
        await publishBytecode(emptyContractCode);

        correctKeccakCodeHash = ethers.utils.hexlify(hashBytecode(correctKeccakCode));
        alwaysRevertCodeHash = ethers.utils.hexlify(hashBytecode(emptyContractCode));
    });

    it('zero pointer test', async () => {
        await keccakTest.zeroPointerTest()
    });

    it('general functionality test', async () => {
        // We currently do not have fussing support, so we generate random data using
        // hash function. 

        const seed = ethers.utils.randomBytes(32);
        // Displaying seed for reproducible tests
        console.log('Keccak256 fussing seed', ethers.utils.hexlify(seed));

        for(let i = 0; i < 5; i++) {
            const data = ethers.utils.keccak256(ethers.utils.hexConcat([seed, i]));

            const correctHash = ethers.utils.keccak256(data);
            const hashFromPrecompile = await testWallet.provider.call({
                to: KECCAK256_CONTRACT_ADDRESS,
                data: data
            });

            expect(hashFromPrecompile).to.equal(correctHash, 'Hash is incorrect');
        }
    });

    it('keccak upgrade test', async() => {
        const deployerInterfact = new ethers.utils.Interface((await loadArtifact('ContractDeployer')).abi);

        const eraseInput = deployerInterfact.encodeFunctionData('forceDeployKeccak256', [
            alwaysRevertCodeHash
        ]);

        const upgradeInput = deployerInterfact.encodeFunctionData('forceDeployKeccak256', [
            correctKeccakCodeHash
        ]);

        await keccakTest.keccakUpgradeTest(
            eraseInput,
            upgradeInput
        );
    })
});
