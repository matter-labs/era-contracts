import { ethers } from "ethers";
import * as fs from "fs";
import _ from "lodash";
import os from "os";
import { join } from "path";
import { hashBytecode } from "zksync-ethers/build/utils";

const SOLIDITY_SOURCE_CODE_PATHS = ["system-contracts/", "l2-contracts/", "l1-contracts/", "da-contracts/"];
const YUL_SOURCE_CODE_PATHS = ["system-contracts/"];
const OUTPUT_FILE_PATH = "AllContractsHashes.json";

const SKIPPED_FOLDERS = ["l1-contracts/deploy-scripts"];
const FORCE_INCLUDE = ["Create2AndTransfer.sol"];

function getCanonicalNameFromFile(directory: string, fileName: string) {
  const folderName = SOLIDITY_SOURCE_CODE_PATHS.find(x => directory.startsWith(x));
  if(!folderName) {
    throw new Error('Unknown directory');
  }

  return `${folderName}${fileName}`;
}

// A path to the file in zkout/out folder, e.g. `/l1-contracts/zkout/ERC20.sol/ERC20.json`
function getCanonicalNameFromFoundryPath(foundryPath: string) {
  const folderName = SOLIDITY_SOURCE_CODE_PATHS.find(x => foundryPath.startsWith('/' + x));
  if(!folderName) {
    throw new Error('Unknown directory');
  }

  const fileName = foundryPath.split('/').find(x => x.endsWith('.sol'));
  if(!fileName) {
    // It may be a yul file, so we return null
    return null;
  }

  return `${folderName}${fileName}`;
}

function listSolFiles(directory: string): string[] {
  const solFiles: string[] = [];

  function searchDir(dir: string) {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
          const fullPath = join(dir, entry.name);
          if (entry.isDirectory()) {
              searchDir(fullPath);
          } else if (entry.isFile() && fullPath.endsWith('.sol')) {
              solFiles.push(getCanonicalNameFromFile(directory, entry.name));
          }
      }
  }

  searchDir(directory);
  return solFiles;
}

let cachedIgnoredFiles: any = null;

function shouldForceIncludeFile(filePath: string) {
  return FORCE_INCLUDE.some(x => filePath.includes(x));
}

function getIgnoredFiles() {
  if (cachedIgnoredFiles) {
    return cachedIgnoredFiles;
  }

  let res: any = {};

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
  const canonicalPath = getCanonicalNameFromFoundryPath(filePath);

  if(!canonicalPath) {
    return false;
  }

  return !!getIgnoredFiles()[canonicalPath]
}

type SourceContractDetails = {
  contractName: string;
};

type EvmCompilations = {
  evmBytecodePath: string | null;
  evmBytecodeHash: string | null;
  evmDeployedBytecodeHash: string | null;
};

type ZKCompilation = {
  zkBytecodePath: string | null;
  zkBytecodeHash: string | null;
};

type SourceAndEvmCompilationDetails = SourceContractDetails & EvmCompilations;
type SourceAndZKCompilationDetails = SourceContractDetails & ZKCompilation;

type ContractsInfo = SourceContractDetails & EvmCompilations & ZKCompilation;

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

const SOLIDITY_ARTIFACTS_ZK_DIR = "zkout";
const SOLIDITY_ARTIFACTS_DIR = "out";

const getBytecodeHashFromZkJson = (jsonFileContents: { bytecode: { object: string } }) => {
  try {
    return ethers.utils.hexlify(hashBytecode("0x" + jsonFileContents.bytecode.object));
  } catch (err) {
    return "0x";
  }
};

type EvmJsonFileContents = {
  bytecode: { object: string };
  deployedBytecode: { object: string };
};

const getBytecodeHashFromEvmJson = (jsonFileContents: EvmJsonFileContents) => {
  try {
    if (jsonFileContents.deployedBytecode.object == "0x") {
      return ["0x", "0x"];
    }
    return [
      ethers.utils.hexlify(
        ethers.utils.keccak256(ethers.utils.arrayify(ethers.utils.hexlify(jsonFileContents.bytecode.object)))
      ),
      ethers.utils.hexlify(
        ethers.utils.keccak256(ethers.utils.arrayify(ethers.utils.hexlify(jsonFileContents.deployedBytecode.object)))
      ),
    ];
  } catch (err) {
    return ["0x", "0x"];
  }
};

const getZkSolidityContractsDetailsWithArtifactsDir = (workDir: string): SourceAndZKCompilationDetails[] => {
  const artifactsDir = SOLIDITY_ARTIFACTS_ZK_DIR;
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

  return compiledFiles
    .map((jsonFile) => {
      const jsonFileContents = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
      const zkBytecodeHash = getBytecodeHashFromZkJson(jsonFileContents);

      const zkBytecodePath = jsonFile.startsWith(join(__dirname, ".."))
        ? jsonFile.replace(join(__dirname, ".."), "")
        : jsonFile;

      const contractName = (jsonFile.split("/").pop() || "").replace(".json", "");

      return {
        contractName: join(workDir, contractName),
        zkBytecodePath,
        zkBytecodeHash,
      };
    })
    // ---------------------------------------------------------------------
    //  Filter out empty bytecode + check skipping logic
    // ---------------------------------------------------------------------
    .filter((c) => c.zkBytecodeHash != "0x" && !shouldSkipFolderOrFile(c.zkBytecodePath));
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

  return compiledFiles
    .map((jsonFile) => {
      const jsonFileContents = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
      const hashes = getBytecodeHashFromEvmJson(jsonFileContents);

      const evmBytecodePath = jsonFile.startsWith(join(__dirname, ".."))
        ? jsonFile.replace(join(__dirname, ".."), "")
        : jsonFile;

      const contractName = (jsonFile.split("/").pop() || "").replace(".json", "");

      return {
        contractName: join(workDir, contractName),
        evmBytecodePath,
        evmBytecodeHash: hashes[0],
        evmDeployedBytecodeHash: hashes[1],
      };
    })
    // ---------------------------------------------------------------------
    //  Filter out empty bytecode + check skipping logic
    // ---------------------------------------------------------------------
    .filter((c) => c.evmBytecodeHash != "0x" && !shouldSkipFolderOrFile(c.evmBytecodePath));
};

const getSolidityContractsDetails = (dir: string): ContractsInfo[] => {
  const zkContracts = getZkSolidityContractsDetailsWithArtifactsDir(dir);
  const contracts = getEVMSolidityContractsDetailsWithArtifactsDir(dir);

  const mergedContracts: ContractsInfo[] = [];

  zkContracts.forEach((contract) => {
    const newContract: ContractsInfo = {
      contractName: contract.contractName,
      zkBytecodeHash: contract.zkBytecodeHash,
      zkBytecodePath: contract.zkBytecodePath,
      evmBytecodeHash: null,
      evmBytecodePath: null,
      evmDeployedBytecodeHash: null,
    };
    mergedContracts.push(newContract);
  });

  contracts.forEach((contract) => {
    const existingContract = mergedContracts.find((c) => c.contractName === contract.contractName);

    if (existingContract) {
      existingContract.evmBytecodeHash = contract.evmBytecodeHash;
      existingContract.evmBytecodePath = contract.evmBytecodePath;
      existingContract.evmDeployedBytecodeHash = contract.evmDeployedBytecodeHash;
    } else {
      const newContract: ContractsInfo = {
        contractName: contract.contractName,
        evmBytecodeHash: contract.evmBytecodeHash,
        evmBytecodePath: contract.evmBytecodePath,
        evmDeployedBytecodeHash: contract.evmDeployedBytecodeHash,
        zkBytecodeHash: null,
        zkBytecodePath: null,
      };
      mergedContracts.push(newContract);
    }
  });

  return mergedContracts;
};

const getYulContractsDetails = (dir: string): ContractsInfo[] => {
  const bytecodesDir = join(dir, SOLIDITY_ARTIFACTS_ZK_DIR);
  const dirsEndingWithYul = findDirsEndingWith(bytecodesDir, ".yul").filter(
    (dirent) => !dirent.name.endsWith(".t.sol")
  );

  const compiledFiles = dirsEndingWithYul
    .map((d) => {
      const contractFiles = fs
        .readdirSync(join(d.path, d.name), { withFileTypes: true, recursive: true })
        .filter((dirent) => dirent.isFile() && dirent.name.endsWith(".json") && !dirent.name.includes("dbg"));

      return contractFiles.map((c) => {
        return join(c.path, c.name);
      });
    })
    .flat();

  return compiledFiles
    .map((jsonFile) => {
      const jsonFileContents = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
      const zkBytecodeHash = getBytecodeHashFromZkJson(jsonFileContents);

      const zkBytecodePath = jsonFile.startsWith(join(__dirname, ".."))
        ? jsonFile.replace(join(__dirname, ".."), "")
        : jsonFile;

      const contractName = (jsonFile.split("/").pop() || "").replace(".json", "");

      return {
        contractName,
        zkBytecodePath,
        zkBytecodeHash,
        evmBytecodePath: null,
        evmBytecodeHash: null,
        evmDeployedBytecodeHash: null,
      };
    })
    // ---------------------------------------------------------------------
    //  Filter out empty bytecode + check skipping logic
    // ---------------------------------------------------------------------
    .filter((c) => c.zkBytecodeHash != "0x" && !shouldSkipFolderOrFile(c.zkBytecodePath));
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
  const args = process.argv;
  if (args.length > 3 || (args.length == 3 && !args.includes("--check-only"))) {
    console.log(
      "This command can be used with no arguments or with the --check-only flag. Use the --check-only flag to check the hashes without updating the SystemContractsHashes.json file."
    );
    process.exit(1);
  }
  const checkOnly = args.includes("--check-only");

  const solidityContractsDetails = _.flatten(SOLIDITY_SOURCE_CODE_PATHS.map(getSolidityContractsDetails));
  const yulContractsDetails = _.flatten(YUL_SOURCE_CODE_PATHS.map(getYulContractsDetails));
  const systemContractsDetails = [...solidityContractsDetails, ...yulContractsDetails];

  console.log("New hashes: ", systemContractsDetails.length);

  const newSystemContractsHashes = systemContractsDetails;
  const oldSystemContractsHashes = readSystemContractsHashesFile(OUTPUT_FILE_PATH);
  if (_.isEqual(newSystemContractsHashes, oldSystemContractsHashes)) {
    console.log("Calculated hashes match the hashes in the SystemContractsHashes.json file.");
    console.log("Exiting...");
    return;
  }
  const differences = findDifferences(newSystemContractsHashes, oldSystemContractsHashes);
  console.log("Calculated hashes differ from the hashes in the SystemContractsHashes.json file. Differences:");
  console.log(differences);
  if (checkOnly) {
    console.log("You can use the `yarn calculate-hashes:fix` command to update the AllContractsHashes.json file.");
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
    console.log("Please make sure to run `yarn sc build` before running this script.");
    process.exit(1);
  });
