// hardhat import should be the first import in the file
import * as hre from "hardhat";
import { Command } from "commander";
import { ethers } from "ethers";
import { L2SharedBridgeFactory, ProxyAdminFactory, UpgradeableBeaconFactory } from "../typechain";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Provider, Wallet } from "zksync-ethers";
import { unapplyL1ToL2Alias } from "./utils";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import { IBridgehubFactory } from "../../l1-contracts/typechain/IBridgehubFactory";

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("deploy L2SharedBridge, L2StandardToken, and L2WrappedBaseToken")
    .requiredOption("--private-key <privateKey>")
    .requiredOption("--l1-rpc <l1Rpc>")
    .requiredOption("--l2-rpc <l2Rpc>")
    .requiredOption("--chain-id <chainId>")
    .requiredOption("--l2-shared-bridge-proxy-address <l2SharedBridgeProxyAddress>")
    .requiredOption("--l2-weth-proxy-address <l2WethProxyAddress")
    .requiredOption("--bridgehub-address <bridgehubAddress>")
    .requireOption("--proxy-admin-address <proxyAdminAddress>")
    .option("--gas-price <gasPrice>")
    .option("--l2-gas-limit <l2GasLimit>")
    .option("--l2-gas-per-pubdata-byte-limit <l2GasPerPubdataByteLimit>")
    .action(async (cmd: any) => {
      const chainId = cmd.chainId;

      const l2Provider = new Provider(cmd.l2Rpc);
      const l1Provider = new Provider(cmd.l21pc);
      const deployWallet = new Wallet(cmd.privateKey, l2Provider, l1Provider);
      const deployer = new Deployer(hre, deployWallet);

      console.log(`Using deployer wallet: ${deployWallet.address}`);

      console.log("DEPLOYING CONTRACTS");

      const sharedBridgeArtifact = await deployer.loadArtifact("L2SharedBridge");
      const l2SharedBridge = await deployer.deploy(sharedBridgeArtifact, [chainId]);

      console.log(`L2SharedBridge Address: ${l2SharedBridge.address}`);

      const standardERC20Artifact = await deployer.loadArtifact("L2StandardERC20");
      const standardERC20 = await deployer.deploy(standardERC20Artifact, []);

      console.log(`L2StandardERC20 Address: ${standardERC20.address}`);

      const wrappedBaseTokenArtifact = await deployer.loadArtifact("L2WrappedBaseToken");
      const wrappedBaseToken = await deployer.deploy(wrappedBaseTokenArtifact, []);

      console.log(`L2WrappedBaseToken Address: ${wrappedBaseToken.address}`);

      console.log("GENERATING L2 CALLDATA");
      const sharedBridgeUpgradeCalldata = ProxyAdminFactory.connect(ethers.constants.AddressZero, deployWallet).interface.encodeFunctionData("upgrade", [
        cmd.l2SharedBridgeProxyAddress,
        l2SharedBridge.address
      ]);
      console.log(`Upgrade L2SharedBridge Proxy Calldata ${sharedBridgeUpgradeCalldata}`);

      const wethUpgradeCalldata = ProxyAdminFactory.connect(ethers.constants.AddressZero, deployWallet).interface.encodeFunctionData("upgrade", [
        cmd.l2WethProxyAddress,
        wrappedBaseToken.address
      ]);
      console.log(`Upgrade L2WETH Proxy Calldata ${wethUpgradeCalldata}`);

      const upgradeStandardBaseTokenCalldata = UpgradeableBeaconFactory.connect(ethers.constants.AddressZero, deployWallet).interface.encodeFunctionData("upgradeTo", [
        standardERC20.address
      ]);
      console.log(`Upgrade L2StandardBaseToken Beacon Calldata ${upgradeStandardBaseTokenCalldata}`);

      console.log("GENERATING L1 CALLDATA");
      const l2SharedBridgeTokenBeacon = await L2SharedBridgeFactory
        .connect(cmd.l2SharedBridgeProxyAddress, l2Provider)
        .l2TokenBeacon();

      console.log(`L2TokenBeacon Address: ${l2SharedBridgeTokenBeacon}`);

      const l1GasPrice = cmd.gasPrice ?? (await l1Provider.getGasPrice()).mul(GAS_MULTIPLIER);
      const l2GasLimit = cmd.l2GasLimit ?? 1000000;
      const l2GasPerPubdataByteLimit = cmd.l2GasPerPubdataByteLimit ?? 800;

      const bridgehub = IBridgehubFactory.connect(cmd.bridgehubAddress, l1Provider);

      const expectedCost = await bridgehub.l2TransactionBaseCost(
        cmd.chainId,
        l1GasPrice,
        l2GasLimit,
        800
      );

      const upgradeL2SharedBridgeCalldata = bridgehub.interface.encodeFunctionData("requestL2TransactionDirect", [{
        chainId: cmd.chainId,
        l2Contract: cmd.proxyAdminAddress,
        mintValue: expectedCost,
        l2Value: 0,
        l2Calldata: sharedBridgeUpgradeCalldata,
        l2GasLimit: l2GasLimit,
        l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
        factoryDeps: [],
        refundRecipient: deployWallet.address
      }]);

      const upgradeL2WethToken = bridgehub.interface.encodeFunctionData("requestL2TransactionDirect", [{
        chainId: cmd.chainId,
        l2Contract: cmd.proxyAdminAddress,
        mintValue: expectedCost,
        l2Value: 0,
        l2Calldata: wethUpgradeCalldata,
        l2GasLimit: l2GasLimit,
        l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
        factoryDeps: [],
        refundRecipient: deployWallet.address
      }]);

      const upgradeL2BaseTokenBeacon = bridgehub.interface.encodeFunctionData("requestL2TransactionDirect", [{
        chainId: cmd.chainId,
        l2Contract: cmd.proxyAdminAddress,
        mintValue: expectedCost,
        l2Value: 0,
        l2Calldata: upgradeStandardBaseTokenCalldata,
        l2GasLimit: l2GasLimit,
        l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
        factoryDeps: [],
        refundRecipient: deployWallet.address
      }]);

      console.log(`Upgrade L2SharedBridge Implementation Calldata: ${upgradeL2SharedBridgeCalldata}`);
      console.log(`Upgrade L2WethToken Implementation Calldata: ${upgradeL2WethToken}`);
      console.log(`Upgrade L2StandardBaseToken Implementation Calldata: ${upgradeL2BaseTokenBeacon}`);

    });

  await program.parseAsync(process.argv);

}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });