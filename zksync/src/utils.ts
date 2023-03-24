import { artifacts } from 'hardhat';

import { deployedAddressesFromEnv } from '../../ethereum/src.ts/deploy';
import { IZkSyncFactory } from '../../ethereum/typechain/IZkSyncFactory';
import { Interface } from 'ethers/lib/utils';

import { ethers, Wallet, BytesLike } from 'ethers';

export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = '0x0000000000000000000000000000000000008006';
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(['string'], ['zksyncCreate2']);

export function hashL2Bytecode(bytecode: ethers.BytesLike): Uint8Array {
    // For getting the consistent length we first convert the bytecode to UInt8Array
    const bytecodeAsArray = ethers.utils.arrayify(bytecode);

    if (bytecodeAsArray.length % 32 != 0) {
        throw new Error('The bytecode length in bytes must be divisible by 32');
    }

    const hashStr = ethers.utils.sha256(bytecodeAsArray);
    const hash = ethers.utils.arrayify(hashStr);

    // Note that the length of the bytecode
    // should be provided in 32-byte words.
    const bytecodeLengthInWords = bytecodeAsArray.length / 32;
    if (bytecodeLengthInWords % 2 == 0) {
        throw new Error('Bytecode length in 32-byte words must be odd');
    }
    const bytecodeLength = ethers.utils.arrayify(bytecodeAsArray.length / 32);
    if (bytecodeLength.length > 2) {
        throw new Error('Bytecode length must be less than 2^16 bytes');
    }
    // The bytecode should always take the first 2 bytes of the bytecode hash,
    // so we pad it from the left in case the length is smaller than 2 bytes.
    const bytecodeLengthPadded = ethers.utils.zeroPad(bytecodeLength, 2);

    const codeHashVersion = new Uint8Array([1, 0]);
    hash.set(codeHashVersion, 0);
    hash.set(bytecodeLengthPadded, 2);

    return hash;
}

export function computeL2Create2Address(
    deployWallet: Wallet,
    bytecode: BytesLike,
    constructorInput: BytesLike,
    create2Salt: BytesLike
) {
    const senderBytes = ethers.utils.hexZeroPad(deployWallet.address, 32);
    const bytecodeHash = hashL2Bytecode(bytecode);
    const constructorInputHash = ethers.utils.keccak256(constructorInput);

    const data = ethers.utils.keccak256(
        ethers.utils.concat([CREATE2_PREFIX, senderBytes, create2Salt, bytecodeHash, constructorInputHash])
    );

    return ethers.utils.hexDataSlice(data, 12);
}

export async function create2DeployFromL1(
    wallet: ethers.Wallet,
    bytecode: ethers.BytesLike,
    constructor: ethers.BytesLike,
    create2Salt: ethers.BytesLike,
    l2GasLimit: ethers.BigNumberish
) {
    const zkSyncAddress = deployedAddressesFromEnv().ZkSync.DiamondProxy;
    const zkSync = IZkSyncFactory.connect(zkSyncAddress, wallet);

    const deployerSystemContracts = new Interface(artifacts.readArtifactSync('IContractDeployer').abi);
    const bytecodeHash = hashL2Bytecode(bytecode);
    const calldata = deployerSystemContracts.encodeFunctionData('create2', [create2Salt, bytecodeHash, constructor]);
    const gasPrice = await zkSync.provider.getGasPrice();
    const expectedCost = await zkSync.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

    await zkSync.requestL2Transaction(
        DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
        0,
        calldata,
        l2GasLimit,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        [bytecode],
        wallet.address,
        { value: expectedCost, gasPrice }
    );
}

export function getNumberFromEnv(envName: string): string {
    let number = process.env[envName];
    if (!/^([1-9]\d*|0)$/.test(number)) {
        throw new Error(`Incorrect number format number in ${envName} env: ${number}`);
    }
    return number;
}
