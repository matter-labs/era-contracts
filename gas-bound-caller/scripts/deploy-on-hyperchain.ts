// hardhat import should be the first import in the file
import { ethers } from "ethers";
import { Command } from "commander";
import { PREDEPLOYED_CREATE2_ADDRESS, getCreate2DeploymentInfo } from "./utils";
import { Wallet, Provider, Contract } from "zksync-ethers";

const singletonFactoryAbi = [
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "",
        type: "bytes32",
      },
      {
        internalType: "bytes32",
        name: "",
        type: "bytes32",
      },
      {
        internalType: "bytes",
        name: "",
        type: "bytes",
      },
    ],
    name: "create2",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "payable",
    type: "function",
  },
];

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("Deploy on hyperchain")
    .description("Deploys the GasBoundCaller on a predetermined Hyperchain network")
    .option("--private-key <private-key>")
    .option("--l2-rpc <l2Rpc>")
    .action(async (cmd) => {
      console.log("Reading the canonical bytecode of the GasBoundCaller");

      const { bytecode, bytecodeHash, expectedAddress } = getCreate2DeploymentInfo();

      const wallet = new Wallet(cmd.privateKey, new Provider(cmd.l2Rpc));

      const singleTonFactory = new Contract(PREDEPLOYED_CREATE2_ADDRESS, singletonFactoryAbi, wallet);

      console.log("Expected address:", expectedAddress);

      const currentCode = await wallet.provider.getCode(expectedAddress);
      if (currentCode !== "0x") {
        if (currentCode === bytecode) {
          console.log("The GasBoundCaller is already deployed on the expected address");
          return;
        }
        throw new Error("The expected address is already occupied by a contract with different bytecode");
      }

      console.log("Sending transaction to deploy the GasBoundCaller");
      const tx = await singleTonFactory.create2(ethers.constants.HashZero, bytecodeHash, "0x", {
        customData: {
          factoryDeps: [bytecode],
        },
      });

      console.log("Transaction hash:", tx.hash);
      await tx.wait();

      const codeAfterDeploy = await wallet.provider.getCode(expectedAddress);
      if (codeAfterDeploy.toLowerCase() !== bytecode.toLowerCase()) {
        throw new Error("Deployment failed. The bytecode on the expected address is not the same as the bytecode.");
      }

      console.log("Transaction complete!");
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
