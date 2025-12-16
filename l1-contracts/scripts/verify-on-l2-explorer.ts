// hardhat import should be the first import in the file

import { Command } from "commander";
import { spawn } from "./utils";

const VERIFICATION_URL = process.env.VERIFICATION_URL!;
const CHAIN = "zksync";

interface ContractDescription {
  address: string;
  codeName: string;
  path: string;
}

// List of L2 contracts to verify
const L2_CONTRACTS: { [key: string]: ContractDescription } = {
  L2AssetRouter: {
    address: "0x0000000000000000000000000000000000010003",
    codeName: "L2AssetRouter",
    path: "contracts/bridge/asset-router/L2AssetRouter.sol",
  },
  L2NativeTokenVault: {
    address: "0x0000000000000000000000000000000000010004",
    codeName: "L2NativeTokenVault",
    path: "contracts/bridge/ntv/L2NativeTokenVault.sol",
  },
  MessageRoot: {
    address: "0x0000000000000000000000000000000000010005",
    codeName: "L2MessageRoot",
    path: "contracts/core/message-root/L2MessageRoot.sol",
  },
  BridgeHub: {
    address: "0x0000000000000000000000000000000000010002",
    codeName: "L2Bridgehub",
    path: "contracts/core/bridgehub/L2Bridgehub.sol",
  },
  BridgedStandardERC20: {
    address: "0x05b00ef3489E21E57b3e93a72bc9F59c57bB199b",
    codeName: "BridgedStandardERC20",
    path: "contracts/bridge/BridgedStandardERC20.sol",
  },
  L2WrappedBaseToken: {
    address: "0x0000000000000000000000000000000000010007",
    codeName: "L2WrappedBaseToken",
    path: "contracts/bridge/L2WrappedBaseToken.sol",
  },
};

async function verifyContract(contractInfo: ContractDescription) {
  const codeNameWithPath = `${contractInfo.path}:${contractInfo.codeName}`;
  console.log(`Verifying ${contractInfo.codeName} on ${contractInfo.address} address..`);
  // It's safe to pass '0x' for constructor args here because all contracts in L2_CONTRACTS are either deployed without constructor arguments or have default constructors. If a contract had required constructor arguments, verification would fail and should be handled explicitly.
  await spawn(
    `forge verify-contract --zksync --chain ${CHAIN} --watch --verifier zksync --verifier-url ${VERIFICATION_URL} --constructor-args 0x ${contractInfo.address} ${codeNameWithPath}`
  );
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("verify l2 contracts").description("Verify L2 contracts source code on block explorer");

  for (const contractName in L2_CONTRACTS) {
    const contractInfo = L2_CONTRACTS[contractName];
    await verifyContract(contractInfo);
  }

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
