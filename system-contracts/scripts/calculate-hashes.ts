import { ethers } from "ethers";
import * as fs from "fs";
import _ from "lodash";
import os from "os";
import { join } from "path";
import { hashBytecode } from "zksync-web3/build/src/utils";

type ContractDetails = {
  contractName: string;
  bytecodePath: string;
  sourceCodePath: string;
};

type Hashes = {
  bytecodeHash: string;
  sourceCodeHash: string;
};

type SystemContractHashes = ContractDetails & Hashes;

const findDirsEndingWith = (path: string, endingWith: string): string[] => {
  const absolutePath = makePathAbsolute(path);
  try {
    const dirs = fs.readdirSync(absolutePath, { withFileTypes: true }).filter((dirent) => dirent.isDirectory());
    const dirsEndingWithSol = dirs.filter((dirent) => dirent.name.endsWith(endingWith));
    return dirsEndingWithSol.map((dirent) => dirent.name);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to read directory: ${absolutePath} Error: ${msg}`);
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

const SOLIDITY_ARTIFACTS_DIR = "artifacts-zk";

const getSolidityContractDetails = (dir: string, contractName: string): ContractDetails => {
  const bytecodePath = join(SOLIDITY_ARTIFACTS_DIR, dir, contractName + ".sol", contractName + ".json");
  const sourceCodePath = join(dir, contractName + ".sol");
  return {
    contractName,
    bytecodePath,
    sourceCodePath,
  };
};

const getSolidityContractsDetails = (dir: string): ContractDetails[] => {
  const bytecodesDir = join(SOLIDITY_ARTIFACTS_DIR, dir);
  const dirsEndingWithSol = findDirsEndingWith(bytecodesDir, ".sol");
  const contractNames = dirsEndingWithSol.map((d) => d.replace(".sol", ""));
  const solidityContractsDetails = contractNames.map((c) => getSolidityContractDetails(dir, c));
  return solidityContractsDetails;
};

const YUL_ARTIFACTS_DIR = "artifacts";

const getYulContractDetails = (dir: string, contractName: string): ContractDetails => {
  const bytecodePath = join(dir, YUL_ARTIFACTS_DIR, contractName + ".yul.zbin");
  const sourceCodePath = join(dir, contractName + ".yul");
  return {
    contractName,
    bytecodePath,
    sourceCodePath,
  };
};

const getYulContractsDetails = (dir: string): ContractDetails[] => {
  const dirsEndingWithYul = findFilesEndingWith(dir, ".yul");
  const contractNames = dirsEndingWithYul.map((d) => d.replace(".yul", ""));
  const yulContractsDetails = contractNames.map((c) => getYulContractDetails(dir, c));
  return yulContractsDetails;
};

const makePathAbsolute = (path: string): string => {
  return join(__dirname, "..", path);
};

const readSourceCode = (details: ContractDetails): string => {
  const absolutePath = makePathAbsolute(details.sourceCodePath);
  try {
    return ethers.utils.hexlify(fs.readFileSync(absolutePath));
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to read source code for ${details.contractName}: ${absolutePath} Error: ${msg}`);
  }
};

const readBytecode = (details: ContractDetails): string => {
  const absolutePath = makePathAbsolute(details.bytecodePath);
  try {
    if (details.bytecodePath.endsWith(".json")) {
      const jsonFile = fs.readFileSync(absolutePath, "utf8");
      return ethers.utils.hexlify(JSON.parse(jsonFile).bytecode);
    } else {
      return ethers.utils.hexlify(fs.readFileSync(absolutePath));
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to read bytecode for ${details.contractName}: ${details.bytecodePath} Error: ${msg}`);
  }
};

const getHashes = (contractName: string, sourceCode: string, bytecode: string): Hashes => {
  try {
    return {
      bytecodeHash: ethers.utils.hexlify(hashBytecode(bytecode)),
      // The extra checks performed by the hashBytecode function are not needed for the source code, therefore
      // sha256 is used for simplicity
      sourceCodeHash: ethers.utils.sha256(sourceCode),
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to calculate hashes for ${contractName} Error: ${msg}`);
  }
};

const getSystemContractsHashes = (systemContractsDetails: ContractDetails[]): SystemContractHashes[] =>
  systemContractsDetails.map((contractDetails) => {
    const sourceCode = readSourceCode(contractDetails);
    const bytecode = readBytecode(contractDetails);
    const hashes = getHashes(contractDetails.contractName, sourceCode, bytecode);

    const systemContractHashes: SystemContractHashes = {
      ...contractDetails,
      ...hashes,
    };

    return systemContractHashes;
  });

const readSystemContractsHashesFile = (path: string): SystemContractHashes[] => {
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

const saveSystemContractsHashesFile = (path: string, systemContractsHashes: SystemContractHashes[]) => {
  const absolutePath = makePathAbsolute(path);
  try {
    fs.writeFileSync(absolutePath, JSON.stringify(systemContractsHashes, null, 2) + os.EOL);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    throw new Error(`Failed to save file: ${absolutePath} Error: ${msg}`);
  }
};

const findDifferences = (newHashes: SystemContractHashes[], oldHashes: SystemContractHashes[]) => {
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

const SOLIDITY_SOURCE_CODE_PATHS = ["contracts-preprocessed"];
const YUL_SOURCE_CODE_PATHS = ["contracts-preprocessed", "contracts-preprocessed/precompiles", "bootloader/build"];
const OUTPUT_FILE_PATH = "SystemContractsHashes.json";

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

  const newSystemContractsHashes = getSystemContractsHashes(systemContractsDetails);
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
