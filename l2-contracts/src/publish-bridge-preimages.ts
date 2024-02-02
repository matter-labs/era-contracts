import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import * as fs from "fs";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import * as path from "path";
import { getNumberFromEnv, web3Provider } from "../../l1-contracts/scripts/utils";
import * as hre from "hardhat";
import { REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

const PRIORITY_TX_MAX_GAS_LIMIT = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");
const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

function getContractBytecode(contractName: string) {
  return hre.artifacts.readArtifactSync(contractName).bytecode;
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("publish-bridge-preimages");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--nonce <nonce>")
    .option("--gas-price <gas-price>")
    .action(async (cmd) => {
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const wallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using wallet: ${wallet.address}`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await wallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const gasPrice = cmd.gasPrice ? parseInt(cmd.gasPrice) : await wallet.getGasPrice();
      console.log(`Using gas price: ${gasPrice}`);

      const deployer = new Deployer({ deployWallet: wallet });
      const bridgehub = deployer.bridgehubContract(wallet);

      const publishL2ERC20BridgeTx = await bridgehub.requestL2TransactionDirect(
        {
          chainId,
          l2Contract: ethers.constants.AddressZero,
          mintValue: 0,
          l2Value: 0,
          l2Calldata: "0x",
          l2GasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
          l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
          factoryDeps: [getContractBytecode("L2ERC20Bridge")],
          refundRecipient: wallet.address,
        },
        { nonce, gasPrice }
      );
      await publishL2ERC20BridgeTx.wait();
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
