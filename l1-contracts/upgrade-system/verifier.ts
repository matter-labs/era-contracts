// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import type { BigNumber } from "ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import { deployViaCreate2 } from "../src.ts/deploy-utils";
import { web3Url } from "zk/build/utils";
import * as path from "path";
import { insertGasPrice } from "./utils";

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function deployVerifier(
  l1Rpc: string,
  create2Address: string,
  nonce?: number,
  gasPrice?: BigNumber,
  privateKey?: string,
  file?: string,
  create2Salt?: string
) {
  const provider = new ethers.providers.JsonRpcProvider(l1Rpc);
  const wallet = privateKey
    ? new ethers.Wallet(privateKey, provider)
    : ethers.Wallet.fromMnemonic(
        process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
        "m/44'/60'/0'/0/1"
      ).connect(provider);

  create2Salt = create2Salt ?? ethers.constants.HashZero;

  const ethTxOptions = {};
  if (!nonce) {
    ethTxOptions["nonce"] = await wallet.getTransactionCount();
  }
  if (!gasPrice) {
    await insertGasPrice(provider, ethTxOptions);
  }
  ethTxOptions["gasLimit"] = 10_000_000;
  const [address, txHash] = await deployViaCreate2(
    wallet,
    "Verifier",
    [],
    create2Salt,
    ethTxOptions,
    create2Address,
    true
  );

  console.log(JSON.stringify({ address, txHash }, null, 2));
  if (file) {
    fs.writeFileSync(file, JSON.stringify({ address, txHash }, null, 2));
  }
  return [address, txHash];
}

export const command = new Command("verifier").description("Verifier commands");

command
  .command("deploy")
  .option("--l1rpc <l1Rpc>")
  .option("--private-key <privateKey>")
  .option("--create2-address <create2Address>")
  .option("--file <file>")
  .option("--nonce <nonce>")
  .option("--gas-price <gasPrice>")
  .option("--create2-salt <create2Salt>")
  .description("deploy verifier")
  .action(async (cmd) => {
    const l1Rpc = cmd.l1Rpc ?? web3Url();
    await deployVerifier(l1Rpc, cmd.create2Address, cmd.nonce, cmd.gasPrice, cmd.privateKey, cmd.file, cmd.create2Salt);
  });
