import { exec } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';
import { JsonRpcProvider, Contract, Wallet } from 'ethers';
import { ChainConfig, ChainAddresses, CoreDeployedAddresses, CTMDeployedAddresses } from './types';
import { parseForgeScriptOutput, ensureDirectoryExists, saveTomlConfig } from './utils';

const execAsync = promisify(exec);

export class ChainRegistry {
    private l1RpcUrl: string;
    private privateKey: string;
    private l1Provider: JsonRpcProvider;
    private wallet: Wallet;
    private projectRoot: string;
    private outputDir: string;
    private l1Addresses: CoreDeployedAddresses;
    private ctmAddresses: CTMDeployedAddresses;

    constructor(
        l1RpcUrl: string,
        privateKey: string,
        l1Addresses: CoreDeployedAddresses,
        ctmAddresses: CTMDeployedAddresses
    ) {
        this.l1RpcUrl = l1RpcUrl;
        this.privateKey = privateKey;
        this.l1Provider = new JsonRpcProvider(l1RpcUrl);
        this.wallet = new Wallet(privateKey, this.l1Provider);
        this.projectRoot = path.resolve(__dirname, '../../..');
        this.outputDir = path.join(__dirname, '../outputs');
        this.l1Addresses = l1Addresses;
        this.ctmAddresses = ctmAddresses;
        ensureDirectoryExists(this.outputDir);
    }

    async registerChain(config: ChainConfig): Promise<ChainAddresses> {
        console.log(`📝 Registering L2 chain ${config.chainId}...`);

        const configPath = await this.generateChainConfig(config);
        const outputPath = path.join(this.outputDir, `chain-${config.chainId}-output.toml`);

        const scriptPath = 'deploy-scripts/ctm/RegisterZKChain.s.sol:RegisterZKChainScript';

        const envVars = {
            CHAIN_CONFIG: configPath,
            CHAIN_OUTPUT: outputPath,
            BRIDGEHUB_ADDR: this.l1Addresses.bridgehub,
            CTM_ADDR: this.ctmAddresses.chainTypeManager,
        };

        await this.runForgeScript(scriptPath, envVars);

        const output = parseForgeScriptOutput(outputPath);

        console.log(`✅ Chain ${config.chainId} registered`);

        return {
            chainId: config.chainId,
            diamondProxy: output.diamond_proxy_addr || output.diamond_proxy,
        };
    }

    async initializeL2SystemContracts(chainId: number, chainProxy: string): Promise<void> {
        console.log(`🔧 Initializing L2 system contracts for chain ${chainId}...`);

        const bridgehubAbi = [
            'function requestL2TransactionDirect((uint256 chainId, uint256 mintValue, address l2Contract, uint256 l2Value, bytes l2Calldata, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, bytes[] factoryDeps, address refundRecipient) calldata) external payable returns (bytes32)',
        ];

        const bridgehub = new Contract(this.l1Addresses.bridgehub, bridgehubAbi, this.wallet);

        const l2Calldata = this.encodeL2SystemContractsInit();

        const tx = await bridgehub.requestL2TransactionDirect({
            chainId: chainId,
            mintValue: 0,
            l2Contract: '0x0000000000000000000000000000000000008006',
            l2Value: 0,
            l2Calldata: l2Calldata,
            l2GasLimit: 10000000,
            l2GasPerPubdataByteLimit: 800,
            factoryDeps: [],
            refundRecipient: await this.wallet.getAddress(),
        });

        await tx.wait();

        console.log(`✅ L2 system contracts initialized for chain ${chainId}`);
    }

    private async generateChainConfig(config: ChainConfig): Promise<string> {
        const configPath = path.join(__dirname, `../config/chain-${config.chainId}.toml`);

        const chainConfig = {
            chain: {
                chain_id: config.chainId,
                base_token_addr: config.baseToken,
                validium_mode: config.validiumMode,
                chain_type_manager_addr: this.ctmAddresses.chainTypeManager,
            },
            contracts: {
                bridgehub_proxy_addr: this.l1Addresses.bridgehub,
                state_transition_proxy_addr: this.ctmAddresses.chainTypeManager,
                transparent_proxy_admin_addr: this.l1Addresses.transparentProxyAdmin,
            },
        };

        saveTomlConfig(configPath, chainConfig);

        return configPath;
    }

    private encodeL2SystemContractsInit(): string {
        const { AbiCoder } = require('ethers');
        const abiCoder = new AbiCoder();

        return abiCoder.encode(
            ['address', 'address', 'address'],
            [
                '0x0000000000000000000000000000000000010002',
                '0x0000000000000000000000000000000000010003',
                '0x0000000000000000000000000000000000010004',
            ]
        );
    }

    private async runForgeScript(scriptPath: string, envVars: Record<string, string>): Promise<string> {
        const env = {
            ...process.env,
            ...envVars,
        };

        const command = `forge script ${scriptPath} --rpc-url ${this.l1RpcUrl} --private-key ${this.privateKey} --broadcast --legacy`;

        console.log(`   Running: ${scriptPath}`);

        try {
            const { stdout, stderr } = await execAsync(command, {
                cwd: this.projectRoot,
                env,
                maxBuffer: 10 * 1024 * 1024,
            });

            if (stderr && !stderr.includes('Warning')) {
                console.warn('   Forge stderr:', stderr);
            }

            return stdout;
        } catch (error: any) {
            console.error('❌ Forge script failed:');
            console.error('   Command:', command);
            console.error('   Error:', error.message);
            if (error.stdout) {
                console.error('   Stdout:', error.stdout);
            }
            if (error.stderr) {
                console.error('   Stderr:', error.stderr);
            }
            throw error;
        }
    }
}
