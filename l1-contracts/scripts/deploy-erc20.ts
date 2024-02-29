// hardhat import should be the first import in the file
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import type { Contract } from "ethers";
import { Wallet } from "ethers";
import { parseEther } from "ethers/lib/utils";
import { web3Provider } from "./utils";
import * as fs from "fs";
import * as path from "path";

const DEFAULT_ERC20 = "TestnetERC20Token";

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const provider = web3Provider();

type Token = {
  address: string | null;
  name: string;
  symbol: string;
  decimals: number;
};

type TokenDescription = Token & {
  implementation?: string;
  contract?: Contract;
};

async function deployContracts(tokens: TokenDescription[], wallet: Wallet): Promise<number> {
  let nonce = await wallet.getTransactionCount("pending");

  for (const token of tokens) {
    token.implementation = token.implementation || DEFAULT_ERC20;
    const tokenFactory = await hardhat.ethers.getContractFactory(token.implementation, wallet);
    const args = token.implementation !== "WETH9" ? [token.name, token.symbol, token.decimals] : [];

    token.contract = await tokenFactory.deploy(...args, { gasLimit: 5000000, nonce: nonce++ });
  }

  await Promise.all(tokens.map(async (token) => token.contract.deployTransaction.wait()));

  return nonce;
}

function getTestAddresses(): string[] {
  return Array.from(
    { length: 10 },
    (_, i) =>
      Wallet.fromMnemonic(ethTestConfig.test_mnemonic as string, `m/44'/60'/0'/0/${i}`).connect(provider).address
  );
}

function unwrapToken(token: TokenDescription): Token {
  token.address = token.contract.address;

  delete token.contract;
  if (token.implementation) {
    delete token.implementation;
  }

  return token;
}

async function mintTokens(tokens: TokenDescription[], wallet: Wallet, nonce: number): Promise<Token[]> {
  const targetAddresses = [wallet.address, ...getTestAddresses()];

  const results = [];
  const promises = [];
  for (const token of tokens) {
    if (token.implementation !== "WETH9") {
      for (const address of targetAddresses) {
        const tx = await token.contract.mint(address, parseEther("3000000000"), { nonce: nonce++ });
        promises.push(tx.wait());
      }
    }

    results.push(unwrapToken(token));
  }
  await Promise.all(promises);

  return results;
}

async function deployToken(token: TokenDescription, wallet: Wallet): Promise<Token> {
  token.implementation = token.implementation || DEFAULT_ERC20;
  const tokenFactory = await hardhat.ethers.getContractFactory(token.implementation, wallet);
  const args = token.implementation !== "WETH9" ? [token.name, token.symbol, token.decimals] : [];
  const erc20 = await tokenFactory.deploy(...args, { gasLimit: 5000000 });
  await erc20.deployTransaction.wait();

  if (token.implementation !== "WETH9") {
    await erc20.mint(wallet.address, parseEther("3000000000"));

    for (let i = 0; i < 10; ++i) {
      const testWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic as string, "m/44'/60'/0'/0/" + i).connect(
        provider
      );

      await erc20.mint(testWallet.address, parseEther("3000000000"));
    }
  }

  token.address = erc20.address;

  // Remove the unneeded field
  if (token.implementation) {
    delete token.implementation;
  }

  return token;
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-erc20").description("deploy testnet erc20 token");

  program
    .command("add")
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

      console.log(JSON.stringify(await deployToken(token, wallet), null, 2));
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
      const result = await mintTokens(tokens, wallet, nonce);

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
