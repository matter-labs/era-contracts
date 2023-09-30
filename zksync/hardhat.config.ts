import '@nomicfoundation/hardhat-chai-matchers';
import '@nomiclabs/hardhat-solpp';
import '@matterlabs/hardhat-zksync-solc';
import '@nomiclabs/hardhat-ethers';
import '@matterlabs/hardhat-zksync-verify';
import 'hardhat-typechain';

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
    require('dotenv').config();
}

export default {
    zksolc: {
        version: '1.3.11',
        compilerSource: 'binary',
        settings: {
            isSystem: true
        }
    },
    solidity: {
        version: '0.8.19'
    },
    defaultNetwork: 'localhost',
    networks: {
        localhost: {
            // era-test-node default url
            url: 'http://127.0.0.1:8011', 
            ethNetwork: null,
            zksync: true
        },
        zkSyncTestnet: {
            url: 'https://zksync2-testnet.zksync.dev',
            ethNetwork: 'goerli',
            zksync: true,
            // contract verification endpoint
            verifyURL: 'https://zksync2-testnet-explorer.zksync.dev/contract_verification'
        },
        zksyncMainnet: {
            url: 'https://mainnet.era.zksync.io',
            ethNetwork: 'mainnet',
            zksync: true,
            // contract verification endpoint
            verifyURL: 'https://zksync2-mainnet-explorer.zksync.io/contract_verification'
        }
    }
};
