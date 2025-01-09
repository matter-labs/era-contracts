/// Temporary script that helps to generate the calldata to the gateway upgrade.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import { Command } from "commander";
import { Provider } from "zksync-ethers";
import { ethers } from "ethers";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-new-generator");

  program
    .option("--l2-rpc-url <web3-rpc-url>")
    .option("--l1-rpc-url <web3-rpc-url>")
    .action(async (cmd) => {
      const l1Provider = new ethers.providers.JsonRpcProvider(cmd.l1RpcUrl);
      const l2Provider = new Provider(cmd.l2RpcUrl);

      const bridgehubAddr = await l2Provider.getBridgehubContractAddress();
      const proxyAdmin = await l1Provider.getStorageAt(
        bridgehubAddr,
        "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
      );

      console.log(`bridgehub_proxy_address = "${bridgehubAddr}"`);
      console.log(`transparent_proxy_admin = "0x${proxyAdmin.substring(26)}"`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
