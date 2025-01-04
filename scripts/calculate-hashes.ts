import { assert } from "console";
import { ethers } from "ethers";
import * as fs from "fs";
import _ from "lodash";
import os from "os";
import { join } from "path";
import { json } from "stream/consumers";
import { hashBytecode } from "zksync-ethers/build/utils";



type SourceContractDetails = {
  contractName: string;
  sourceCodePath: string;
  sourceCodeHash: string;
}

type CompilationDetails = {
  bytecodePath: string;
  bytecodeHash: string;
}

type SourceAndCompilationDetails = SourceContractDetails & CompilationDetails;

type AllCompilations = {
  evm: CompilationDetails | null;
  zk: CompilationDetails | null;
}


type ContractsInfo = SourceContractDetails & AllCompilations;


const findDirsEndingWith = (path: string, endingWith: string): fs.Dirent[] => {
  const absolutePath = makePathAbsolute(path);
  try {
    const dirs = fs.readdirSync(absolutePath, { withFileTypes: true, recursive: true }).filter((dirent) => dirent.isDirectory());
    const dirsEndingWithSol = dirs.filter((dirent) => dirent.name.endsWith(endingWith));
    return dirsEndingWithSol;
  } catch (err) {
    return [];
  }
};

const findFilesEndingWith = (path: string, endingWith: string): string[] => {
  const absolutePath = makePathAbsolute(path);
  try {
    const files = fs.readdirSync(absolutePath, { withFileTypes: true }).filter((dirent) => dirent.isFile());
    const filesEndingWithSol = files.filter((dirent) => dirent.name.endsWith(endingWith));
    return filesEndingWithSol.map((dirent) => dirent.name);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to read directory: ${absolutePath} Error: ${msg}`);
  }
};

const SOLIDITY_ARTIFACTS_ZK_DIR = "artifacts-zk";
const SOLIDITY_ARTIFACTS_DIR = "artifacts";


const getSolidityContractsDetailsWithArtifactsDir = (dir: string, zkBytecode: boolean): SourceAndCompilationDetails[] => {
  const [workDir, subDir] = dir.split('/');
  const artifactsDir = zkBytecode ? SOLIDITY_ARTIFACTS_ZK_DIR : SOLIDITY_ARTIFACTS_DIR;
  const bytecodesDir = join(workDir, artifactsDir, subDir);
  const dirsEndingWithSol = findDirsEndingWith(bytecodesDir, ".sol");

  const compiledFiles = dirsEndingWithSol.map((d) => {
    const contractFiles = fs.readdirSync(join(d.path, d.name), { withFileTypes: true })
      .filter((dirent) => dirent.isFile() && dirent.name.endsWith(".json") && !dirent.name.includes("dbg"))
      .map((dirent) => dirent.name);


    return contractFiles.map((c) => {
      return join(d.path, d.name, c)
    });
  }).flat();

  return compiledFiles.map((jsonFile) => {
    const jsonFileContents = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
    const bytecode = ethers.utils.hexlify(jsonFileContents.deployedBytecode);
    const bytecodeHash = (bytecode == "0x") ?
      "0x"
      : zkBytecode ?
        ethers.utils.hexlify(hashBytecode(bytecode)) : ethers.utils.hexlify(ethers.utils.sha256(ethers.utils.arrayify(bytecode)))
      ;

    const bytecodePath = jsonFile.startsWith(join(__dirname, '..'))
      ? jsonFile.replace(join(__dirname, '..'), "")
      : jsonFile;

    return ({
      contractName: jsonFileContents.contractName,
      sourceCodePath: jsonFileContents.sourceName,
      sourceCodeHash: ethers.utils.sha256(ethers.utils.hexlify(fs.readFileSync(join(workDir, jsonFileContents.sourceName)))),
      bytecodePath,
      bytecodeHash,
    });
    // Filter out the interfaces (that don't have any bytecode).
  }).filter((c) => c.bytecodeHash != "0x");

};


const getSolidityContractsDetails = (dir: string): ContractsInfo[] => {
  const zkContracts = getSolidityContractsDetailsWithArtifactsDir(dir, true);
  const contracts = getSolidityContractsDetailsWithArtifactsDir(dir, false);

  const mergedContracts: ContractsInfo[] = [];

  const allContracts = [...zkContracts, ...contracts];

  allContracts.forEach((contract) => {
    const existingContract = mergedContracts.find(
      (c) => c.contractName === contract.contractName && c.sourceCodePath === contract.sourceCodePath
    );

    if (existingContract) {
      if (contract.bytecodePath.includes(SOLIDITY_ARTIFACTS_ZK_DIR)) {
        existingContract.zk = {
          bytecodePath: contract.bytecodePath,
          bytecodeHash: contract.bytecodeHash,
        };
      } else {
        existingContract.evm = {
          bytecodePath: contract.bytecodePath,
          bytecodeHash: contract.bytecodeHash,
        };
      }
    } else {
      const newContract: ContractsInfo = {
        contractName: contract.contractName,
        sourceCodePath: contract.sourceCodePath,
        sourceCodeHash: contract.sourceCodeHash,
        evm: contract.bytecodePath.includes(SOLIDITY_ARTIFACTS_ZK_DIR)
          ? null
          : {
            bytecodePath: contract.bytecodePath,
            bytecodeHash: contract.bytecodeHash,
          },
        zk: contract.bytecodePath.includes(SOLIDITY_ARTIFACTS_ZK_DIR)
          ? {
            bytecodePath: contract.bytecodePath,
            bytecodeHash: contract.bytecodeHash,
          }
          : null,
      };
      mergedContracts.push(newContract);
    }
  });

  return mergedContracts;
};

const YUL_ARTIFACTS_DIR = "artifacts";

const getYulContractDetails = (dir: string, contractName: string): ContractsInfo => {
  const bytecodePath = join(dir, YUL_ARTIFACTS_DIR, contractName + ".yul.zbin");
  const sourceCodePath = join(dir, contractName + ".yul");
  return {
    contractName,
    sourceCodePath,
    sourceCodeHash: ethers.utils.sha256(ethers.utils.hexlify(fs.readFileSync(sourceCodePath))),
    zk: {
      bytecodePath,
      bytecodeHash: ethers.utils.hexlify(hashBytecode(fs.readFileSync(bytecodePath))),
    },
    evm: null
  };
};

const getYulContractsDetails = (dir: string): ContractsInfo[] => {
  const filesEndingWithYul = findFilesEndingWith(dir, ".yul");
  const contractNames = filesEndingWithYul.map((d) => d.replace(".yul", ""));
  const yulContractsDetails = contractNames.map((c) => getYulContractDetails(dir, c));
  return yulContractsDetails;
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

const SOLIDITY_SOURCE_CODE_PATHS = [
  "system-contracts/contracts-preprocessed",
  "l2-contracts/contracts",
  "l1-contracts/contracts"
];
const YUL_SOURCE_CODE_PATHS = ["system-contracts/contracts-preprocessed", "system-contracts/contracts-preprocessed/precompiles", "system-contracts/bootloader/build"];
const OUTPUT_FILE_PATH = "AllContractsHashes.json";

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
    console.log(
      "You can use the `yarn sc calculate-hashes:fix` command to update the SystemContractsHashes.json file."
    );
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
