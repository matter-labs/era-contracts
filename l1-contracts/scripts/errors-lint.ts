import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import * as https from "https";

// Constant arrays
const CONTRACTS_DIRECTORIES: Record<string, string[]> = {
  contracts: [
    "common/L1ContractErrors.sol",
    "bridge/L1BridgeContractErrors.sol",
    "core/bridgehub/L1BridgehubErrors.sol",
    "interop/InteropErrors.sol",
    "bridge/asset-tracker/AssetTrackerErrors.sol",
    "state-transition/L1StateTransitionErrors.sol",
    "upgrades/ZkSyncUpgradeErrors.sol",
  ],
  "./deploy-scripts": ["utils/ZkSyncScriptErrors.sol"],
  "../l2-contracts/contracts": ["errors/L2ContractErrors.sol"],
  "../system-contracts/contracts": ["SystemContractErrors.sol"],
  "../da-contracts/contracts": ["DAContractsErrors.sol"],
};

// ---------- Helpers: signature DB ----------

async function querySignatureDatabase(signature: string): Promise<boolean> {
  const url = `https://api.openchain.xyz/signature-database/v1/search?query=${encodeURIComponent(
    signature
  )}&_=${Date.now()}`;
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        let data = "";
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          try {
            const parsedData = JSON.parse(data);
            if (!parsedData.ok || !parsedData.result) {
              return reject(new Error(`Invalid response from signature database. Response: ${data}`));
            }
            const { event, function: func } = parsedData.result;
            const signatureFound = Object.keys(event || {}).length > 0 || Object.keys(func || {}).length > 0;
            resolve(signatureFound);
          } catch {
            reject(new Error(`Failed to parse response from signature database: ${data}`));
          }
        });
      })
      .on("error", (err) => {
        reject(new Error(`Error querying signature database: ${err.message}`));
      });
  });
}

async function submitSignatureToDatabase(signature: string): Promise<void> {
  const postData = JSON.stringify({
    function: [signature],
    event: [],
  });

  const options = {
    hostname: "api.openchain.xyz",
    path: "/signature-database/v1/import",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(postData),
    },
  };

  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let responseBody = "";
      res.on("data", (chunk) => (responseBody += chunk));

      res.on("end", () => {
        if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
          console.log(`Signature "${signature}" submitted successfully.`);
          resolve();
        } else if (res.statusCode === 400 && responseBody.includes("already exists")) {
          console.log(
            `Signature "${signature}" already exists in the database (race condition?). Treating as success.`
          );
          resolve();
        } else {
          reject(
            new Error(`Failed to submit signature "${signature}". Status: ${res.statusCode}, Body: ${responseBody}`)
          );
        }
      });
    });

    req.on("error", (e) => {
      reject(new Error(`Error submitting signature "${signature}": ${e.message}`));
    });

    req.write(postData);
    req.end();
  });
}

// ---------- Helpers: parsing/sorting ----------

// ethers v5 uses ethers.utils.id; v6 uses ethers.id
function keccakId(text: string): string {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const anyEthers: any = ethers as any;
  const fn = anyEthers.id ?? anyEthers.utils?.id;
  if (!fn) throw new Error("Unable to find ethers.id / ethers.utils.id");
  return fn(text);
}

// Sort error blocks (selector + multi-line error) alphabetically by error name
function sortErrorBlocks(lines: string[]): string[] {
  const before: string[] = [];
  const blocks: string[][] = [];
  const after: string[] = [];
  let i = 0;
  let startedBlocks = false;

  while (i < lines.length) {
    const line = lines[i];
    const next = lines[i + 1];

    if (/^\s*\/\/\s*0x[0-9a-fA-F]{8}\s*$/.test(line) && next && /^\s*error\s+/.test(next)) {
      startedBlocks = true;
      const block: string[] = [];
      block.push(line);
      i++;
      while (i < lines.length) {
        block.push(lines[i]);
        if (lines[i].trim().endsWith(");")) {
          i++;
          break;
        }
        i++;
      }
      blocks.push(block);
    } else if (/^\s*error\s+/.test(line)) {
      startedBlocks = true;
      const block: string[] = [];
      while (i < lines.length) {
        block.push(lines[i]);
        if (lines[i].trim().endsWith(");")) {
          i++;
          break;
        }
        i++;
      }
      blocks.push(block);
    } else {
      if (!startedBlocks) before.push(line);
      else after.push(line);
      i++;
    }
  }

  blocks.sort((a, b) => {
    const nameA = a.find((l) => /^\s*error\s+/.test(l))!.match(/error\s+(\w+)/)![1];
    const nameB = b.find((l) => /^\s*error\s+/.test(l))!.match(/error\s+(\w+)/)![1];
    return nameA.localeCompare(nameB);
  });

  return [...before, ...blocks.flat(), ...after];
}

// ---------- Core: process files & collect usage ----------

async function processFile(
  filePath: string,
  fix: boolean,
  database: boolean,
  collectedErrors: Map<string, [string, string]>
): Promise<boolean> {
  const content = fs.readFileSync(filePath, "utf8");

  // Collect enum names to map to uint8 in error signatures
  const enums = new Set<string>();
  const enumRegex = /enum\s+(\w+)\s*\{/g;
  let enumMatch;
  while ((enumMatch = enumRegex.exec(content)) !== null) {
    enums.add(enumMatch[1]);
  }

  const lines = content.split(/\r?\n/);
  const output: string[] = [];
  let modified = false;
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (/^\s*error\s+/.test(line)) {
      const blockLines: string[] = [];
      const start = i;
      while (i < lines.length) {
        blockLines.push(lines[i]);
        if (lines[i].trim().endsWith(");")) break;
        i++;
      }

      const blockText = blockLines.join("\n");
      const sigRe = /^\s*error\s+(\w+)\s*\(([\s\S]*?)\)\s*;\s*$/m;
      const match = blockText.match(sigRe);
      if (!match) throw new Error(`Cannot parse error at ${filePath}:${start + 1}`);

      const [, errName, params] = match;
      const types = params
        .split(",")
        .map((p) => p.trim().split(/\s+/)[0])
        .filter((t) => t)
        .map((t) => (enums.has(t) ? "uint8" : t));
      const sig = `${errName}(${types.join(",")})`;

      if (collectedErrors.has(sig)) {
        const [, prev] = collectedErrors.get(sig)!;
        throw new Error(`Error ${errName} defined twice in ${prev} and ${filePath}`);
      }
      collectedErrors.set(sig, [errName, filePath]);

      // Insert/update selector comment
      const selector = keccakId(sig).slice(0, 10);
      const comment = `// ${selector}`;
      const prev = output[output.length - 1];
      if (!prev || (prev.trim() !== comment && !prev.trim().startsWith("// skip-errors-lint"))) {
        if (!fix) throw new Error(`Missing selector above ${filePath}:${start + 1}`);
        if (prev && prev.trim().startsWith("//")) output[output.length - 1] = comment;
        else output.push(comment);
        modified = true;
      }

      // Submit selectors to signature DB
      if (database) {
        const exists = await querySignatureDatabase(sig);
        if (!exists) {
          await submitSignatureToDatabase(sig);
        } else {
          console.log(`Signature "${sig}" already exists in the database.`);
        }
      }

      blockLines.forEach((l) => output.push(l));
      i++;
    } else {
      output.push(line);
      i++;
    }
  }

  if (fix && modified) {
    const sorted = sortErrorBlocks(output);
    fs.writeFileSync(filePath, sorted.join("\n"), "utf8");
    return true;
  }
  return modified;
}

// Escape for building a safe regex alternation
function escapeRegex(s: string): string {
  return s.replace(/[$()*+.?[\\\]^{|}-]/g, "\\$&");
}

// Recursively collects all custom error usages from the given contract directories.
// This recognizes:
// - revert ErrorName(...)
// - require(..., ErrorName(...))
// - naked calls: ErrorName(...)
// - qualified calls: Namespace.ErrorName(...)
// - selector usage: ErrorName.selector
// - abi.encodeWithSelector(ErrorName.selector, ...)
function collectErrorUsages(directories: string[], usedErrors: Set<string>, declaredNames?: Set<string>) {
  const nameAlternation =
    declaredNames && declaredNames.size > 0
      ? Array.from(declaredNames)
          .sort((a, b) => a.length - b.length)
          .map(escapeRegex)
          .join("|")
      : "[A-Za-z0-9_]+";

  const pattern =
    "\\b(?:" +
    // 1) revert ErrorName(...)
    "revert\\s+(" +
    nameAlternation +
    ")\\s*\\(" +
    "|" +
    // 2) require(..., ErrorName(...))
    "require\\s*\\([^;]*?\\b(" +
    nameAlternation +
    ")\\s*\\(" +
    "|" +
    // 3) naked constructor call ErrorName(...)
    "(" +
    nameAlternation +
    ")\\s*\\(" +
    "|" +
    // 4) Namespace.ErrorName(...)
    "[A-Za-z0-9_]+\\s*\\.\\s*(" +
    nameAlternation +
    ")\\s*\\(" +
    "|" +
    // 5) ErrorName.selector
    "(" +
    nameAlternation +
    ")\\.selector\\b" +
    "|" +
    // 6) abi.encodeWithSelector(ErrorName.selector, ...)
    "abi\\s*\\.\\s*encodeWithSelector\\s*\\(\\s*(" +
    nameAlternation +
    ")\\.selector" +
    ")";

  const usageRe = new RegExp(pattern, "gm");

  for (const dir of directories) {
    const absoluteDir = path.resolve(dir);
    if (!fs.existsSync(absoluteDir)) continue;

    const stat = fs.statSync(absoluteDir);
    if (stat.isDirectory()) {
      const files = fs.readdirSync(absoluteDir);
      for (const file of files) {
        const fullPath = path.join(absoluteDir, file);
        const st = fs.statSync(fullPath);
        if (st.isDirectory()) {
          collectErrorUsages([fullPath], usedErrors, declaredNames);
        } else if (file.endsWith(".sol")) {
          let src = fs.readFileSync(fullPath, "utf8");

          // Strip comments
          src = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

          // Drop import lines and error declarations to avoid counting definitions/imports as "usage"
          src = src.replace(/^\s*import\s+[^;]+;.*$/gm, "");
          src = src.replace(/^\s*error\s+[A-Za-z0-9_]+\s*\([^;]*\)\s*;.*$/gm, "");

          // Normalize whitespace
          src = src.replace(/\s+/g, " ");

          let m: RegExpExecArray | null;
          while ((m = usageRe.exec(src)) !== null) {
            // Find which capturing group hit and add that name
            for (let i = 1; i < m.length; i++) {
              const name = m[i];
              if (name) {
                if (!declaredNames || declaredNames.has(name)) {
                  usedErrors.add(name);
                }
                break;
              }
            }
          }

          // Check for errors used in revert statements like revert ErrorName(...)
          const fileContent = fs.readFileSync(fullPath, "utf8");
          const revertRegex = /revert\s+([A-Za-z0-9_]+)/g;
          let match;
          while ((match = revertRegex.exec(fileContent)) !== null) usedErrors.add(match[1]);

          // Also check for error selector usage like ErrorName.selector
          const selectorRegex = /([A-Za-z0-9_]+)\.selector/g;
          while ((match = selectorRegex.exec(fileContent)) !== null) usedErrors.add(match[1]);

          // Check for errors used in require statements like require(condition, ErrorName(...))
          const requireRegex = /require\s*\([^,]+,\s*([A-Za-z0-9_]+)\s*\(/g;
          while ((match = requireRegex.exec(fileContent)) !== null) usedErrors.add(match[1]);
        }
      }
    } else if (stat.isFile() && absoluteDir.endsWith(".sol")) {
      // If a single file slipped in, scan its directory
      collectErrorUsages([path.dirname(absoluteDir)], usedErrors, declaredNames);
    }
  }
}

// ---------- CLI ----------

async function main() {
  const program = new Command();
  program
    .option("--fix", "Fix the errors by inserting selectors and sorting")
    .option("--check", "Check if the selectors are present without modifying files")
    .option("--database", "Upload error selectors to the signature DB (https://openchain.xyz/signatures).")
    .parse(process.argv);

  const options = program.opts<{ fix?: boolean; check?: boolean; database?: boolean }>();
  if ((!options.fix && !options.check) || (options.fix && options.check)) {
    console.error("Error: You must provide either --fix or --check, but not both.");
    process.exit(1);
  }
  if (!options.fix && options.database) {
    console.error("You can only upload the signatures to the database when using --fix flag.");
    process.exit(1);
  }

  let hasErrors = false;

  for (const [contractsPath, errorsPaths] of Object.entries(CONTRACTS_DIRECTORIES)) {
    const declaredErrors = new Map<string, [string, string]>(); // sig -> [errName, filePath]
    const usedErrors = new Set<string>();

    // Process/validate each error definition file, collecting declared errors
    for (const customErrorFile of errorsPaths) {
      const absolutePath = path.resolve(contractsPath + "/" + customErrorFile);
      const result = await processFile(absolutePath, !!options.fix, !!options.database, declaredErrors);
      if (result && options.check) hasErrors = true;
    }

    if (options.check && hasErrors) {
      console.error("Some errors were found.");
      process.exit(1);
    }

    if (options.check) {
      // Restrict usage scan to only declared error names from this package path
      const declaredNames = new Set(Array.from(declaredErrors.values()).map(([name]) => name));

      // Check for error usage in contracts, test files, and deploy scripts
      const searchPaths = [contractsPath];
      if (contractsPath === "contracts") {
        searchPaths.push("test"); // Also search test directory for contracts
      }
      collectErrorUsages(searchPaths, usedErrors, declaredNames);

      const unusedErrors = [...declaredErrors].filter(([, [errorName]]) => !usedErrors.has(errorName));
      if (unusedErrors.length > 0) {
        for (const [errorSig, [, filePath]] of unusedErrors) {
          console.error(`Error "${errorSig}" from ${filePath} is declared but never used.`);
        }
        process.exit(1);
      }
    }
  }

  if (options.check && !hasErrors) console.log("All files are correct.");
  if (options.fix) console.log("All files have been processed and fixed.");
}

main().catch((e) => {
  console.error(e?.message ?? String(e));
  process.exit(1);
});
