import { artifacts } from 'hardhat';

import { deployedAddressesFromEnv } from '../../ethereum/src.ts/deploy';
import { IZkSyncFactory } from '../../ethereum/typechain/IZkSyncFactory';
import { Interface } from 'ethers/lib/utils';

import { ethers, Wallet, BytesLike } from 'ethers';
import { Provider } from 'zksync-web3';
import { sleep } from 'zksync-web3/build/src/utils';

export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = '0x0000000000000000000000000000000000008006';
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(['string'], ['zksyncCreate2']);
const L1_TO_L2_ALIAS_OFFSET = '0x1111000000000000000000000000000000001111';
const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);

export function applyL1ToL2Alias(address: string): string {
    return ethers.utils.hexlify(ethers.BigNumber.from(address).add(L1_TO_L2_ALIAS_OFFSET).mod(ADDRESS_MODULO));
}

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
    l2GasLimit: ethers.BigNumberish,
    gasPrice?: ethers.BigNumberish
) {
    const zkSyncAddress = deployedAddressesFromEnv().ZkSync.DiamondProxy;
    const zkSync = IZkSyncFactory.connect(zkSyncAddress, wallet);

    const deployerSystemContracts = new Interface(artifacts.readArtifactSync('IContractDeployer').abi);
    const bytecodeHash = hashL2Bytecode(bytecode);
    const calldata = deployerSystemContracts.encodeFunctionData('create2', [create2Salt, bytecodeHash, constructor]);
    gasPrice ??= await zkSync.provider.getGasPrice();
    const expectedCost = await zkSync.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

    return await zkSync.requestL2Transaction(
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

export async function awaitPriorityOps(
    zksProvider: Provider,
    l1TxReceipt: ethers.providers.TransactionReceipt,
    zksyncInterface: ethers.utils.Interface
) {
    const deployL2TxHashes = l1TxReceipt.logs
        .map((log) => zksyncInterface.parseLog(log))
        .filter((event) => event.name === 'NewPriorityRequest')
        .map((event) => event.args[1]);
    for (const txHash of deployL2TxHashes) {
        console.log('Awaiting L2 transaction with hash: ', txHash);
        let receipt = null;
        while (receipt == null) {
            receipt = await zksProvider.getTransactionReceipt(txHash);
            await sleep(100);
        }

        if (receipt.status != 1) {
            throw new Error('Failed to process L2 tx');
        }
    }
}
