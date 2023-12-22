/// Temporary script that generated the needed calldata for the migration of the governance.

import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { applyL1ToL2Alias, getAddressFromEnv } from "./utils";
import * as fs from "fs";

import { UpgradeableBeaconFactory } from "../../zksync/typechain/UpgradeableBeaconFactory";
import { Provider } from "zksync-web3";

const L2ERC20BridgeABI = JSON.parse(
  fs
    .readFileSync(
      "../zksync/artifacts-zk/cache-zk/solpp-generated-contracts/bridge/L2ERC20Bridge.sol/L2ERC20Bridge.json"
    )
    .toString()
).abi;

async function getERC20BeaconAddress(l2Erc20BridgeAddress: string) {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const contract = new ethers.Contract(l2Erc20BridgeAddress, L2ERC20BridgeABI, provider);
  return await contract.l2TokenBeacon();
}

async function proxyGov(addr: string, prov: ethers.providers.Provider) {
  const adminSlot = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
  return `0x${(await prov.getStorageAt(addr, adminSlot)).substring(26)}`;
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("migrate-governance");

  program.action(async () => {
    // This action is very dangerous, and so we double check that the governance in env is the same
    // one as the user provided manually.
    const governanceAddressFromEnv = getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR").toLowerCase();
    const aliasedNewGovernor = applyL1ToL2Alias(governanceAddressFromEnv);

    console.log(`Using governance address from env: ${governanceAddressFromEnv}`);
    console.log(`Aliased governance address from env: ${aliasedNewGovernor}`);

    // We won't be making any transactions with this wallet, we just need
    // it to initialize the Deployer object.
    const deployWallet = Wallet.createRandom().connect(
      new ethers.providers.JsonRpcProvider(process.env.ETH_CLIENT_WEB3_URL)
    );
    const deployer = new Deployer({
      deployWallet,
      verbose: true,
    });

    // Firstly, we deploy the info about the L1 contracts

    const zkSync = deployer.zkSyncContract(deployWallet);

    console.log("zkSync governor: ", await zkSync.getGovernor());
    console.log("zkSync pendingGovernor: ", await zkSync.getPendingGovernor());

    const validatorTimelock = deployer.validatorTimelock(deployWallet);
    console.log("validatorTimelock governor: ", await validatorTimelock.owner());
    console.log("validatorTimelock pendingGovernor: ", await validatorTimelock.pendingOwner());

    const l1Erc20Bridge = deployer.transparentUpgradableProxyContract(
      deployer.addresses.Bridges.ERC20BridgeProxy,
      deployWallet
    );

    console.log("l1Erc20Bridge governor: ", await proxyGov(l1Erc20Bridge.address, deployWallet.provider));

    // Now, starting to deploy the info about the L2 contracts

    const deployWallet2 = Wallet.createRandom().connect(
      new ethers.providers.JsonRpcProvider(process.env.API_WEB3_JSON_RPC_HTTP_URL)
    );

    const l2ERC20Bridge = deployer.transparentUpgradableProxyContract(
      process.env.CONTRACTS_L2_ERC20_BRIDGE_ADDR!,
      deployWallet2
    );
    console.log("l2ERC20Bridge governor: ", await proxyGov(l2ERC20Bridge.address, deployWallet2.provider));

    const l2wethToken = deployer.transparentUpgradableProxyContract(
      process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR!,
      deployWallet2
    );
    console.log("l2wethToken governor: ", await proxyGov(l2wethToken.address, deployWallet2.provider));

    // L2 Tokens are BeaconProxies
    const l2Erc20BeaconAddress: string = await getERC20BeaconAddress(l2ERC20Bridge.address);
    const l2Erc20TokenBeacon = UpgradeableBeaconFactory.connect(l2Erc20BeaconAddress, deployWallet2);

    console.log("l2Erc20TokenBeacon governor: ", await l2Erc20TokenBeacon.owner());
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
