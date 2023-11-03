import { CONTRACT_DEPLOYER_ADDRESS, hashBytecode } from 'zksync-web3/build/src/utils';
import { KeccakTest, KeccakTest__factory } from '../typechain-types';
import { KECCAK256_CONTRACT_ADDRESS } from './shared/constants';
import { getWallets, loadArtifact, publishBytecode, setCode } from './shared/utils';
import { ethers } from 'hardhat';
import { readYulBytecode } from '../scripts/utils';
import { Language } from '../scripts/constants';
import { BytesLike, Wallet, providers } from 'ethers';
import { expect } from 'chai';
import { ECDH } from 'crypto';

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

        // Testing empty array
        await compareCorrectHash('0x', testWallet.provider!);
        const BLOCK_SIZE = 136;

        await compareCorrectHash(randomHexFromSeed(seed, BLOCK_SIZE), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, BLOCK_SIZE - 1), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, BLOCK_SIZE - 2), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, BLOCK_SIZE + 1), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, BLOCK_SIZE + 2), testWallet.provider!);

        await compareCorrectHash(randomHexFromSeed(seed, 101 * BLOCK_SIZE), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, 101 * BLOCK_SIZE - 1), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, 101 * BLOCK_SIZE - 2), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, 101 * BLOCK_SIZE + 1), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, 101 * BLOCK_SIZE + 2), testWallet.provider!);

        // In order to get random length, we use modulo operation
        await compareCorrectHash(randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(113).toNumber()), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(1101).toNumber()), testWallet.provider!);
        await compareCorrectHash(randomHexFromSeed(seed, ethers.BigNumber.from(seed).mod(17).toNumber()), testWallet.provider!);
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

async function compareCorrectHash (
    data: BytesLike,
    provider: providers.Provider
) {
    const correctHash = ethers.utils.keccak256(data);
    const hashFromPrecompile = await provider.call({
        to: KECCAK256_CONTRACT_ADDRESS,
        data
    });
    expect(hashFromPrecompile).to.equal(correctHash, 'Hash is incorrect');
}

function randomHexFromSeed(
    seed: BytesLike,
    len: number,
) {
    const hexLen = len * 2 + 2;
    let data = '0x';
    while (data.length < hexLen) {
        const next = ethers.utils.keccak256(ethers.utils.hexConcat([seed, data]));
        data = ethers.utils.hexConcat([data, next]);
    }
    return data.substring(0, hexLen);
}
