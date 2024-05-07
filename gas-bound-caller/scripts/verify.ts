// hardhat import should be the first import in the file
import * as hardhat from "hardhat";
import { getCreate2DeploymentInfo } from "./utils";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function verifyPromise(address: string, constructorArguments?: Array<any>, libraries?: object): Promise<any> {
  return new Promise((resolve, reject) => {
    hardhat
      .run("verify:verify", { address, constructorArguments, libraries })
      .then(() => resolve(`Successfully verified ${address}`))
      .catch((e) => reject(`Failed to verify ${address}\nError: ${e.message}`));
  });
}

async function main() {
  if (process.env.CHAIN_ETH_NETWORK == "localhost") {
    console.log("Contract verification not available on localhost");
    return;
  }

  const { expectedAddress } = getCreate2DeploymentInfo();

  const verificationMessage = await verifyPromise(expectedAddress);

  if (verificationMessage.status == "fulfilled") {
    console.log(verificationMessage.value);
  } else {
    console.log(verificationMessage.reason);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
