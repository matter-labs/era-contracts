import assert from "assert";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {
  compilerVersionsFromBytecode,
  parseForgeCompilerInput,
  yulVerificationRequest,
} from "./yul-verification-input";
import type { CompilerInput } from "./yul-verification-input";
import { Language, SourceLocation, SYSTEM_CONTRACTS } from "./constants";

// What `forge verify-contract --zksync --show-standard-json-input` (foundry-zksync v0.1.5) printed
// for EcAdd in a full checkout, remappings included, and EcAdd's AllContractsHashes.json entry for
// that build. Re-export both after a zksolc bump: the compile check needs ZKSOLC_VERSION installed.
const FIXTURE = path.join(__dirname, "yul-verification-input-data", "EcAdd.json");
const SOURCE_PATH = "contracts-preprocessed/precompiles/EcAdd.yul";
const CODE_NAME = "EcAdd";
const CONTRACT_NAME = `${SOURCE_PATH}:${CODE_NAME}`;
const ADDRESS = "0x0000000000000000000000000000000000000006";
const ZKSOLC_VERSION = "v1.5.17";
const SOLC_RELEASE = "zkVM-0.8.28-1.0.2";
const LLVM_OPTIONS = ["-dse-memoryssa-scanlimit=0", "-dse-memoryssa-walklimit=0"];
const EXPECTED_HASH = "0100000df4f976ae6ad4baa58e28b7246da7269ca435d7d2b491c7814a0bc2c8";
// The CBOR metadata that ends zkout/NonceHolder.sol/NonceHolder.json in the same build.
const NONCE_HOLDER_METADATA =
  "0xa2646970667358221220aff031398d3de8aa67d01d8b7913e3809b05d1a0bdf85c31f1c5601aba5fea5d64736f6c6378247a6b736f6c633a312e352e31373b736f6c633a302e382e32383b6c6c766d3a312e302e320055";
// foundry-zksync and scripts/install-zksolc.sh keep zksolc here as zksolc-<os>-<arch>[-musl]-<version>.
const ZKSOLC_DIR = path.join(os.homedir(), ".zksync");

const input = parseForgeCompilerInput(`Compiler info\n${fs.readFileSync(FIXTURE, "utf8")}`);
const request = (value: CompilerInput = input, options = LLVM_OPTIONS, solc = SOLC_RELEASE) =>
  yulVerificationRequest(value, ADDRESS, CONTRACT_NAME, ZKSOLC_VERSION, solc, options);
const { sourceCode, codeFormat } = request();
assert.throws(() => parseForgeCompilerInput("No JSON"), /did not return/);

// Foundry exports the Yul build input labelled as Solidity and with the project remappings.
assert.strictEqual(input.language, "Solidity");
assert.ok(input.settings.remappings?.length, "Fixture must carry Foundry's remappings");

// What the verifier needs: the Yul language, no remappings (solc rejects them for Yul) and every
// other build setting unchanged, including the LLVM options and EraVM extensions.
assert.strictEqual(codeFormat, "solidity-standard-json-input");
assert.strictEqual(sourceCode.language, "Yul");
assert.ok(!("remappings" in sourceCode.settings));
const buildSettings = { ...input.settings };
delete buildSettings.remappings;
assert.deepStrictEqual(sourceCode.settings, buildSettings);
assert.deepStrictEqual(sourceCode.settings.llvmOptions, LLVM_OPTIONS);
assert.strictEqual(sourceCode.settings.enableEraVMExtensions, true);
assert.deepStrictEqual(sourceCode.sources, input.sources);
assert.strictEqual(input.language, "Solidity", "Must not mutate original build input");
assert.ok(input.settings.remappings, "Must not mutate original build input");

assert.throws(() => request({ ...input, settings: { ...input.settings, llvmOptions: [] } }), /Verification lost LLVM/);
assert.throws(() => request({ ...input, sources: {} }), /Missing Yul source/);
assert.throws(
  () => request({ ...input, sources: { ...input.sources, "Other.sol": { content: "contract Other {}" } } }),
  /mixed Solidity/
);
assert.throws(() => request(input, LLVM_OPTIONS, "0.8.28"), /Exact released/);
assert.deepStrictEqual(
  request({ ...input, settings: { ...input.settings, llvmOptions: [] } }, []).sourceCode.settings.llvmOptions,
  []
);

// Compile the request the way Foundry builds Yul, with zksolc and no --solc, and check that it
// reproduces the deployed bytecode. The explorer verifier adds --solc; see the README.
const platform = process.platform == "darwin" ? "macosx" : process.platform;
const arch = process.arch == "x64" ? "amd64" : process.arch;
const binaries = (fs.existsSync(ZKSOLC_DIR) ? fs.readdirSync(ZKSOLC_DIR) : []).filter(
  (file) => file.startsWith(`zksolc-${platform}-`) && file.endsWith(`-${ZKSOLC_VERSION}`)
);
const zksolc = binaries.find((file) => file.includes(`-${arch}`)) ?? binaries[0];
if (!zksolc) throw new Error(`zksolc ${ZKSOLC_VERSION} is not in ${ZKSOLC_DIR}; run scripts/install-zksolc.sh`);
const output = JSON.parse(
  execFileSync(path.join(ZKSOLC_DIR, zksolc), ["--standard-json"], {
    input: JSON.stringify(sourceCode),
    encoding: "utf8",
  })
);
assert.deepStrictEqual(
  (output.errors ?? []).filter((error: { severity: string }) => error.severity == "error"),
  []
);
assert.strictEqual(output.contracts[SOURCE_PATH][CODE_NAME].hash, EXPECTED_HASH);

// The script reads the zkVM-solc release from a Solidity artifact; Yul bytecode records only zksolc.
assert.deepStrictEqual(compilerVersionsFromBytecode(NONCE_HOLDER_METADATA), {
  zksolc: ZKSOLC_VERSION,
  solc: SOLC_RELEASE,
});
assert.throws(
  () => compilerVersionsFromBytecode(output.contracts[SOURCE_PATH][CODE_NAME].evm.bytecode.object),
  /does not record/
);

// verify-on-explorer submits a system-contracts Solidity entry as contracts-preprocessed/<codeName>.sol,
// the preprocessed copy of contracts/<codeName>.sol, and skips SourceLocation.L1Contracts entries,
// which l1-contracts' verify-on-l2-explorer verifies instead. Every Solidity entry must therefore
// name a contract that its project builds: a stale or mistyped codeName, or a contract that moved
// to l1-contracts (L2BaseToken is now L2BaseTokenEra) without its location changing, fails here.
const BUILT_CONTRACTS = new Set(
  (
    JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "AllContractsHashes.json"), "utf8")) as {
      contractName: string;
    }[]
  ).map(({ contractName }) => contractName)
);
const PROJECT_DIRS = {
  [SourceLocation.SystemContracts]: "system-contracts",
  [SourceLocation.L1Contracts]: "l1-contracts",
};
for (const description of Object.values(SYSTEM_CONTRACTS)) {
  if (description.lang == Language.Solidity) {
    const contractName = `${PROJECT_DIRS[description.location]}/${description.codeName}`;
    assert.ok(BUILT_CONTRACTS.has(contractName), `${contractName} is not in AllContractsHashes.json`);
  }
  if (description.lang == Language.Solidity && description.location == SourceLocation.SystemContracts) {
    const source = path.join(__dirname, "..", "contracts", `${description.codeName}.sol`);
    assert.ok(fs.existsSync(source), `${description.codeName} has no source in system-contracts/contracts`);
  }
}
console.log("Yul verification input regression checks passed");
