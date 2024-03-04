// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import type { BigNumberish, Wallet } from "ethers";
import type { FacetCut } from "./diamondCut";

import { testConfigPath } from "../src.ts/utils";
import { Deployer } from "./deploy";
import { deployTokens, getTokens } from "./deploy-token";
import {
  L2_BOOTLOADER_BYTECODE_HASH,
  L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  loadDefaultEnvVarsForTests,
  initialBridgehubDeployment,
  registerHyperchain,
} from "./deploy-process";
import * as fs from "fs";

const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));
const testnetTokenPath = `${testConfigPath}/hardhat.json`;

export async function defaultDeployerForTests(deployWallet: Wallet, ownerAddress: string): Promise<Deployer> {
  return new Deployer({
    deployWallet,
    ownerAddress,
    verbose: false, // change here to view deployement
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });
}

export async function initialTestnetDeploymentProcess(
  deployWallet: Wallet,
  ownerAddress: string,
  gasPrice: BigNumberish,
  extraFacets: FacetCut[],
  baseTokenName?: string
): Promise<Deployer> {
  await loadDefaultEnvVarsForTests(deployWallet);
  const deployer = await defaultDeployerForTests(deployWallet, ownerAddress);

  const testnetTokens = getTokens();
  const result = await deployTokens(testnetTokens, deployer.deployWallet, null, false, deployer.verbose);
  fs.writeFileSync(testnetTokenPath, JSON.stringify(result, null, 2));

  // deploy the verifier first
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, true, 1);
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false, 1);
  await registerHyperchain(deployer, extraFacets, gasPrice, baseTokenName);
  return deployer;
}
