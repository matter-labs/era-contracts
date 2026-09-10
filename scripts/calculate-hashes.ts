import { ethers } from "ethers";
import * as fs from "fs";
import _ from "lodash";
import os from "os";
import { join } from "path";
import * as blakejs from "blakejs";

const SOLIDITY_SOURCE_CODE_PATHS = ["l1-contracts/", "da-contracts/"];
const OUTPUT_FILE_PATH = "AllContractsHashes.json";

const SKIPPED_FOLDERS = ["l1-contracts/deploy-scripts", "l1-contracts/test", "l1-contracts/contracts/dev-contracts"];
const FORCE_INCLUDE = ["Create2AndTransfer.sol"];

// Opens a Solidity file and returns all the contracts/libraries created inside of it.
function parseSolFile(filePath: string): string[] {
  const content = fs.readFileSync(filePath, "utf-8");
  const regex = /(?:^|\s)(contract|library)\s+(\w+)/g;
  const matches: string[] = [];
  let match;

  while ((match = regex.exec(content)) !== null) {
    matches.push(match[2]);
  }

  return matches;
}

// Returns paths where all the foundry compiled artifacts related to the file can be stored
function getCanonicalPathsFromFile(directory: string, fileName: string, fullPath: string) {
  const folderName = SOLIDITY_SOURCE_CODE_PATHS.find((x) => directory.startsWith(x));
  if (!folderName) {
    throw new Error("Unknown directory");
  }

  const res: string[] = [];

  const parsed = parseSolFile(fullPath);

  for (const item of parsed) {
    res.push(`/${folderName}out/${fileName}/${item}.json`);
  }

  return res;
}

function listSolFiles(directory: string): string[] {
  const solFiles: string[] = [];

  function searchDir(dir: string) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        searchDir(fullPath);
      } else if (entry.isFile() && fullPath.endsWith(".sol")) {
        solFiles.push(...getCanonicalPathsFromFile(directory, entry.name, fullPath));
      }
    }
  }

  searchDir(directory);
  return solFiles;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let cachedIgnoredFiles: any = null;

function shouldForceIncludeFile(filePath: string) {
  // This is a simple substring check. It is simple and fine in most cases.
  // In the worst case, accidentally including a file is better than accidentally excluding.
  return FORCE_INCLUDE.some((x) => filePath.includes(x));
}

function getIgnoredFiles() {
  if (cachedIgnoredFiles) {
    return cachedIgnoredFiles;
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const res: any = {};

  for (const dir of SKIPPED_FOLDERS) {
    const files = listSolFiles(dir);
    for (const f of files) {
      if (!shouldForceIncludeFile(f)) {
        res[f] = true;
      }
    }
  }

  cachedIgnoredFiles = res;

  return res;
}

function shouldSkipFolderOrFile(filePath: string): boolean {
  return !!getIgnoredFiles()[filePath];
}

type SourceContractDetails = {
  contractName: string;
};

type EvmCompilations = {
  evmBytecodePath: string | null;
  evmBytecodeHash: string | null;
  evmDeployedBytecodeHash: string | null;
  evmDeployedBytecodeBlakeHash: string | null;
  evmDeployedBytecodeLength: number | null;
};

type SourceAndEvmCompilationDetails = SourceContractDetails & EvmCompilations;

type ContractsInfo = SourceAndEvmCompilationDetails;

const findDirsEndingWith = (path: string, endingWith: string): fs.Dirent[] => {
  const absolutePath = makePathAbsolute(path);
  try {
    const dirs = fs.readdirSync(absolutePath, { withFileTypes: true }).filter((dirent) => dirent.isDirectory());
    const dirsEndingWithSol = dirs.filter((dirent) => dirent.name.endsWith(endingWith));
    return dirsEndingWithSol;
  } catch (err) {
    return [];
  }
};

const SOLIDITY_ARTIFACTS_DIR = "out";

type EvmJsonFileContents = {
  bytecode: { object: string };
  deployedBytecode: { object: string };
};

type EVMBytecodeInfo = {
  evmBytecodeHash: string;
  evmDeployedBytecodeHash: string;
  evmDeployedBytecodeBlakeHash: string;
  evmDeployedBytecodeLength: number;
};

function defaultEVMBytecodeInfo(): EVMBytecodeInfo {
  return {
    evmBytecodeHash: "0x",
    evmDeployedBytecodeHash: "0x",
    evmDeployedBytecodeBlakeHash: "0x",
    evmDeployedBytecodeLength: 0,
  };
}

const getBytecodeInfoFromEvmJson = (jsonFileContents: EvmJsonFileContents): EVMBytecodeInfo => {
  try {
    if (jsonFileContents.deployedBytecode.object == "0x") {
      return defaultEVMBytecodeInfo();
    }
    return {
      evmBytecodeHash: ethers.utils.hexlify(
        ethers.utils.keccak256(ethers.utils.arrayify(jsonFileContents.bytecode.object))
      ),
      evmDeployedBytecodeHash: ethers.utils.hexlify(
        ethers.utils.keccak256(ethers.utils.arrayify(jsonFileContents.deployedBytecode.object))
      ),
      evmDeployedBytecodeBlakeHash: ethers.utils.hexlify(
        blakejs.blake2s(ethers.utils.arrayify(jsonFileContents.deployedBytecode.object))
      ),
      evmDeployedBytecodeLength: ethers.utils.arrayify(jsonFileContents.deployedBytecode.object).length,
    };
  } catch (err) {
    return defaultEVMBytecodeInfo();
  }
};

const getEVMSolidityContractsDetailsWithArtifactsDir = (workDir: string): SourceAndEvmCompilationDetails[] => {
  const artifactsDir = SOLIDITY_ARTIFACTS_DIR;
  const bytecodesDir = join(workDir, artifactsDir);
  const dirsEndingWithSol = findDirsEndingWith(bytecodesDir, ".sol").filter(
    (dirent) => !dirent.name.endsWith(".t.sol") && !dirent.name.endsWith(".s.sol") && !dirent.name.endsWith("Test.sol")
  );

  const compiledFiles = dirsEndingWithSol
    .map((d) => {
      const contractFiles = fs
        .readdirSync(join(d.path, d.name), { withFileTypes: true })
        .filter((dirent) => dirent.isFile() && dirent.name.endsWith(".json") && !dirent.name.includes("dbg"))
        .map((dirent) => dirent.name);

      return contractFiles.map((c) => {
        return join(d.path, d.name, c);
      });
    })
    .flat();

  return (
    compiledFiles
      .map((jsonFile) => {
        const jsonFileContents = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
        const info = getBytecodeInfoFromEvmJson(jsonFileContents);

        const evmBytecodePath = jsonFile.startsWith(join(__dirname, ".."))
          ? jsonFile.replace(join(__dirname, ".."), "")
          : jsonFile;

        const contractName = (jsonFile.split("/").pop() || "").replace(".json", "");

        return {
          contractName: join(workDir, contractName),
          evmBytecodePath,
          evmBytecodeHash: info.evmBytecodeHash,
          evmDeployedBytecodeHash: info.evmDeployedBytecodeHash,
          evmDeployedBytecodeBlakeHash: info.evmDeployedBytecodeBlakeHash,
          evmDeployedBytecodeLength: info.evmDeployedBytecodeLength,
        };
      })
      // ---------------------------------------------------------------------
      //  Filter out empty bytecode + check skipping logic
      // ---------------------------------------------------------------------
      .filter((c) => c.evmBytecodeHash != "0x" && !shouldSkipFolderOrFile(c.evmBytecodePath))
  );
};

const makePathAbsolute = (path: string): string => {
  return join(__dirname, "..", path);
};

const readSystemContractsHashesFile = (path: string): ContractsInfo[] => {
  const absolutePath = makePathAbsolute(path);
  try {
    const file = fs.readFileSync(absolutePath, "utf8");
    const parsedFile = JSON.parse(file);
    return parsedFile;
  } catch (err) {
    if ((err as { code?: string })?.code === "ENOENT") {
      console.warn(`File ${absolutePath} not found. Creating a new one.`);
      fs.writeFileSync(absolutePath, "[]");
      return [];
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to read file: ${absolutePath} Error: ${msg}`);
  }
};

const saveSystemContractsHashesFile = (path: string, systemContractsHashes: ContractsInfo[]) => {
  const absolutePath = makePathAbsolute(path);
  try {
    fs.writeFileSync(absolutePath, JSON.stringify(systemContractsHashes, null, 2) + os.EOL);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to save file: ${absolutePath} Error: ${msg}`);
  }
};

const findDifferences = (newHashes: ContractsInfo[], oldHashes: ContractsInfo[]) => {
  const differentElements = _.xorWith(newHashes, oldHashes, _.isEqual);

  const differentUniqueElements = _.uniqWith(differentElements, (a, b) => a.contractName === b.contractName);

  const differencesList = differentUniqueElements.map((diffElem) => {
    const newHashesElem = newHashes.find((elem) => elem.contractName === diffElem.contractName);

    const oldHashesElem = oldHashes.find((elem) => elem.contractName === diffElem.contractName);

    const differingFields = _.xorWith(
      Object.entries(newHashesElem || {}),
      Object.entries(oldHashesElem || {}),
      _.isEqual
    );

    const differingFieldsUniqueKeys = _.uniq(differingFields.map(([key]) => key));

    return {
      contract: diffElem.contractName,
      differingFields: differingFieldsUniqueKeys,
      old: oldHashesElem || {},
      new: newHashesElem || {},
    };
  });

  return differencesList;
};

const main = async () => {
  const args = process.argv.slice(2);
  const allowedArgs = new Set(["--check-only"]);
  if (args.some((arg) => !allowedArgs.has(arg)) || new Set(args).size !== args.length) {
    console.log(
      `Usage: calculate-hashes.ts [--check-only]. Use --check-only to check without updating ${OUTPUT_FILE_PATH}.`
    );
    process.exit(1);
  }
  const checkOnly = args.includes("--check-only");
  const oldSystemContractsHashes = readSystemContractsHashesFile(OUTPUT_FILE_PATH);

  // Strict manifest: exactly the ordinary-EVM artifacts this branch builds. Rows for
  // artifacts that can no longer be rebuilt (EraVM zkout, removed workspaces) are not carried.
  const newSystemContractsHashes: ContractsInfo[] = _.flatten(
    SOLIDITY_SOURCE_CODE_PATHS.map((sourcePath) => {
      const hashes = getEVMSolidityContractsDetailsWithArtifactsDir(sourcePath);
      if (hashes.length === 0) {
        throw new Error(`No EVM artifacts found for ${sourcePath}; run its build:foundry script first.`);
      }
      return hashes;
    })
  );

  console.log("New hashes: ", newSystemContractsHashes.length);
  if (_.isEqual(newSystemContractsHashes, oldSystemContractsHashes)) {
    console.log(`Calculated hashes match the hashes in the ${OUTPUT_FILE_PATH} file.`);
    console.log("Exiting...");
    return;
  }
  const differences = findDifferences(newSystemContractsHashes, oldSystemContractsHashes);
  console.log(`Calculated hashes differ from the hashes in the ${OUTPUT_FILE_PATH} file. Differences:`);
  console.log(differences);
  if (checkOnly) {
    console.log(`You can use the \`yarn calculate-hashes:fix\` command to update the ${OUTPUT_FILE_PATH} file.`);
    console.log("Exiting...");
    process.exit(1);
  } else {
    console.log("Updating...");
    saveSystemContractsHashesFile(OUTPUT_FILE_PATH, newSystemContractsHashes);
    console.log("Update finished");
    console.log("Exiting...");
    return;
  }
};

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    console.log("Please make sure the contract projects selected for hashing have been built first.");
    process.exit(1);
  });
