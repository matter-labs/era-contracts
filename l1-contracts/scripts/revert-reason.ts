// hardhat import should be the first import in the file
import * as hardhat from "hardhat";

import * as chalk from "chalk";
import { ethers } from "ethers";
import { Interface } from "ethers/lib/utils";
import { web3Url } from "./utils";

const erc20BridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1ERC20Bridge").abi);
const zkSyncInterface = new Interface(hardhat.artifacts.readArtifactSync("IZkSync").abi);
const verifierInterface = new Interface(hardhat.artifacts.readArtifactSync("Verifier").abi);

const interfaces = [erc20BridgeInterface, zkSyncInterface, verifierInterface];

function decodeTransaction(contractInterface, tx) {
  try {
    return contractInterface.parseTransaction({ data: tx.data });
  } catch {
    return null;
  }
}

function hex_to_ascii(str1) {
  const hex = str1.toString();
  let str = "";
  for (let n = 0; n < hex.length; n += 2) {
    str += String.fromCharCode(parseInt(hex.substr(n, 2), 16));
  }
  return str;
}

async function reason() {
  const args = process.argv.slice(2);
  const hash = args[0];
  const web3 = args[1] == null ? web3Url() : args[1];
  console.log("tx hash:", hash);
  console.log("provider:", web3);

  const provider = new ethers.providers.JsonRpcProvider(web3);

  const tx = await provider.getTransaction(hash);
  tx.gasPrice = null;
  if (!tx) {
    console.log("tx not found");
  } else {
    try {
      const parsedTransaction = interfaces
        .map((contractInterface) => decodeTransaction(contractInterface, tx))
        .find((tx) => tx != null);

      if (parsedTransaction) {
        console.log("parsed tx: ", parsedTransaction.name, parsedTransaction);
        console.log("tx args: ", parsedTransaction.name, JSON.stringify(parsedTransaction.args, null, 2));
      } else {
        console.log("tx:", tx);
      }
    } catch (e) {
      console.log("zkSync transaction is not parsed");
    }

    const transaction = await provider.getTransaction(hash);
    const receipt = await provider.getTransactionReceipt(hash);
    console.log("receipt:", receipt);
    console.log("\n \n ");

    if (receipt.gasUsed) {
      const gasLimit = transaction.gasLimit;
      const gasUsed = receipt.gasUsed;
      console.log("Gas limit: ", transaction.gasLimit.toString());
      console.log("Gas used: ", receipt.gasUsed.toString());

      // If more than 90% of gas was used, report it as an error.
      const threshold = gasLimit.mul(90).div(100);
      if (gasUsed.gte(threshold)) {
        const error = chalk.bold.red;
        console.log(error("More than 90% of gas limit was used!"));
        console.log(error("It may be the reason of the transaction failure"));
      }
    }

    if (receipt.status) {
      console.log("tx success");
    } else {
      const code = await provider.call(tx, tx.blockNumber);
      const reason = hex_to_ascii(code.substr(138));
      console.log("revert reason:", reason);
      console.log("revert code", code);
    }

    for (const log of receipt.logs) {
      console.log(log);
      try {
        const parsedLog = interfaces
          .map((contractInterface) => contractInterface.parseLog(log))
          .find((log) => log != null);

        if (parsedLog) {
          console.log(parsedLog);
        } else {
          console.log(log);
        }
      } catch {
        // ignore
      }
    }
  }
}

reason()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
