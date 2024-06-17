// hardhat import should be the first import in the file
import * as hardhat from "hardhat";

const EXPECTED_ADDRESS = "0xc706EC7dfA5D4Dc87f29f859094165E8290530f5";

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
    console.log("Skip contract verification on localhost");
    return;
  }

  const message = await verifyPromise(EXPECTED_ADDRESS);
  console.log(message.status == "fulfilled" ? message.value : message.reason);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
