import * as hardhat from "hardhat";
import type { Wallet } from "ethers";
import * as fs from "fs";

export async function deployTestnetTokens(tokens: any, wallet: Wallet, outputPath: string, verbose: boolean = false) {
  const result = [];

  for (const token of tokens) {
    if (token.symbol != "WETH") {
      const constructorArgs = [
        `${token.name} (${process.env.CHAIN_ETH_NETWORK})`,
        token.symbol,
        token.decimals,
        { gasLimit: 1200000 },
      ];
      if (verbose) {
        console.log(`Deploying testnet ERC20: ${constructorArgs.toString()}`);
      }
      const tokenFactory = await hardhat.ethers.getContractFactory("TestnetERC20Token");
      const erc20 = await tokenFactory.deploy(...constructorArgs);
      const testnetToken = token;
      testnetToken.address = erc20.address;
      result.push(testnetToken);
    } else {
      if (verbose) {
        console.log("Deploying testnet WETH");
      }
      const tokenFactory = await hardhat.ethers.getContractFactory("WETH9", wallet);
      const weth = await tokenFactory.deploy({ gasLimit: 800000 });
      const testnetToken = token;
      testnetToken.address = weth.address;
      if (verbose) {
        console.log(`WETH deployed at ${weth.address}`);
      }
      result.push(testnetToken);
    }
  }

  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2));
}
