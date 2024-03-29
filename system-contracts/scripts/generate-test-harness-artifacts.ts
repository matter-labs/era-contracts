/// This script generates the `predeployed_contracts.json` needed for the https://github.com/matter-labs/test-contract
/// It will output a mapping from the address to the bytecode of the corresponding contract.

// hardhat import should be the first import in the file
import * as hre from "hardhat";

import * as fs from "fs";
import { ethers } from "ethers";
import { DEFAULT_ACCOUNT_CONTRACT_NAME, getSystemContractsBytecodes } from "./utils";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Provider, Wallet } from "zksync-web3";

const FILENAME = 'predeployed_contracts_artifacts.json';

interface PredeployedContractsOutput {
  predeployed_contracts: {
    [address: string]: string;
  };
  default_account_code: string;
}

async function main() {
  // We won't need the functionality of the wallet, but we still need to create the `Deployer` object to
  // easily work with artifacts.
  // We'll create a provider with testnet URL and a random wallet.
  const deployer = new Deployer(hre, Wallet.createRandom().connect(new Provider('https://zksync2-testnet.zksync.dev')));

  const defaultAccountBytecode = ethers.utils.hexlify((await deployer.loadArtifact(DEFAULT_ACCOUNT_CONTRACT_NAME)).bytecode);
  const systemContractBytecodes = await getSystemContractsBytecodes(deployer);

  const result: PredeployedContractsOutput = {
    'predeployed_contracts': {},
    'default_account_code': defaultAccountBytecode
  };
  for (const contract of systemContractBytecodes) {
    if (contract.factoryDeps.length !== 0) {
      throw new Error(`Contract ${contract.name} has factory dependencies. This script supports only bytecodes with no factory dependencies`);
    }
    result.predeployed_contracts[contract.address] = ethers.utils.hexlify(contract.bytecode);
  }

  fs.writeFileSync(FILENAME, JSON.stringify(result, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
