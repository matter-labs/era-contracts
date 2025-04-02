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
}; // Replace with your directories

// Function to extract the error signature
function getErrorSignature(errorString: string): string {
  errorString = errorString.trim();
  const parenIndex = errorString.indexOf("(");

  if (parenIndex === -1) {
    throw new Error("No '(' in error");
  } else {
    const errorName = errorString.substring(0, parenIndex).trim();
    const paramsString = errorString.substring(parenIndex + 1, errorString.lastIndexOf(")")).trim();

    const params = paramsString
      .split(",")
      .map((param) => {
        const typeMatch = param.trim().match(/^(\w+(\[\])*)\s*(\w*)$/);
        if (typeMatch) {
          return typeMatch[1];
        } else {
          return "";
        }
      })
      .filter((paramType) => paramType !== "");

    return `${errorName}(${params.join(",")})`;
  }
}

// Function to process each file
function processFile(filePath: string, fix: boolean, collectedErrors: Map<string, [string, string]>): boolean {
  const fileContent = fs.readFileSync(filePath, "utf8");
  const lines = fileContent.split(/\r?\n/);
  let modified = false;
  const newLines = [];
  let lineNumber = 0;

  while (lineNumber < lines.length) {
    const line = lines[lineNumber];
    const errorMatch = line.match(/^\s*error\s+(.+);\s*$/);

    if (errorMatch) {
      const errorString = errorMatch[1].trim();

      // Get the error signature
      const signature = getErrorSignature(errorString);

      const errorName = signature.substring(0, signature.indexOf("("));
      if (collectedErrors.has(signature)) {
        throw new Error(
          `Error ${errorName} is defined twice. Once in ${collectedErrors.get(signature)[1]} and in ${filePath}`
        );
      }
      collectedErrors.set(signature, [errorName, filePath]);

      // Calculate the selector
      const hash = ethers.utils.id(signature);
      const selector = hash.substring(0, 10);

      // Check the line above
      const previousLine = newLines[newLines.length - 1];
      const selectorComment = `// ${selector}`;

      if (!previousLine || previousLine.trim() !== selectorComment) {
        if (fix) {
          // We allow fixing incorrect signature
          if (previousLine.startsWith("//")) {
            newLines[newLines.length - 1] = selectorComment;
          } else {
            // Insert the selector line
            newLines.push(selectorComment);
          }
          modified = true;
        } else {
          throw new Error(`Missing selector comment above error at ${filePath}:${lineNumber + 1}`);
        }
      }
      // Push the current line
      newLines.push(line);
    } else {
      // Not an error line, just copy
      newLines.push(line);
    }
    lineNumber++;
  }

  if (fix && modified) {
    // Write back to file
    const newContent = newLines.join("\n");
    fs.writeFileSync(filePath, newContent, "utf8");
  }

  return modified;
}

// Recursively collects all custom error usages from the given contract directories.s
function collectErrorUsages(directories: string[], usedErrors: Set<string>) {
  // Iterate over each directory provided in the directories array
  for (const dir of directories) {
    // Resolve the directory path to an absolute path
    const absoluteDir = path.resolve(dir);

    // Check if the directory exists and is indeed a directory
    if (fs.existsSync(absoluteDir) && fs.lstatSync(absoluteDir).isDirectory()) {
      // Read all entries (files and subdirectories) within the directory
      const files = fs.readdirSync(absoluteDir);

      // Iterate over each entry in the directory
      for (const file of files) {
        // Construct the full path of the current entry
        const fullPath = path.join(absoluteDir, file);

        // Check if the current entry is a directory
        if (fs.lstatSync(fullPath).isDirectory()) {
          // If it is a directory, recursively call collectErrorUsages on this subdirectory
          collectErrorUsages([fullPath], usedErrors);
        }
        // Check if the current entry is a Solidity file (ends with .sol)
        else if (file.endsWith(".sol")) {
          // Read the content of the Solidity file as a string
          const fileContent = fs.readFileSync(fullPath, "utf8");

          // Regular expression to match 'revert <ErrorName>' patterns in the file
          const revertRegex = /revert\s+([A-Za-z0-9_]+)/g;

          let match;
          // Use a loop to find all matches of the pattern in the file content
          while ((match = revertRegex.exec(fileContent)) !== null) {
            // match[1] contains the captured error name after 'revert'
            const errorName = match[1];
            // Add the error name to the usedErrors set
            usedErrors.add(errorName);
          }
        }
        // If the entry is neither a directory nor a Solidity file, it is ignored
      }
    }
    // If the path does not exist or is not a directory, it is ignored
  }
}

async function main() {
  // Initialize the command parser
  const program = new Command();

  program
    .option("--fix", "Fix the errors by inserting missing selectors")
    .option("--check", "Check if the selectors are present without modifying files")
    .parse(process.argv);

  const options = program.opts();

  // Validate arguments
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

      if (result && options.check) {
        hasErrors = true;
      }
    }

    if (options.check && hasErrors) {
      console.error("Some errors were found.");
      process.exit(1);
    }

    if (options.check) {
      collectErrorUsages([contractsPath], usedErrors);

      // Find declared errors that are never used
      const unusedErrors = [...declaredErrors].filter(([, [errorName]]) => !usedErrors.has(errorName));

      if (unusedErrors.length > 0) {
        for (const [errorSig, errorFile] of unusedErrors) {
          console.error(`Error "${errorSig}" from ${errorFile} is declared but never used.`);
        }
        process.exit(1);
      }
    }
  }

  if (options.check && !hasErrors) {
    console.log("All files are correct.");
  }

  if (options.fix) {
    console.log("All files have been processed and fixed.");
  }
}

main();
