import assert from "assert";

// zksolc ends every bytecode with its CBOR metadata followed by the metadata length.
const CBOR_LENGTH_BYTES = 2;
// In a Solidity build the CBOR `solc` entry names zksolc, solc and the zkVM-solc revision (`llvm`);
// the explorer verifier reads it back as zkVM-<solc>-<revision>.
const SOLIDITY_BUILD_COMPILERS = /zksolc:(\d+\.\d+\.\d+);solc:(\d+\.\d+\.\d+);llvm:(\d+\.\d+\.\d+)/;

export interface CompilerInput {
  language: string;
  sources: Record<string, { content: string }>;
  settings: { llvmOptions?: string[]; remappings?: string[]; [key: string]: unknown };
}

export function parseForgeCompilerInput(output: string): CompilerInput {
  // Foundry can print informational lines before the Standard JSON payload.
  const lines = output.split("\n");
  const start = lines.findIndex((line) => line.trimStart().startsWith("{"));
  if (start < 0) throw new Error("Foundry did not return Standard JSON input");
  return JSON.parse(lines.slice(start).join("\n"));
}

// The compiler versions a Solidity artifact was built with, as a verification request names them.
export function compilerVersionsFromBytecode(bytecode: string) {
  const code = Buffer.from(bytecode.replace(/^0x/, ""), "hex");
  const metadataEnd = code.length - CBOR_LENGTH_BYTES;
  const metadataStart = metadataEnd - code.readUInt16BE(metadataEnd);
  const match =
    metadataStart >= 0 && SOLIDITY_BUILD_COMPILERS.exec(code.subarray(metadataStart, metadataEnd).toString("latin1"));
  if (!match) throw new Error("Bytecode metadata does not record the zksolc and zkVM-solc versions");
  return { zksolc: `v${match[1]}`, solc: `zkVM-${match[2]}-${match[3]}` };
}

export function yulVerificationRequest(
  input: CompilerInput,
  address: string,
  contractName: string,
  compilerZksolcVersion: string,
  compilerSolcVersion: string,
  expectedLlvmOptions: string[]
) {
  const sourcePath = contractName.slice(0, contractName.lastIndexOf(":"));
  if (!sourcePath.endsWith(".yul") || !input.sources[sourcePath]) {
    throw new Error(`Missing Yul source for ${contractName}`);
  }
  if (!Object.keys(input.sources).every((name) => name.endsWith(".yul"))) {
    throw new Error("Refusing to relabel mixed Solidity/Yul compiler input");
  }
  assert.deepStrictEqual(input.settings.llvmOptions ?? [], expectedLlvmOptions, "Verification lost LLVM options");
  if (
    !/^v\d+\.\d+\.\d+$/.test(compilerZksolcVersion) ||
    !/^zkVM-\d+\.\d+\.\d+-\d+\.\d+\.\d+$/.test(compilerSolcVersion)
  ) {
    throw new Error("Exact released zksolc and zkVM-solc versions are required");
  }
  // solc rejects `settings.remappings` in Yul input. Yul has no imports and zksolc leaves the
  // field out of the bytecode and its metadata, so dropping it keeps the build's bytecode.
  const settings = { ...input.settings };
  delete settings.remappings;
  return {
    contractAddress: address,
    contractName,
    // Foundry v0.1.5 labels --show-standard-json-input as Solidity even for Yul.
    // Correct the language; preserve every other setting, source path and source byte.
    sourceCode: { ...input, language: "Yul", settings },
    codeFormat: "solidity-standard-json-input",
    compilerZksolcVersion,
    compilerSolcVersion,
    optimizationUsed: true,
    constructorArguments: "0x",
    isSystem: true,
  };
}
