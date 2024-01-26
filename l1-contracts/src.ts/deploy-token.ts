import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { Wallet } from "ethers";
import * as fs from "fs";
import { parseEther } from "ethers/lib/utils";

const DEFAULT_ERC20 = "TestnetERC20Token";

export type Token = {
  address: string | null;
  name: string;
  symbol: string;
  decimals: number;
};

export type TokenDescription = Token & {
  implementation?: string;
};

export async function deployTokens(tokens: Token[], wallet: Wallet, mnemonic: any, mintTokens: boolean=false, verbose : boolean = false): Promise<Token[]> {
  const result :Token[] = [];
  for (const token of tokens) {

    const implementation = (token.symbol != "WETH") ? DEFAULT_ERC20 : "WETH9" ;
    const tokenFactory = await hardhat.ethers.getContractFactory(implementation, wallet);
    const args = (token.symbol != "WETH") ? [`${token.name} (${process.env.CHAIN_ETH_NETWORK})`, token.symbol, token.decimals] : [];
    if (verbose) {
      console.log(`Deploying testnet ${token.symbol}`, implementation);
    }
    const erc20 = await tokenFactory.deploy(...args, { gasLimit: 3000000 });
    await erc20.deployTransaction.wait();
    token.address = erc20.address;
    if (verbose) {
      console.log(`Token ${token.symbol} deployed at ${erc20.address}`);
    }

    if ((token.symbol !== "WETH") && mintTokens) {
      await erc20.mint(wallet.address, parseEther("3000000000"));
    }
    if (mintTokens) {
      for (let i = 0; i < 10; ++i) {
        const testWallet = Wallet.fromMnemonic(mnemonic as string, "m/44'/60'/0'/0/" + i).connect(
          wallet.provider
        );
        if (token.symbol !== "WETH")  {
          await erc20.mint(testWallet.address, parseEther("3000000000"));
        }
      }
    }
    
    result.push(token);
  }
  return result;
}