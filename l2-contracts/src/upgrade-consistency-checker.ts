/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { ethers } from "ethers";
import { Provider } from "zksync-ethers";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const l2BridgeImplAddr = "0x470afaacce2acdaefcc662419b74c79d76c914ae";

const eraChainId = 324;

const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);

async function checkIdenticalBytecode(addr: string, contract: string) {
  const correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  const currentCode = await l2Provider.getCode(addr);

  if (ethers.utils.keccak256(currentCode) == ethers.utils.keccak256(correctCode)) {
    console.log(contract, "bytecode is correct");
  } else {
    throw new Error(contract + " bytecode is not correct");
  }
}

async function checkL2SharedBridgeImpl() {
  await checkIdenticalBytecode(l2BridgeImplAddr, "L2SharedBridge");

  // In Era we can retrieve the immutable from the simulator
  const contract = new ethers.Contract(
    "0x0000000000000000000000000000000000008005",
    immutableSimulatorAbi(),
    l2Provider
  );

  const usedEraChainId = ethers.BigNumber.from(await contract.getImmutable(l2BridgeImplAddr, 0));
  if (!usedEraChainId.eq(ethers.BigNumber.from(eraChainId))) {
    throw new Error("Era chain id is not correct");
  }
  console.log("L2SharedBridge is correct!");
}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("upgrade-consistency-checker")
    .description("upgrade shared bridge for era diamond proxy");

  program.action(async () => {
    await checkL2SharedBridgeImpl();
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

function immutableSimulatorAbi() {
  return [
    {
      inputs: [
        {
          internalType: "address",
          name: "_dest",
          type: "address",
        },
        {
          internalType: "uint256",
          name: "_index",
          type: "uint256",
        },
      ],
      name: "getImmutable",
      outputs: [
        {
          internalType: "bytes32",
          name: "",
          type: "bytes32",
        },
      ],
      stateMutability: "view",
      type: "function",
    },
    {
      inputs: [
        {
          internalType: "address",
          name: "_dest",
          type: "address",
        },
        {
          components: [
            {
              internalType: "uint256",
              name: "index",
              type: "uint256",
            },
            {
              internalType: "bytes32",
              name: "value",
              type: "bytes32",
            },
          ],
          internalType: "struct ImmutableData[]",
          name: "_immutables",
          type: "tuple[]",
        },
      ],
      name: "setImmutables",
      outputs: [],
      stateMutability: "nonpayable",
      type: "function",
    },
  ];
}
