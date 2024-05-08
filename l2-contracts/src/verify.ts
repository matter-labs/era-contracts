// hardhat import should be the first import in the file
import * as hardhat from "hardhat";

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

  const promises = [];

  // Contracts without constructor parameters
  for (const address of [
    process.env.CONTRACTS_L2_WETH_TOKEN_IMPL_ADDR,
    process.env.CONTRACTS_L2_ERC20_BRIDGE_TOKEN_IMPL_ADDR,
  ]) {
    const promise = verifyPromise(address);
    promises.push(promise);
  }

  promises.push(verifyPromise(process.env.CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR, [process.env.CONTRACTS_ERA_CHAIN_ID]));

  const messages = await Promise.allSettled(promises);
  for (const message of messages) {
    console.log(message.status == "fulfilled" ? message.value : message.reason);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
