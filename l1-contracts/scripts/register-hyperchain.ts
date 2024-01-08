import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import * as fs from "fs";
import * as path from "path";
import { web3Provider, getTokens, ADDRESS_ONE } from "./utils";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function main() {
  const program = new Command();

  program.version("0.1.0").name("register-hyperchain").description("register hyperchains");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--governor-address <governor-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .option("--base-token-name <base-token-name>")
    .option("--base-token-address <base-token-address>")
    .action(async (cmd) => {
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const ownerAddress = cmd.governorAddress || process.env.GOVERNOR_ADDRESS || deployWallet.address;
      console.log(`Using governor address: ${ownerAddress}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const create2Salt = cmd.create2Salt ? cmd.create2Salt : ethers.utils.hexlify(ethers.utils.randomBytes(32));

      const deployer = new Deployer({
        deployWallet,
        ownerAddress,
        verbose: true,
      });

      let baseTokenAddress = cmd.baseTokenAddress ? cmd.baseTokenAddress : ADDRESS_ONE;
      if (baseTokenAddress != ethers.constants.AddressZero && baseTokenAddress != ADDRESS_ONE) {
        if ((await deployWallet.provider.getCode(cmd.baseTokenAddress)) == "0x") {
          throw new Error(`Token ${cmd.baseTokenAddress} is not deployed`);
        }
        console.log(`Using base token at ${baseTokenAddress}`);
      } else if (cmd.baseTokenName) {
        const tokens = getTokens(process.env.CHAIN_ETH_NETWORK);
        const token = tokens.find((token: { symbol: string }) => token.symbol == cmd.baseTokenName);
        if (!token) {
          throw new Error(`Token ${cmd.baseTokenName} not found`);
        } else if (!token.address) {
          throw new Error(`Token ${cmd.baseTokenName} has no address`);
        }
        baseTokenAddress = token.address;
        console.log(`Using base token ${cmd.baseTokenName} at ${baseTokenAddress}`);
      }  else if (baseTokenAddress == ADDRESS_ONE) {
        // base token is eth, we are ok.
        console.log(`Using ETH as base token at ${baseTokenAddress}`);
      }

      if (!(await deployer.bridgehubContract(deployWallet).tokenIsRegistered(baseTokenAddress))) {
        await deployer.registerToken(baseTokenAddress, gasPrice);
      }

      await deployer.registerHyperchain(baseTokenAddress, create2Salt, null, gasPrice);
      await deployer.deployValidatorTimelock(create2Salt, { gasPrice });
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
