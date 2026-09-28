import { execFileSync, spawnSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

// Checks solc's warnings for the foundry project in the cwd against its `solc-warnings.json`.
// See AGENTS.md "solc warnings". Run with `--selftest` to exercise the exception matching.

const POLICY_FILE = "solc-warnings.json";
// solc stops reporting after this many warnings and emits 4591 instead.
const SOLC_WARNING_CAP = 256;
const SOLC_WARNING_CAP_CODE = 4591;

export interface PolicyException {
  file: string;
  code: number;
  source: string;
}

export interface Policy {
  roots: string[];
  exceptions: PolicyException[];
}

export interface SolcWarning {
  code: number;
  file: string;
  source: string;
  formatted: string;
}

interface SolcDiagnostic {
  severity: "error" | "warning" | "info";
  errorCode?: string;
  formattedMessage: string;
  sourceLocation?: { file: string; start: number; end: number };
}

// solc reports byte offsets, which differ from string indices once a file has non-ASCII text.
export function sourceFirstLine(content: Buffer, start: number, end: number): string {
  return content.subarray(start, end).toString("utf8").split("\n")[0].trim();
}

export function evaluate(
  policy: Policy,
  warnings: SolcWarning[]
): { violations: SolcWarning[]; stale: PolicyException[] } {
  const used = new Set<PolicyException>();
  const violations: SolcWarning[] = [];
  for (const w of warnings) {
    const exception = policy.exceptions.find((e) => e.file === w.file && e.code === w.code && e.source === w.source);
    if (exception) {
      used.add(exception);
    } else {
      violations.push(w);
    }
  }
  return { violations, stale: policy.exceptions.filter((e) => !used.has(e)) };
}

function svmDataDirs(): string[] {
  const home = os.homedir();
  const dataDir =
    process.env.XDG_DATA_HOME ??
    (process.platform === "darwin"
      ? path.join(home, "Library", "Application Support")
      : path.join(home, ".local", "share"));
  return [path.join(home, ".svm"), path.join(dataDir, "svm")];
}

function findSolc(version: string): string | undefined {
  return svmDataDirs()
    .map((dir) => path.join(dir, version, `solc-${version}`))
    .find((candidate) => fs.existsSync(candidate));
}

// A warm build cache can leave forge with nothing to compile, so it never installs solc. Building a
// one-file project pinned to the version makes forge install it, checksum verification included.
function installSolc(version: string): void {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "solc-warnings-"));
  try {
    fs.mkdirSync(path.join(dir, "src"));
    fs.writeFileSync(path.join(dir, "foundry.toml"), `[profile.default]\nsolc = "${version}"\n`);
    fs.writeFileSync(
      path.join(dir, "src", "Probe.sol"),
      `// SPDX-License-Identifier: MIT\npragma solidity ${version};\ncontract Probe {}\n`
    );
    execFileSync("forge", ["build", "--root", dir], { stdio: "inherit" });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function collectWarnings(policy: Policy): SolcWarning[] {
  const config = JSON.parse(execFileSync("forge", ["config", "--json"], { encoding: "utf8" }));
  const version: string | null = config.solc;
  if (!version) {
    throw new Error("foundry.toml must pin `solc` to a single version");
  }
  let solc = findSolc(version);
  if (!solc) {
    installSolc(version);
    solc = findSolc(version);
  }
  if (!solc) {
    throw new Error(`solc ${version} not found in ${svmDataDirs().join(", ")}`);
  }

  const files = execFileSync("git", ["ls-files", "--", ...policy.roots.map((root) => `${root}/*.sol`)], {
    encoding: "utf8",
  })
    .split("\n")
    .filter(Boolean);
  const remappings = execFileSync("forge", ["remappings"], { encoding: "utf8" }).split("\n").filter(Boolean);
  const input = {
    language: "Solidity",
    sources: Object.fromEntries(files.map((file) => [file, { urls: [file] }])),
    settings: {
      remappings,
      evmVersion: config.evm_version,
      viaIR: Boolean(config.via_ir),
      outputSelection: { "*": { "": [] } },
    },
  };
  // `lib/` entries are symlinks into the repository root's `lib/`.
  const repoRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
  const result = spawnSync(solc, ["--standard-json", "--base-path", ".", "--allow-paths", repoRoot], {
    input: JSON.stringify(input),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`solc exited with ${result.status}: ${result.stderr}`);
  }
  const diagnostics: SolcDiagnostic[] = JSON.parse(result.stdout).errors ?? [];

  const errors = diagnostics.filter((d) => d.severity === "error");
  if (errors.length > 0) {
    throw new Error(`solc reported errors:\n${errors.map((e) => e.formattedMessage).join("\n")}`);
  }
  const reported = diagnostics.filter((d) => d.severity !== "error");
  if (reported.length >= SOLC_WARNING_CAP || reported.some((d) => Number(d.errorCode) === SOLC_WARNING_CAP_CODE)) {
    throw new Error(`solc hit its cap of ${SOLC_WARNING_CAP} reported warnings, so the list below it is incomplete`);
  }

  const contents = new Map<string, Buffer>();
  return reported.map((d) => {
    const loc = d.sourceLocation;
    let source = "";
    if (loc) {
      if (!contents.has(loc.file)) {
        contents.set(loc.file, fs.readFileSync(loc.file));
      }
      source = sourceFirstLine(contents.get(loc.file)!, loc.start, loc.end);
    }
    return { code: Number(d.errorCode), file: loc?.file ?? "", source, formatted: d.formattedMessage };
  });
}

function check(): number {
  const policy: Policy = JSON.parse(fs.readFileSync(POLICY_FILE, "utf8"));
  const warnings = collectWarnings(policy);
  const { violations, stale } = evaluate(policy, warnings);

  for (const v of violations) {
    console.error(v.formatted);
    console.error(
      `  to accept it, add to ${POLICY_FILE}: ${JSON.stringify({ file: v.file, code: v.code, source: v.source })}\n`
    );
  }
  for (const e of stale) {
    console.error(`stale exception in ${POLICY_FILE}, no longer reported by solc: ${JSON.stringify(e)}`);
  }
  if (violations.length > 0 || stale.length > 0) {
    console.error(`solc-warnings: ${violations.length} new warning(s), ${stale.length} stale exception(s).`);
    return 1;
  }
  console.log(`solc-warnings: ${warnings.length} warning(s), all listed in ${POLICY_FILE}.`);
  return 0;
}

// Exception-matching tests. Run via `yarn solc-warnings:selftest`; wired into `lint:check`.
function selftest(): number {
  const failures: string[] = [];
  const expect = (name: string, actual: unknown, expected: unknown) => {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      failures.push(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
  };
  const policy: Policy = {
    roots: [],
    exceptions: [
      { file: "contracts/A.sol", code: 5667, source: "uint256 _salt," },
      { file: "contracts/B.sol", code: 5667, source: "uint256 _gone," },
    ],
  };
  const warning = (file: string, code: number, source = "") => ({ code, file, source, formatted: `${file}:${code}` });

  const result = evaluate(policy, [
    warning("contracts/A.sol", 5667, "uint256 _salt,"),
    warning("contracts/A.sol", 5667, "uint256 _other,"),
    warning("contracts/A.sol", 2072, "uint256 _salt,"),
    warning("contracts/C.sol", 5667, "uint256 _salt,"),
  ]);
  expect(
    "violations",
    result.violations.map((v) => `${v.formatted}:${v.source}`),
    [
      "contracts/A.sol:5667:uint256 _other,",
      "contracts/A.sol:2072:uint256 _salt,",
      "contracts/C.sol:5667:uint256 _salt,",
    ]
  );
  expect(
    "stale exceptions",
    result.stale.map((e) => e.source),
    ["uint256 _gone,"]
  );

  // An em dash is 3 bytes in UTF-8 but one string index, so slicing the string would land 2 characters late.
  const content = Buffer.from("// — \nfunction f(uint256 _salt,\n  bool b) {}\n", "utf8");
  const start = content.indexOf("uint256");
  expect("byte offsets", sourceFirstLine(content, start, content.indexOf("{")), "uint256 _salt,");

  if (failures.length > 0) {
    console.error(`solc-warnings --selftest: ${failures.length} failure(s):`);
    for (const f of failures) console.error(`  ${f}`);
    return 1;
  }
  console.log("solc-warnings --selftest: policy tests pass.");
  return 0;
}

function main(): void {
  if (process.argv.includes("--selftest")) {
    process.exit(selftest());
  }
  process.exit(check());
}

main();
