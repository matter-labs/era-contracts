import { expect } from 'chai';
import { BigNumber } from 'ethers';
import * as hardhat from 'hardhat';
import { ethers } from 'hardhat';
import { UnsafeBytesTest, UnsafeBytesTestFactory } from '../../typechain';

async function expectReadValues(contract: UnsafeBytesTest, types: string[], values: any[]) {
    // `solidityPack` checks that arrays have the same length.
    const bytesData = ethers.utils.solidityPack(types, values);

    let offset = BigNumber.from(0);
    for (let i = 0; i < types.length; ++i) {
        let readValue;

        switch (types[i]) {
            case 'address': {
                ({ readValue, offset } = await contract.readAddress(bytesData, offset));
                break;
            }
            case 'uint32': {
                ({ readValue, offset } = await contract.readUint32(bytesData, offset));
                break;
            }
            case 'uint256': {
                ({ readValue, offset } = await contract.readUint256(bytesData, offset));
                break;
            }
            case 'bytes32': {
                ({ readValue, offset } = await contract.readBytes32(bytesData, offset));
                break;
            }
        }
        expect(ethers.BigNumber.from(readValue)).equal(ethers.BigNumber.from(values[i]));
    }
}

describe('Unsafe bytes tests', function () {
    let testContract: UnsafeBytesTest;

    before(async () => {
        const unsafeBytesTestFactory = await hardhat.ethers.getContractFactory('UnsafeBytesTest');
        const unsafeBytesTestContract = await unsafeBytesTestFactory.deploy();
        testContract = UnsafeBytesTestFactory.connect(unsafeBytesTestContract.address, unsafeBytesTestContract.signer);
    });

    it('Read packed array', async () => {
        const types = ['address', 'address', 'uint256', 'uint32', 'uint32', 'address', 'bytes32', 'address'];
        const values = [
            '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
            '0x7aFd58312784ACf80E2ba97Dd84Ff2bADeA9e4A2',
            '0x15',
            '0xffffffff',
            '0x16',
            '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            '0x4845bfb858e60647a4f22f02d3712a20fa6b557288dbe97b6ae719390482ef4b',
            '0xaBEA9132b05A70803a4E85094fD0e1800777fBEF'
        ];
        await expectReadValues(testContract, types, values);
    });
});
