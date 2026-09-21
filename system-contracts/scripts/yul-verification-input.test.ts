import assert from "assert";
import { parseForgeCompilerInput, yulVerificationRequest } from "./yul-verification-input";
import type { CompilerInput } from "./yul-verification-input";

const llvmOptions = ["-force-attribute=$llvm_NoInline_llvm$_unoptimized:optnone"];
const sourcePath = "contracts-preprocessed/Example.yul";
const codeName = "Example";
const name = `${sourcePath}:Example`;
const input = {
  language: "Solidity",
  sources: { [sourcePath]: { content: `object "${codeName}" { code { } }` } },
  settings: { llvmOptions, optimizer: { mode: "3" }, metadata: { hashType: "keccak256" }, enableEraVMExtensions: true },
};
const request = (value: CompilerInput = input, options = llvmOptions, solc = "zkVM-0.8.28-1.0.1") =>
  yulVerificationRequest(value, "0x0000000000000000000000000000000000008001", name, "v1.5.17", solc, options);
assert.deepStrictEqual(parseForgeCompilerInput(`Compiler info\n${JSON.stringify(input)}`), input);
assert.throws(() => parseForgeCompilerInput("No JSON"), /did not return/);
assert.strictEqual(request().sourceCode.language, "Yul");
assert.strictEqual(input.language, "Solidity", "Must not mutate original build input");
assert.deepStrictEqual(request().sourceCode.settings, input.settings);
assert.deepStrictEqual(request().sourceCode.sources, input.sources);
assert.strictEqual(request().codeFormat, "solidity-standard-json-input");
assert.throws(() => request({ ...input, settings: { ...input.settings, llvmOptions: [] } }), /Verification lost LLVM/);
assert.throws(() => request({ ...input, sources: {} }), /Missing Yul source/);
assert.throws(
  () => request({ ...input, sources: { ...input.sources, "Other.sol": { content: "contract Other {}" } } }),
  /mixed Solidity/
);
assert.throws(() => request(input, llvmOptions, "0.8.28"), /Exact released/);
assert.deepStrictEqual(
  request({ ...input, settings: { ...input.settings, llvmOptions: [] } }, []).sourceCode.settings.llvmOptions,
  []
);
console.log("Yul verification input regression checks passed");
