/// This script is needed for testing the behavior of the shared bridge on Era chain.
/// Unlike other chains, Era also contains a legacy ERC20 bridge, which is also supported by the corresponding L2SharedBridge.
///
/// This script ensures that the LegacyBridge is set up correctly and that the L2SharedBridge references it correctly too.
/// IMPORTANT: this script should be only used for local testing.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits, Interface } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { ethTestConfig, getAddressFromEnv } from "../src.ts/utils";
import { hashL2Bytecode } from "../../l2-contracts/src/utils";
import { Provider } from "zksync-web3";
import beaconProxy = require("../../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json");

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-shared-bridge-era").description("upgrade shared bridge for era diamond proxy");

  program
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      console.log(`Using owner address: ${ownerAddress}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const create2Salt = cmd.create2Salt ? cmd.create2Salt : ethers.utils.hexlify(ethers.utils.randomBytes(32));

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      await deployer.deploySharedBridgeImplementation(create2Salt, { nonce });

      const proxyAdminInterface = new Interface(hardhat.artifacts.readArtifactSync("ProxyAdmin").abi);
      let calldata = proxyAdminInterface.encodeFunctionData("upgrade(address,address)", [
        deployer.addresses.Bridges.SharedBridgeProxy,
        deployer.addresses.Bridges.SharedBridgeImplementation,
      ]);

      await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, calldata);

      // deploy a dummy erc20 bridge to set the storage values
      await deployer.deployERC20BridgeImplementation(create2Salt, {}, true);

      // upgrade to dummy bridge
      calldata = proxyAdminInterface.encodeFunctionData("upgrade(address,address)", [
        deployer.addresses.Bridges.ERC20BridgeProxy,
        deployer.addresses.Bridges.ERC20BridgeImplementation,
      ]);

      await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, calldata);
      console.log("Upgraded ERC20Bridge to 'dummy' implementation");

      const dummyBridgeAbi = hardhat.artifacts.readArtifactSync("DummyL1ERC20Bridge").abi;
      const dummyBridge = new ethers.Contract(
        deployer.addresses.Bridges.ERC20BridgeProxy,
        dummyBridgeAbi,
        deployWallet
      );

      const l2SharedBridgeAddress = getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR");
      const l2TokenBytecodeHash = hashL2Bytecode(beaconProxy.bytecode);
      const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      // For the server to start up.
      console.log("Waiting for server to start up");
      await waitForServer(l2Provider);
      console.log("Server started up");

      // Wait a bit more after the server is ready to ensure that all of its components are ready.
      await sleep(2);

      const l2SharedBridge = new ethers.Contract(
        l2SharedBridgeAddress,
        ["function l2TokenBeacon() view returns (address)"],
        l2Provider
      );
      const l2TokenBeacon = await l2SharedBridge.l2TokenBeacon();

      console.log("Retrieved storage values for TestERC20Bridge:");
      console.log("l2SharedBridgeAddress:", l2SharedBridgeAddress);
      console.log("l2TokenBeacon:", l2TokenBeacon);
      console.log("l2TokenBytecodeHash:", ethers.utils.hexlify(l2TokenBytecodeHash));

      // set storage values
      const tx = await dummyBridge.setValues(l2SharedBridgeAddress, l2TokenBeacon, l2TokenBytecodeHash);
      await tx.wait();

      console.log("Set storage values for TestERC20Bridge");
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

async function waitForServer(provider: Provider) {
  let iter = 0;
  while (iter < 60) {
    try {
      await provider.getBlockNumber();
      return;
    } catch (_) {
      await sleep(2);
      iter += 1;
    }
  }
  throw new Error("Server didn't start up in time. Exiting.");
}

async function sleep(seconds: number) {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}
