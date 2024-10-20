// hardhat import should be the first import in the file
import * as hre from "hardhat";

import { ethers } from "ethers";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { render, renderFile } from "template-file";
import { utils } from "zksync-ethers";
import { getRevertSelector, getTransactionUtils, SYSTEM_CONTRACTS } from "./constants";
import * as fs from "node:fs";

const savedHashes = require('../SystemContractsHashes.json');

function getSavedHash(name: string) {
    // @ts-ignore
    return savedHashes.find(x => x.contractName == name).bytecodeHash;
}

// Shows the correct standard force deployment data.
// uses `SYSTEM_CONTRACTS` for order and the saved hashes for the hashes.
async function main() {
    const deployments: any[] = [];
    for (const contract of Object.values(SYSTEM_CONTRACTS)) {
        const forceDeployment = {
            bytecodeHash: getSavedHash(contract.codeName),
            newAddress: contract.address,
            callConstructor: false,
            value: 0,
            input: '0x'
        }
        deployments.push(forceDeployment);
    }

    const encodedData = (new ethers.utils.Interface(
        hre.artifacts.readArtifactSync('ContractDeployer').abi
    )).encodeFunctionData('forceDeployOnAddresses', [deployments]);

    console.log(encodedData);

}
  
main();
  