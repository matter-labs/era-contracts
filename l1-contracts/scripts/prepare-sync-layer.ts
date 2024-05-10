// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER, web3Url } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { initialBridgehubDeployment } from "../src.ts/deploy-process";
import { ethTestConfig, getAddressFromEnv, getNumberFromEnv } from "../src.ts/utils";

import { Wallet as ZkWallet, Provider as ZkProvider } from 'zksync-ethers';

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy").description("deploy L1 contracts");

  program
    .command('deploy-sync-layer-contracts')
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      if(process.env.CONTRACTS_BASE_NETWORK_ZKSYNC !== "true") {
        throw new Error("This script is only for zkSync network");
      }

      let deployWallet: ethers.Wallet | ZkWallet;
      
      // if (process.env.CONTRACTS_BASE_NETWORK_ZKSYNC === "true") {
        const provider = new ZkProvider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        deployWallet = cmd.privateKey
        ? new ZkWallet(cmd.privateKey, provider)
        : ZkWallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      // } else {
      //   deployWallet = cmd.privateKey
      //   ? new Wallet(cmd.privateKey, provider)
      //   : Wallet.fromMnemonic(
      //       process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
      //       "m/44'/60'/0'/0/1"
      //     ).connect(provider);
      // }

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

      if (deployer.isZkMode()) {
        console.log("Deploying on a zkSync network!");
      }

      await deployer.updateCreate2FactoryZkMode();
      await deployer.updateBlobVersionedHashRetrieverZkMode();

      await deployer.deployMulticall3(create2Salt, { gasPrice });
      await deployer.deployDefaultUpgrade(create2Salt, { gasPrice });
      await deployer.deployGenesisUpgrade(create2Salt, { gasPrice });

      await deployer.deployGovernance(create2Salt, { gasPrice });
      await deployer.deployVerifier(create2Salt, { gasPrice });

      await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });

      // SyncLayer does not need to have all the same contracts as on L1. 
      // We only need validator timelock as well as the STM.
      await deployer.deployValidatorTimelock(create2Salt, { gasPrice });

      // On L2 there is no bridgebub.
      deployer.addresses.Bridgehub.BridgehubProxy = ethers.constants.AddressZero;

      await deployer.deployStateTransitionDiamondFacets(create2Salt, gasPrice);
      await deployer.deployStateTransitionManagerImplementation(create2Salt, { gasPrice });
      await deployer.deployStateTransitionManagerProxy(create2Salt, { gasPrice });
    });

  program
    .command('register-sync-layer')
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      // Now, all the operations are done on L1
      const deployWallet = cmd.privateKey
      ? new Wallet(cmd.privateKey, provider)
      : Wallet.fromMnemonic(
          process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
          "m/44'/60'/0'/0/1"
        ).connect(provider);
      
      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      console.log(`Using owner address: ${ownerAddress}`);

      await registerSTMOnL1(new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      }));
  
    });

  await program.parseAsync(process.argv);
}

async function registerSTMOnL1(deployer: Deployer) {
  const stmOnSyncLayer = getAddressFromEnv('SYNC_LAYER_STATE_TRANSITION_PROXY_ADDR');
  const chainId = getNumberFromEnv('CHAIN_ETH_ZKSYNC_NETWORK_ID');

  console.log(`STM on SyncLayer: ${stmOnSyncLayer}`);
  console.log(`SyncLayer chain Id: ${chainId}`);

  const l1STM = deployer.stateTransitionManagerContract(deployer.deployWallet);
  console.log(deployer.addresses.StateTransition.StateTransitionProxy);
  // this script only works when owner is the deployer
  console.log(`Registering SyncLayer chain id on the STM`);
  await performViaGovernane(
    deployer,
    {
      to: l1STM.address,
      data: l1STM.interface.encodeFunctionData(
        'registerSyncLayer',
        [chainId, true]
      )
    }
  )
  
  console.log(`Registering STM counter part on the SyncLayer`);
  await performViaGovernane(
    deployer,
    {
      to: l1STM.address,
      data: l1STM.interface.encodeFunctionData(
        'registerCounterpart',
        [chainId, stmOnSyncLayer]
      )
    }
  );
  console.log(`SyncLayer registration completed`);

}

async function performViaGovernane(deployer: Deployer, params: {
  to: string,
  data: string,
}) {
  const governance = deployer.governanceContract(deployer.deployWallet);
  const operation = {
    calls: [
      {
        target: params.to,
        data: params.data,
        value: 0,
      }
    ],
    predecessor: ethers.constants.HashZero,
    salt: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
  };
  await (await governance.scheduleTransparent(operation, 0)).wait();
    
  await (
    await governance.execute(operation)
  ).wait();
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
