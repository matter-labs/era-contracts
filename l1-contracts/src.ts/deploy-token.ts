import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { Wallet } from "ethers";
import type { Contract } from "ethers";
import { parseEther } from "ethers/lib/utils";

import * as fs from "fs";

const DEFAULT_ERC20 = "TestnetERC20Token";

export type L1Token = {
  address: string | null;
  name: string;
  symbol: string;
  decimals: number;
};

export type TokenDescription = L1Token & {
  implementation?: string;
  contract?: Contract;
};

export async function deployContracts(tokens: TokenDescription[], wallet: Wallet): Promise<number> {
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

function getTestAddresses(mnemonic: string): string[] {
  return Array.from({ length: 10 }, (_, i) => Wallet.fromMnemonic(mnemonic as string, `m/44'/60'/0'/0/${i}`).address);
}

function unwrapToken(token: TokenDescription): L1Token {
  token.address = token.contract.address;

  delete token.contract;
  if (token.implementation) {
    delete token.implementation;
  }

  return token;
}

export async function mintTokens(
  tokens: TokenDescription[],
  wallet: Wallet,
  nonce: number,
  mnemonic: string
): Promise<L1Token[]> {
  const targetAddresses = [wallet.address, ...getTestAddresses(mnemonic)];

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

export function getTokens(): L1Token[] {
  const network = process.env.CHAIN_ETH_NETWORK || "localhost";
  const configPath =
    network == "hardhat"
      ? `./test/test_config/constant/${network}.json`
      : `${process.env.ZKSYNC_HOME}/etc/tokens/${network}.json`;
  return JSON.parse(
    fs.readFileSync(configPath, {
      encoding: "utf-8",
    })
  );
}

export async function deployTokens(
  tokens: TokenDescription[],
  wallet: Wallet,
  mnemonic: string,
  mintTokens: boolean = false,
  verbose: boolean = false
): Promise<L1Token[]> {
  const result: L1Token[] = [];
  for (const token of tokens) {
    const implementation = token.implementation || token.symbol != "WETH" ? DEFAULT_ERC20 : "WETH9";
    const tokenFactory = await hardhat.ethers.getContractFactory(implementation, wallet);
    const args =
      token.symbol != "WETH" ? [`${token.name} (${process.env.CHAIN_ETH_NETWORK})`, token.symbol, token.decimals] : [];
    if (verbose) {
      console.log(`Deploying testnet ${token.symbol}`, implementation);
    }
    const erc20 = await tokenFactory.deploy(...args, { gasLimit: 3000000 });
    await erc20.deployTransaction.wait();
    token.address = erc20.address;
    if (verbose) {
      console.log(`Token ${token.symbol} deployed at ${erc20.address}`);
    }

    if (token.symbol !== "WETH" && mintTokens) {
      await erc20.mint(wallet.address, parseEther("3000000000"));
    }
    if (mintTokens) {
      for (let i = 0; i < 10; ++i) {
        const testWalletAddress = Wallet.fromMnemonic(mnemonic as string, "m/44'/60'/0'/0/" + i).address;
        if (token.symbol !== "WETH") {
          await erc20.mint(testWalletAddress, parseEther("3000000000"));
        }
      }
    }
    // Remove the unneeded field
    // if (token.implementation) {
    //   delete token.implementation;
    // }
    result.push(token);
  }
  return result;
}
