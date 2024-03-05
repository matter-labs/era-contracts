// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

// import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import { Wallet } from "ethers";
import { web3Provider } from "./utils";

import type { TokenDescription } from "../src.ts/deploy-token";
import { deployTokens, deployContracts, mintTokens } from "../src.ts/deploy-token";

import { ethTestConfig } from "../src.ts/utils";

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-erc20").description("deploy testnet erc20 token");

  program
    .command("add")
    .option("--private-key <private-key>")
    .option("-n, --token-name <tokenName>")
    .option("-s, --symbol <symbol>")
    .option("-d, --decimals <decimals>")
    .option("-i --implementation <implementation>")
    .description("Adds a new token with a given fields")
    .action(async (cmd) => {
      const token: TokenDescription = {
        address: null,
        name: cmd.tokenName,
        symbol: cmd.symbol,
        decimals: cmd.decimals,
        implementation: cmd.implementation,
      };

      const wallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(ethTestConfig.mnemonic, "m/44'/60'/0'/0/1").connect(provider);

      console.log(JSON.stringify(await deployTokens([token], wallet, ethTestConfig.mnemonic, true, false), null, 2));
    });

  program
    .command("add-multi <tokens_json>")
    .option("--private-key <private-key>")
    .description("Adds a multiple tokens given in JSON format")
    .action(async (tokens_json: string, cmd) => {
      const tokens: Array<TokenDescription> = JSON.parse(tokens_json);

      const wallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(ethTestConfig.mnemonic, "m/44'/60'/0'/0/1").connect(provider);

      const nonce = await deployContracts(tokens, wallet);
      const result = await mintTokens(tokens, wallet, nonce, ethTestConfig.mnemonic);

      console.log(JSON.stringify(result, null, 2));
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
