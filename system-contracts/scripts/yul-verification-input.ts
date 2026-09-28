import assert from "assert";

export interface CompilerInput {
  language: string;
  sources: Record<string, { content: string }>;
  settings: { llvmOptions?: string[]; [key: string]: unknown };
}

export function parseForgeCompilerInput(output: string): CompilerInput {
  // Foundry can print informational lines before the Standard JSON payload.
  const lines = output.split("\n");
  const start = lines.findIndex((line) => line.trimStart().startsWith("{"));
  if (start < 0) throw new Error("Foundry did not return Standard JSON input");
  return JSON.parse(lines.slice(start).join("\n"));
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
  return {
    contractAddress: address,
    contractName,
    // Foundry v0.1.5 labels --show-standard-json-input as Solidity even for Yul.
    // Correct the language; preserve every setting, source path and source byte.
    sourceCode: { ...input, language: "Yul" },
    codeFormat: "solidity-standard-json-input",
    compilerZksolcVersion,
    compilerSolcVersion,
    optimizationUsed: true,
    constructorArguments: "0x",
    isSystem: true,
  };
}
