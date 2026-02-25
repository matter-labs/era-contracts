import { providers, utils } from "ethers";
import { parse as parseToml } from "toml";
import * as fs from "fs";
import * as path from "path";
import { L2_NATIVE_TOKEN_VAULT_ADDR } from "./const";

export async function waitForChainReady(rpcUrl: string, maxAttempts = 30): Promise<boolean> {
  const provider = new providers.JsonRpcProvider(rpcUrl);

  for (let i = 0; i < maxAttempts; i++) {
    try {
      const chainId = await provider.send("eth_chainId", []);
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

export function saveTomlConfig(filePath: string, data: Record<string, unknown>): void {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const lines: string[] = [];

  function writeSection(obj: Record<string, unknown>, prefix = ""): void {
    for (const [key, value] of Object.entries(obj)) {
      const fullKey = prefix ? `${prefix}.${key}` : key;

      if (value && typeof value === "object" && !Array.isArray(value)) {
        lines.push(`\n[${fullKey}]`);
        writeSection(value as Record<string, unknown>, fullKey);
      } else if (typeof value === "string") {
        lines.push(`${key} = "${value}"`);
      } else if (typeof value === "boolean") {
        lines.push(`${key} = ${value}`);
      } else if (typeof value === "number") {
        lines.push(`${key} = ${value}`);
      } else if (Array.isArray(value)) {
        lines.push(`${key} = [${value.map((v) => (typeof v === "string" ? `"${v}"` : v)).join(", ")}]`);
      }
    }
  }

  writeSection(data);
  fs.writeFileSync(filePath, lines.join("\n"));
}

export function parseForgeScriptOutput(outputPath: string): Record<string, unknown> {
  if (!fs.existsSync(outputPath)) {
    throw new Error(`Output file not found: ${outputPath}`);
  }

  const content = fs.readFileSync(outputPath, "utf-8");
  return parseToml(content);
}

export function ensureDirectoryExists(dirPath: string): void {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

export function encodeNtvAssetId(chainId: number, tokenAddress: string): string {
  const abiCoder = new utils.AbiCoder();
  return utils.keccak256(
    abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress])
  );
}

export function formatChainInfo(chainId: number, port: number, isL1: boolean): string {
  const type = isL1 ? "L1" : "L2";
  return `${type} Chain ${chainId} on port ${port}`;
}

export function getDefaultAccountPrivateKey(): string {
  // Default Anvil account #0 private key
  return "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function loadAbiFromOut(artifactRelativePath: string): any[] {
  return loadArtifactFromOut(artifactRelativePath).abi;
}

export function loadBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.deployedBytecode?.object || artifact.bytecode?.object || "0x";
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function loadArtifactFromOut(artifactRelativePath: string): any {
  const outRoot = path.resolve(__dirname, "../../../out");
  const artifactPath = path.join(outRoot, artifactRelativePath);
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
}
