import { JsonRpcProvider } from 'ethers';
import { parse as parseToml } from '@iarna/toml';
import * as fs from 'fs';
import * as path from 'path';

export async function waitForChainReady(rpcUrl: string, maxAttempts = 30): Promise<boolean> {
    const provider = new JsonRpcProvider(rpcUrl);

    for (let i = 0; i < maxAttempts; i++) {
        try {
            const chainId = await provider.send('eth_chainId', []);
            if (chainId) {
                console.log(`✅ Chain ready at ${rpcUrl}, chainId: ${chainId}`);
                return true;
            }
        } catch (error) {
            await sleep(1000);
        }
    }

    console.error(`❌ Chain at ${rpcUrl} not ready after ${maxAttempts} attempts`);
    return false;
}

export function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export function loadTomlConfig<T>(filePath: string): T {
    const content = fs.readFileSync(filePath, 'utf-8');
    return parseToml(content) as T;
}

export function saveTomlConfig(filePath: string, data: any): void {
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }

    const lines: string[] = [];

    function writeSection(obj: any, prefix = ''): void {
        for (const [key, value] of Object.entries(obj)) {
            const fullKey = prefix ? `${prefix}.${key}` : key;

            if (value && typeof value === 'object' && !Array.isArray(value)) {
                lines.push(`\n[${fullKey}]`);
                writeSection(value, fullKey);
            } else if (typeof value === 'string') {
                lines.push(`${key} = "${value}"`);
            } else if (typeof value === 'boolean') {
                lines.push(`${key} = ${value}`);
            } else if (typeof value === 'number') {
                lines.push(`${key} = ${value}`);
            } else if (Array.isArray(value)) {
                lines.push(`${key} = [${value.map((v) => (typeof v === 'string' ? `"${v}"` : v)).join(', ')}]`);
            }
        }
    }

    writeSection(data);
    fs.writeFileSync(filePath, lines.join('\n'));
}

export function parseForgeScriptOutput(outputPath: string): any {
    if (!fs.existsSync(outputPath)) {
        throw new Error(`Output file not found: ${outputPath}`);
    }

    const content = fs.readFileSync(outputPath, 'utf-8');
    return parseToml(content);
}

export function ensureDirectoryExists(dirPath: string): void {
    if (!fs.existsSync(dirPath)) {
        fs.mkdirSync(dirPath, { recursive: true });
    }
}

export function keccak256Hash(data: string): string {
    const { keccak256, toUtf8Bytes } = require('ethers');
    return keccak256(toUtf8Bytes(data));
}

export function encodeSystemLogs(logs: any[]): string {
    if (logs.length === 0) {
        return '0x';
    }

    const { AbiCoder } = require('ethers');
    const abiCoder = new AbiCoder();
    return abiCoder.encode(['bytes[]'], [logs.map((log) => log.data || '0x')]);
}

export function hexToBytes(hex: string): Uint8Array {
    if (hex.startsWith('0x')) {
        hex = hex.slice(2);
    }
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
}

export function bytesToHex(bytes: Uint8Array): string {
    return '0x' + Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function waitForTransactionReceipt(
    provider: JsonRpcProvider,
    txHash: string,
    maxAttempts = 60
): Promise<any> {
    for (let i = 0; i < maxAttempts; i++) {
        try {
            const receipt = await provider.getTransactionReceipt(txHash);
            if (receipt && receipt.blockNumber) {
                return receipt;
            }
        } catch (error) {
            // Transaction not found yet
        }
        await sleep(1000);
    }
    throw new Error(`Transaction ${txHash} not confirmed after ${maxAttempts} attempts`);
}

export function formatChainInfo(chainId: number, port: number, isL1: boolean): string {
    const type = isL1 ? 'L1' : 'L2';
    return `${type} Chain ${chainId} on port ${port}`;
}

export function getDefaultAccountPrivateKey(): string {
    // Default Anvil account #0 private key
    return '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
}

export function getDefaultAccountAddress(): string {
    // Default Anvil account #0 address
    return '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
}
