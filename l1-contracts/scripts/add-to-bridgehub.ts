import { Deployer } from "../src.ts/deploy";
import { web3Provider } from "./utils";
import { Wallet } from "ethers";
import * as fs from "fs";
import { testConfigPath } from "../src.ts/utils";

const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));

async function main() {
  const privateKey = "YOUR_PK";
  const provider = web3Provider();
  const deployer = new Deployer({
    addresses: addressConfig,
    deployWallet: new Wallet(privateKey, provider),
    verbose: true,
  });

  deployer.addresses.Governance = "GOVERNANCE_ADDRESS";

  await deployer.executeUpgrade("TARGET_ADDRESS", 0, "RAW_CALLDATA");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
