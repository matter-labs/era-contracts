import { CONTRACT_DEPLOYER_ADDRESS, hashBytecode } from 'zksync-web3/build/src/utils';
import { KeccakTest, KeccakTest__factory } from '../typechain-types';
import { KECCAK256_CONTRACT_ADDRESS } from './shared/constants';
import { getCode, getWallets, loadArtifact, publishBytecode, setCode } from './shared/utils';
import { ethers } from 'hardhat';

describe('Keccak256 tests', function () {
    let keccakTest: KeccakTest;

    let correctKeccakCodeHash: string;
    let alwaysRevertCodeHash: string;

    // Kernel space address, needed to enable mimicCall
    const KECCAK_TEST_ADDRESS = '0x0000000000000000000000000000000000009000';

    before(async () => {
        await setCode(
            KECCAK_TEST_ADDRESS,
            (await loadArtifact('KeccakTest')).bytecode
        );

        keccakTest = KeccakTest__factory.connect(KECCAK_TEST_ADDRESS,  getWallets()[0]);
        const correctKeccakCode = await getCode(KECCAK256_CONTRACT_ADDRESS);

        // The test node might use outdated contracts
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
