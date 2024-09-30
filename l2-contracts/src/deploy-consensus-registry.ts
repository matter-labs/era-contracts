import { Command } from "commander";
import { ethers } from "ethers";
import { computeL2Create2Address, create2DeployFromL2 } from "./utils";
import { Interface } from "ethers/lib/utils";
import { ethTestConfig } from "./deploy-utils";

import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-ethers";

const I_TRANSPARENT_UPGRADEABLE_PROXY_ARTIFACT = hre.artifacts.readArtifactSync("ITransparentUpgradeableProxy");
const TRANSPARENT_UPGRADEABLE_PROXY_ARTIFACT = hre.artifacts.readArtifactSync("TransparentUpgradeableProxy");
const CONSENSUS_REGISTRY_ARTIFACT = hre.artifacts.readArtifactSync("ConsensusRegistry");
const PROXY_ADMIN_ARTIFACT = hre.artifacts.readArtifactSync("ConsensusRegistry");

const CONSENSUS_REGISTRY_INTERFACE = new Interface(CONSENSUS_REGISTRY_ARTIFACT.abi);
const I_TRANSPARENT_UPGRADEABLE_PROXY_INTERFACE = new Interface(I_TRANSPARENT_UPGRADEABLE_PROXY_ARTIFACT.abi);

// Script to deploy the consensus registry contract and output its address.
// Note, that this script expects that the L2 contracts have been compiled PRIOR
// to running this script.
async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("deploy-consensus-registry")
    .description("Deploys the consensus registry contract to L2");

  program.option("--private-key <private-key>").action(async (cmd) => {
    const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
    const deployWallet = cmd.privateKey
      ? new Wallet(cmd.privateKey, zksProvider)
      : Wallet.fromMnemonic(
          process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
          "m/44'/60'/0'/0/1"
        ).connect(zksProvider);
    console.log(`Using deployer wallet: ${deployWallet.address}`);

    // Deploy Consensus Registry contract
    const consensusRegistryImplementation = await computeL2Create2Address(
      deployWallet,
      CONSENSUS_REGISTRY_ARTIFACT.bytecode,
      "0x",
      ethers.constants.HashZero
    );
    await create2DeployFromL2(deployWallet, CONSENSUS_REGISTRY_ARTIFACT.bytecode, "0x", ethers.constants.HashZero);

    // Deploy Proxy Admin contract
    const proxyAdminContract = await computeL2Create2Address(
      deployWallet,
      PROXY_ADMIN_ARTIFACT.bytecode,
      "0x",
      ethers.constants.HashZero
    );
    await create2DeployFromL2(deployWallet, PROXY_ADMIN_ARTIFACT.bytecode, "0x", ethers.constants.HashZero);

    const proxyInitializationParams = CONSENSUS_REGISTRY_INTERFACE.encodeFunctionData("initialize", [
      deployWallet.address,
    ]);
    const proxyConstructor = I_TRANSPARENT_UPGRADEABLE_PROXY_INTERFACE.encodeDeploy([
      consensusRegistryImplementation,
      proxyAdminContract,
      proxyInitializationParams,
    ]);

    await create2DeployFromL2(
      deployWallet,
      TRANSPARENT_UPGRADEABLE_PROXY_ARTIFACT.bytecode,
      proxyConstructor,
      ethers.constants.HashZero
    );

    const address = computeL2Create2Address(
      deployWallet,
      TRANSPARENT_UPGRADEABLE_PROXY_ARTIFACT.bytecode,
      proxyConstructor,
      ethers.constants.HashZero
    );
    console.log(`CONTRACTS_L2_CONSENSUS_REGISTRY_ADDR=${address}`);
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
