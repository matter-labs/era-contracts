import * as fs from "fs";
import * as path from "path";
import * as blakejs from "blakejs";

/** Loads a Foundry artifact from /out/<name>.sol/<name>.json */
function loadArtifact(name: string) {
    const artifactPath = path.join(__dirname, `../out/${name}.sol/${name}.json`);
    const data = fs.readFileSync(artifactPath, "utf-8");
    return JSON.parse(data);
}

/** Extracts deployedBytecode.runtime from artifact */
function loadDeployedBytecode(name: string): string {
    const artifact = loadArtifact(name);
    return artifact.deployedBytecode.object; // runtime bytecode
}

// Helper to convert a hex string to Uint8Array
function hexToBytes(hex: string): Uint8Array {
    if (hex.startsWith("0x")) hex = hex.slice(2);
    if (hex.length % 2 !== 0) {
        throw new Error("Invalid hex string");
    }
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }
    return bytes;
}


async function main() {
    // 1. Load all contract names
    const contractNames = [
        "SystemContractProxy",
        "SystemContractProxyAdmin",
        "L2ComplexUpgrader",
        "L2MessageRoot",
        "L2Bridgehub",
        "L2AssetRouter",
        "L2NativeTokenVaultZKOS",
        "L2ChainAssetHandler",
        "UpgradeableBeaconDeployer",
        "L2SystemProxiesUpgrade"
    ];

    // 2. Calculate blake2s256 hash for each deployedBytecode
    const hashToBytecode: Record<string, string> = {};
    for (const name of contractNames) {
        const bytecode = loadDeployedBytecode(name);
        const bytecodeBytes = hexToBytes(bytecode);
        const hash = blakejs.blake2sHex(bytecodeBytes);
        hashToBytecode[hash] = bytecode;
        console.log(`${name}: ${hash}`);
    }

    // 3. Write mapping to JSON file
    const outputPath = path.join(__dirname, "zksync-os-bytecode-hashes.json");
    fs.writeFileSync(outputPath, JSON.stringify(hashToBytecode, null, 2));
    console.log(`Hash-to-bytecode mapping written to ${outputPath}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
