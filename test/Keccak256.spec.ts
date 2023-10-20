import { KeccakTest } from '../typechain-types';
import { deployContract } from './shared/utils';

describe('Keccak256 tests', function () {
    let keccakTest: KeccakTest;

    before(async () => {
        keccakTest = (await deployContract('KeccakTest')) as KeccakTest
    });

    it('zero pointer test', async () => {
        await keccakTest.zeroPointerTest()
    });
});
