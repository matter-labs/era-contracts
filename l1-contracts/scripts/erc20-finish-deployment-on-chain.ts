import { Command } from "commander";
import { Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import * as zksync from "zksync-ethers";
import { Deployer } from "../src.ts/deploy";
import { GAS_MULTIPLIER, web3Provider } from "./utils";

import * as fs from "fs";
import * as path from "path";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function main() {
  const program = new Command();

  program.version("0.1.0").name("initialize-erc20-bridge-chain");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--erc20-bridge <erc20-bridge>")
    .action(async (cmd) => {
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const l2NodeUrl = process.env.API_WEB3_JSON_RPC_HTTP_URL!;
      const l2Provider = new zksync.Provider(
        {
          url: l2NodeUrl,
          timeout: 1200 * 1000,
        },
        undefined
      );

      const syncWallet = cmd.privateKey
        ? new zksync.Wallet(cmd.privateKey, l2Provider, provider)
        : zksync.Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/0"
          ).connect(l2Provider);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const deployer = new Deployer({
        deployWallet,
        ownerAddress: deployWallet.address,
        verbose: true,
      });

      const erc20Bridge = cmd.erc20Bridge
        ? deployer.defaultERC20Bridge(deployWallet).attach(cmd.erc20Bridge)
        : deployer.defaultERC20Bridge(deployWallet);

      const implDeployTxHash = await erc20Bridge.bridgeImplDeployOnL2TxHash(chainId);
      const proxyDeployTxHash = await erc20Bridge.bridgeProxyDeployOnL2TxHash(chainId);

      const {
        l1BatchNumber: implL1BatchNumber,
        l2MessageIndex: implL2MessageIndex,
        l2TxNumberInBlock: implL2TxNumberInBlock,
        proof: implProof,
      } = await syncWallet.getPriorityOpConfirmation(implDeployTxHash);

      const {
        l1BatchNumber: proxyL1BatchNumber,
        l2MessageIndex: proxyL2MessageIndex,
        l2TxNumberInBlock: proxyL2TxNumberInBlock,
        proof: proxyProof,
      } = await syncWallet.getPriorityOpConfirmation(proxyDeployTxHash);
      //   _getWithdrawalLog(withdrawalHash, index);

      const tx = await erc20Bridge.finishInitializeChain(
        chainId,
        {
          batchNumber: implL1BatchNumber,
          messageIndex: implL2MessageIndex,
          numberInBatch: implL2TxNumberInBlock,
          merkleProof: implProof,
          succeeded: true,
        },
        {
          batchNumber: proxyL1BatchNumber,
          messageIndex: proxyL2MessageIndex,
          numberInBatch: proxyL2TxNumberInBlock,
          merkleProof: proxyProof,
          succeeded: true,
        }
      );

      console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);

      const receipts = await tx.wait(2);

      console.log(`ERC20 bridge priority tx sent to hyperchain, gasUsed: ${receipts.gasUsed.toString()}`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
