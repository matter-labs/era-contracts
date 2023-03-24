import '@nomiclabs/hardhat-waffle';
import '@nomiclabs/hardhat-solpp';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-etherscan';
import 'hardhat-typechain';
import 'hardhat-contract-sizer';
import { getNumberFromEnv } from './scripts/utils';

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
    require('dotenv').config();
}

const systemParams = require('../SystemConfig.json');

const PRIORITY_TX_MAX_GAS_LIMIT = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv('CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT');

const prodConfig = {
    UPGRADE_NOTICE_PERIOD: 0,
    // PRIORITY_EXPIRATION: 101,
    // NOTE: Should be greater than 0, otherwise zero approvals will be enough to make an instant upgrade!
    SECURITY_COUNCIL_APPROVALS_FOR_EMERGENCY_UPGRADE: 1,
    PRIORITY_TX_MAX_GAS_LIMIT,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    DUMMY_VERIFIER: false
};
const testnetConfig = {
    UPGRADE_NOTICE_PERIOD: 0,
    // PRIORITY_EXPIRATION: 101,
    // NOTE: Should be greater than 0, otherwise zero approvals will be enough to make an instant upgrade!
    SECURITY_COUNCIL_APPROVALS_FOR_EMERGENCY_UPGRADE: 1,
    PRIORITY_TX_MAX_GAS_LIMIT,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    DUMMY_VERIFIER: true
};
const testConfig = {
    UPGRADE_NOTICE_PERIOD: 0,
    PRIORITY_EXPIRATION: 101,
    SECURITY_COUNCIL_APPROVALS_FOR_EMERGENCY_UPGRADE: 2,
    PRIORITY_TX_MAX_GAS_LIMIT,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    DUMMY_VERIFIER: true
};
const localConfig = {
    ...prodConfig,
    DUMMY_VERIFIER: true
};

const contractDefs = {
    rinkeby: testnetConfig,
    ropsten: testnetConfig,
    goerli: testnetConfig,
    mainnet: prodConfig,
    test: testConfig,
    localhost: localConfig
};

export default {
    defaultNetwork: 'env',
    solidity: {
        version: '0.8.17',
        settings: {
            optimizer: {
                enabled: true,
                runs: 200
            },
            outputSelection: {
                '*': {
                    '*': ['storageLayout']
                }
            }
        }
    },
    contractSizer: {
        runOnCompile: false
    },
    paths: {
        sources: './contracts'
    },
    solpp: {
        defs: (() => {
            const defs = process.env.CONTRACT_TESTS ? contractDefs.test : contractDefs[process.env.CHAIN_ETH_NETWORK];

            return {
                ...systemParams,
                ...defs
            };
        })()
    },
    networks: {
        env: {
            url: process.env.ETH_CLIENT_WEB3_URL?.split(',')[0]
        },
        hardhat: {
            allowUnlimitedContractSize: false,
            forking: {
                url: 'https://eth-goerli.g.alchemy.com/v2/' + process.env.ALCHEMY_KEY,
                enabled: process.env.TEST_CONTRACTS_FORK === '1'
            }
        }
    },
    etherscan: {
        apiKey: process.env.MISC_ETHERSCAN_API_KEY
    }
};
