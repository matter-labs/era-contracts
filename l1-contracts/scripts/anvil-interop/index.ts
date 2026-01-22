#!/usr/bin/env node

import * as fs from 'fs';
import * as path from 'path';
import { JsonRpcProvider } from 'ethers';
import { AnvilManager } from './src/anvil-manager';
import { ForgeDeployer } from './src/deployer';
import { ChainRegistry } from './src/chain-registry';
import { GatewaySetup } from './src/gateway-setup';
import { BatchSettler } from './src/batch-settler';
import { AnvilConfig, DeploymentContext, ChainAddresses } from './src/types';
import { getDefaultAccountPrivateKey, sleep } from './src/utils';

async function main() {
    console.log('🚀 Starting Multi-Chain Anvil Testing Environment\n');

    const configPath = path.join(__dirname, 'config/anvil-config.json');
    const config: AnvilConfig = JSON.parse(fs.readFileSync(configPath, 'utf-8'));

    const anvilManager = new AnvilManager();
    const privateKey = getDefaultAccountPrivateKey();

    let context: DeploymentContext | undefined;
    let settler: BatchSettler | undefined;

    const cleanup = async () => {
        console.log('\n🧹 Cleaning up...');
        if (settler) {
            await settler.stop();
        }
        await anvilManager.stopAll();
        process.exit(0);
    };

    process.on('SIGINT', cleanup);
    process.on('SIGTERM', cleanup);

    try {
        console.log('=== Step 1: Starting Anvil Chains ===\n');
        for (const chainConfig of config.chains) {
            await anvilManager.startChain({
                chainId: chainConfig.chainId,
                port: chainConfig.port,
                isL1: chainConfig.isL1,
            });
        }

        await sleep(2000);

        const l1Chain = anvilManager.getL1Chain();
        if (!l1Chain) {
            throw new Error('L1 chain not found');
        }

        const l1Provider = anvilManager.getProvider(l1Chain.chainId);

        console.log('\n=== Step 2: Deploying L1 Contracts ===\n');

        const deployer = new ForgeDeployer(l1Chain.rpcUrl, privateKey);

        const l1Addresses = await deployer.deployL1Core();
        console.log('\nL1 Core Addresses:');
        console.log(`  Bridgehub: ${l1Addresses.bridgehub}`);
        console.log(`  L1SharedBridge: ${l1Addresses.l1SharedBridge}`);

        const ctmAddresses = await deployer.deployCTM(l1Addresses.bridgehub);
        console.log('\nCTM Addresses:');
        console.log(`  ChainTypeManager: ${ctmAddresses.chainTypeManager}`);

        await deployer.registerCTM(l1Addresses.bridgehub, ctmAddresses.chainTypeManager);

        console.log('\n=== Step 3: Registering L2 Chains ===\n');

        const registry = new ChainRegistry(l1Chain.rpcUrl, privateKey, l1Addresses, ctmAddresses);

        const l2Providers: Map<number, JsonRpcProvider> = new Map();
        const chainAddresses: Map<number, ChainAddresses> = new Map();

        const l2Chains = anvilManager.getL2Chains();

        for (const l2Chain of l2Chains) {
            const l2Provider = anvilManager.getProvider(l2Chain.chainId);
            l2Providers.set(l2Chain.chainId, l2Provider);

            const chainConfig = config.chains.find((c) => c.chainId === l2Chain.chainId);
            const isGateway = chainConfig?.isGateway || false;

            const addresses = await registry.registerChain({
                chainId: l2Chain.chainId,
                rpcUrl: l2Chain.rpcUrl,
                baseToken: '0x0000000000000000000000000000000000000001',
                validiumMode: false,
                isGateway,
            });

            chainAddresses.set(l2Chain.chainId, addresses);

            console.log(`  Chain ${l2Chain.chainId} registered at: ${addresses.diamondProxy}`);
        }

        console.log('\n=== Step 4: Initializing L2 System Contracts ===\n');

        for (const [chainId, addresses] of chainAddresses.entries()) {
            await registry.initializeL2SystemContracts(chainId, addresses.diamondProxy);
            console.log(`  Chain ${chainId} system contracts initialized`);
        }

        console.log('\n=== Step 5: Setting Up Gateway ===\n');

        const gatewayChainId = config.chains.find((c) => c.isGateway)?.chainId;
        if (gatewayChainId) {
            const gatewaySetup = new GatewaySetup(l1Chain.rpcUrl, privateKey, l1Addresses, ctmAddresses);

            const gatewayCTMAddr = await gatewaySetup.designateAsGateway(gatewayChainId);

            console.log(`  Gateway CTM: ${gatewayCTMAddr}`);

            context = {
                l1Provider,
                l2Providers,
                l1Addresses,
                ctmAddresses,
                chainAddresses,
                gatewayChainId,
            };
        }

        console.log('\n=== Step 6: Starting Batch Settler Daemon ===\n');

        settler = new BatchSettler(
            l1Provider,
            l2Providers,
            privateKey,
            chainAddresses,
            config.batchSettler.pollingIntervalMs,
            config.batchSettler.batchSizeLimit
        );

        await settler.start();

        console.log('\n=== ✅ Multi-Chain Environment Ready ===\n');
        console.log('Environment Details:');
        console.log(`  L1 Chain: ${l1Chain.chainId} at ${l1Chain.rpcUrl}`);
        for (const l2Chain of l2Chains) {
            const isGateway = l2Chain.chainId === gatewayChainId ? ' (Gateway)' : '';
            console.log(`  L2 Chain: ${l2Chain.chainId} at ${l2Chain.rpcUrl}${isGateway}`);
        }
        console.log('\nPress Ctrl+C to stop all chains and exit.\n');

        await keepAlive();
    } catch (error) {
        console.error('\n❌ Setup failed:', error);
        await cleanup();
        process.exit(1);
    }
}

async function keepAlive(): Promise<void> {
    while (true) {
        await sleep(10000);
    }
}

main();
