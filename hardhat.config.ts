import '@nomiclabs/hardhat-solpp';
import '@typechain/hardhat';
import '@nomiclabs/hardhat-ethers';
import '@matterlabs/hardhat-zksync-solc';
import '@matterlabs/hardhat-zksync-chai-matchers';

const systemConfig = require('./SystemConfig.json');

export default {
    zksolc: {
        version: '1.3.14',
        compilerSource: 'binary',
        settings: {
            isSystem: true
        }
    },
    zkSyncDeploy: {
        zkSyncNetwork: 'http://localhost:3050',
        ethNetwork: 'http://localhost:8545'
    },
    solidity: {
        version: '0.8.17',
        settings: {
            optimizer: {
              enabled: true,
              runs: 200
            },
            viaIR: true
        }
    },
    solpp: {
        defs: (() => {
            return {
                ECRECOVER_COST_GAS: systemConfig.ECRECOVER_COST_GAS,
                KECCAK_ROUND_COST_GAS: systemConfig.KECCAK_ROUND_COST_GAS,
                SHA256_ROUND_COST_GAS: systemConfig.SHA256_ROUND_COST_GAS
            }
        })()
    },
    networks: {
        hardhat: {
            zksync: true
        },
        zkSyncTestNode: {
            url: 'http://127.0.0.1:8011',
            ethNetwork: '',
            zksync: true
        }
    }
};
