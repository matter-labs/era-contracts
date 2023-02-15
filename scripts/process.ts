const preprocess = require('preprocess');

import { existsSync, mkdirSync, write, writeFileSync } from 'fs';
import { getRevertSelector, getTransactionUtils } from './constants';
import * as hre from 'hardhat';
import { ethers } from 'ethers';
import { renderFile } from 'template-file';

const OUTPUT_DIR = 'bootloader/build';


function getSelector(contractName: string, method: string): string {
    const artifact = hre.artifacts.readArtifactSync(contractName);
    const contractInterface = new ethers.utils.Interface(artifact.abi);

    return contractInterface.getSighash(method);
}

// Methods from ethers do zero pad from left, but we need to pad from the right
function padZeroRight(hexData: string, length: number): string {
    while (hexData.length < length) {
        hexData += '0';
    }

    return hexData;
}

const PADDED_SELECTOR_LENGTH = 32 * 2 + 2;
function getPaddedSelector(contractName: string, method: string): string {
    let result = getSelector(contractName, method);

    return padZeroRight(result, PADDED_SELECTOR_LENGTH)
}

const SYSTEM_PARAMS = require('../SystemConfig.json');

// Maybe in the future some of these params will be passed
// in a JSON file. For now, a simple object is ok here.
let params = {
    MARK_BATCH_AS_REPUBLISHED_SELECTOR: getSelector('KnownCodesStorage', 'markFactoryDeps'),
    VALIDATE_TX_SELECTOR: getSelector('IAccount', 'validateTransaction'),
    EXECUTE_TX_SELECTOR: getSelector('DefaultAccount', 'executeTransaction'),
    RIGHT_PADDED_GET_ACCOUNT_VERSION_SELECTOR: getPaddedSelector('ContractDeployer','extendedAccountVersion'),
    RIGHT_PADDED_GET_RAW_CODE_HASH_SELECTOR: getPaddedSelector('AccountCodeStorage', 'getRawCodeHash'),
    PAY_FOR_TX_SELECTOR: getSelector('DefaultAccount', 'payForTransaction'),
    PRE_PAYMASTER_SELECTOR: getSelector('DefaultAccount', 'prepareForPaymaster'),
    VALIDATE_AND_PAY_PAYMASTER: getSelector('IPaymaster', 'validateAndPayForPaymasterTransaction'),
    // It doesn't used directly now but is important to keep the way to regenerate it when needed
    TX_UTILITIES: getTransactionUtils(),
    RIGHT_PADDED_POST_TRANSACTION_SELECTOR: getPaddedSelector('IPaymaster', 'postTransaction'),
    RIGHT_PADDED_SET_TX_ORIGIN: getPaddedSelector('SystemContext', 'setTxOrigin'),
    RIGHT_PADDED_SET_GAS_PRICE: getPaddedSelector('SystemContext', 'setGasPrice'),
    RIGHT_PADDED_SET_NEW_BLOCK_SELECTOR: getPaddedSelector('SystemContext', 'setNewBlock'),
    RIGHT_PADDED_OVERRIDE_BLOCK_SELECTOR: getPaddedSelector('SystemContext', 'unsafeOverrideBlock'),
    // Error
    REVERT_ERROR_SELECTOR: padZeroRight(getRevertSelector(), PADDED_SELECTOR_LENGTH),
    RIGHT_PADDED_VALIDATE_NONCE_USAGE_SELECTOR: getPaddedSelector('INonceHolder', 'validateNonceUsage'),
    RIGHT_PADDED_MINT_ETHER_SELECTOR: getPaddedSelector('L2EthToken', 'mint'),
    GET_TX_HASHES_SELECTOR: getSelector('BootloaderUtilities', 'getTransactionHashes'),
    CREATE_SELECTOR: getSelector('ContractDeployer','create'),
    CREATE2_SELECTOR: getSelector('ContractDeployer','create2'),
    CREATE_ACCOUNT_SELECTOR: getSelector('ContractDeployer','createAccount'),
    CREATE2_ACCOUNT_SELECTOR: getSelector('ContractDeployer','create2Account'),
    PADDED_TRANSFER_FROM_TO_SELECTOR: getPaddedSelector('L2EthToken', 'transferFromTo'),
    SUCCESSFUL_ACCOUNT_VALIDATION_MAGIC_VALUE: getPaddedSelector('IAccount', 'validateTransaction'),
    SUCCESSFUL_PAYMASTER_VALIDATION_MAGIC_VALUE: getPaddedSelector('IPaymaster', 'validateAndPayForPaymasterTransaction'),
    ENSURE_RETURNED_MAGIC: 1,
    FORBID_ZERO_GAS_PER_PUBDATA: 1,
    ...SYSTEM_PARAMS
};

async function main() {
    const bootloader = await renderFile('bootloader/bootloader.yul', params);
    // The overhead is unknown for gas tests and so it should be zero to calculate it 
    const gasTestBootloaderTemplate = await renderFile('bootloader/bootloader.yul', {
        ...params,
        L2_TX_INTRINSIC_GAS: 0,
        L2_TX_INTRINSIC_PUBDATA: 0,
        L1_TX_INTRINSIC_L2_GAS: 0,
        L1_TX_INTRINSIC_PUBDATA: 0,
        FORBID_ZERO_GAS_PER_PUBDATA: 0
    })

    const feeEstimationBootloaderTemplate = await renderFile('bootloader/bootloader.yul', {
        ...params,
        ENSURE_RETURNED_MAGIC: 0
    });

    console.log('Preprocessing production bootloader');
    const provedBlockBootloader = preprocess.preprocess(
        bootloader,
        { BOOTLOADER_TYPE: 'proved_block' }
    );    
    console.log('Preprocessing playground block bootloader');
    const playgroundBlockBootloader = preprocess.preprocess(
        bootloader,
        { BOOTLOADER_TYPE: 'playground_block' }
    );
    console.log('Preprocessing gas test bootloader');
    const gasTestBootloader = preprocess.preprocess(
        gasTestBootloaderTemplate,
        { BOOTLOADER_TYPE: 'proved_block' }
    );
    console.log('Preprocessing fee estimation bootloader');
    const feeEstimationBootloader = preprocess.preprocess(
        feeEstimationBootloaderTemplate,
        { BOOTLOADER_TYPE: 'playground_block' }
    );

    if(!existsSync(OUTPUT_DIR)) {
        mkdirSync(OUTPUT_DIR);
    }

    writeFileSync(`${OUTPUT_DIR}/proved_block.yul`, provedBlockBootloader);
    writeFileSync(`${OUTPUT_DIR}/playground_block.yul`, playgroundBlockBootloader);
    writeFileSync(`${OUTPUT_DIR}/gas_test.yul`, gasTestBootloader);
    writeFileSync(`${OUTPUT_DIR}/fee_estimate.yul`, feeEstimationBootloader);

    console.log('Preprocessing done!');
}

main();
