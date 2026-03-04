import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";

// Constant arrays
const CONTRACTS_DIRECTORIES = {
  contracts: [
    "common/L1ContractErrors.sol",
    "bridge/L1BridgeContractErrors.sol",
    "bridgehub/L1BridgehubErrors.sol",
    "state-transition/L1StateTransitionErrors.sol",
    "upgrades/ZkSyncUpgradeErrors.sol",
  ],
  "deploy-scripts": ["ZkSyncScriptErrors.sol"],
  "../l2-contracts/contracts": ["errors/L2ContractErrors.sol"],
  "../system-contracts/contracts": ["SystemContractErrors.sol"],
  "../da-contracts/contracts": ["DAContractsErrors.sol"],
};

// Helper: sort error blocks (selector + multi-line error) alphabetically by error name
function sortErrorBlocks(lines: string[]): string[] {
  const before: string[] = [];
  const blocks: string[][] = [];
  const after: string[] = [];
  let i = 0;
  let inBlock = false;

  while (i < lines.length) {
    const line = lines[i];
    const next = lines[i + 1];

    // If a selector comment followed by an error declaration
    if (/^\s*\/\/\s*0x[0-9a-fA-F]{8}/.test(line) && next && /^\s*error\s+/.test(next)) {
      inBlock = true;
      const block: string[] = [];
      block.push(line);
      i++;
      // Capture error and its multi-line body
      while (i < lines.length) {
        block.push(lines[i]);
        if (lines[i].trim().endsWith(");")) {
          i++;
          break;
        }
        i++;
      }
      blocks.push(block);
    }
    // If an error declaration without preceding selector comment
    else if (/^\s*error\s+/.test(line)) {
      inBlock = true;
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
    }
    // Regular lines
    else {
      if (!inBlock) before.push(line);
      else after.push(line);
      i++;
    }
  }

  // Sort blocks by the first 'error Name'
  blocks.sort((a, b) => {
    const nameA = a.find((l) => /^\s*error\s+/.test(l))!.match(/error\s+(\w+)/)![1];
    const nameB = b.find((l) => /^\s*error\s+/.test(l))!.match(/error\s+(\w+)/)![1];
    return nameA.localeCompare(nameB);
  });

  // Reassemble file
  const sorted: string[] = [...before];
  blocks.forEach((block) => sorted.push(...block));
  return sorted.concat(after);
}

// Process a file: handle selector insertion, multiline parsing, and sorting
function processFile(filePath: string, fix: boolean, collectedErrors: Map<string, [string, string]>): boolean {
  const content = fs.readFileSync(filePath, "utf8");

  // Find all enum definitions in the file
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
      // Capture block lines
      const blockLines: string[] = [];
      const start = i;
      while (i < lines.length) {
        blockLines.push(lines[i]);
        if (lines[i].trim().endsWith(");")) break;
        i++;
      }
      // Regex parse
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

      // Selector comment
      const selector = ethers.utils.id(sig).slice(0, 10);
      const comment = `// ${selector}`;
      const prev = output[output.length - 1];
      if (!prev || (prev.trim() !== comment && !prev.trim().startsWith("// skip-errors-lint"))) {
        if (!fix) throw new Error(`Missing selector above ${filePath}:${start + 1}`);
        if (prev && prev.trim().startsWith("//")) output[output.length - 1] = comment;
        else output.push(comment);
        modified = true;
      }

      // Push block
      blockLines.forEach((l) => output.push(l));
      i++;
    } else {
      output.push(line);
      i++;
    }
  }

  if (fix && modified) {
    // Sort all error blocks
    const sorted = sortErrorBlocks(output);
    fs.writeFileSync(filePath, sorted.join("\n"), "utf8");
    return true;
  }
  return modified;
}

// Recursively collects all custom error usages from the given contract directories.
function collectErrorUsages(directories: string[], usedErrors: Set<string>) {
  for (const dir of directories) {
    const absoluteDir = path.resolve(dir);
    if (fs.existsSync(absoluteDir) && fs.lstatSync(absoluteDir).isDirectory()) {
      const files = fs.readdirSync(absoluteDir);
      for (const file of files) {
        const fullPath = path.join(absoluteDir, file);
        if (fs.lstatSync(fullPath).isDirectory()) {
          collectErrorUsages([fullPath], usedErrors);
        } else if (file.endsWith(".sol")) {
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
    }
  }
}

async function main() {
  const program = new Command();
  program
    .option("--fix", "Fix the errors by inserting selectors and sorting")
    .option("--check", "Check if the selectors are present without modifying files")
    .parse(process.argv);

  const options = program.opts();
  if ((!options.fix && !options.check) || (options.fix && options.check)) {
    console.error("Error: You must provide either --fix or --check, but not both.");
    process.exit(1);
  }
  let hasErrors = false;
  for (const [contractsPath, errorsPaths] of Object.entries(CONTRACTS_DIRECTORIES)) {
    const declaredErrors = new Map<string, [string, string]>();
    const usedErrors = new Set<string>();
    for (const customErrorFile of errorsPaths) {
      const absolutePath = path.resolve(contractsPath + "/" + customErrorFile);
      const result = processFile(absolutePath, options.fix, declaredErrors);
      if (result && options.check) hasErrors = true;
    }
    if (options.check && hasErrors) {
      console.error("Some errors were found.");
      process.exit(1);
    }
    if (options.check) {
      // Check for error usage in contracts, test files, and deploy scripts
      const searchPaths = [contractsPath];
      if (contractsPath === "contracts") {
        searchPaths.push("test"); // Also search test directory for contracts
      }
      collectErrorUsages(searchPaths, usedErrors);
      const unusedErrors = [...declaredErrors].filter(([, [errorName]]) => !usedErrors.has(errorName));
      if (unusedErrors.length > 0) {
        for (const [errorSig, errorFile] of unusedErrors)
          console.error(`Error "${errorSig}" from ${errorFile} is declared but never used.`);
        process.exit(1);
      }
    }
  }
  if (options.check && !hasErrors) console.log("All files are correct.");
  if (options.fix) console.log("All files have been processed and fixed.");
}

main();
