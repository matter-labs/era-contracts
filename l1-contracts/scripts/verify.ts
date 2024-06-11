// hardhat import should be the first import in the file
import * as hardhat from "hardhat";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { ethTestConfig, getNumberFromEnv, getHashFromEnv, getAddressFromEnv } from "../src.ts/utils";

import { Interface } from "ethers/lib/utils";
import { Deployer } from "../src.ts/deploy";
import { Wallet } from "ethers";
import { packSemver, unpackStringSemVer, web3Provider } from "./utils";
import { getTokens } from "../src.ts/deploy-token";

const provider = web3Provider();

function verifyPromise(
  address: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  constructorArguments?: Array<any>,
  libraries?: object,
  contract?: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
): Promise<any> {
  return new Promise((resolve, reject) => {
    hardhat
      .run("verify:verify", {
        address,
        constructorArguments,
        libraries,
        contract,
      })
      .then(() => resolve(`Successfully verified ${address}`))
      .catch((e) => reject(`Failed to verify ${address}\nError: ${e.message}`));
  });
}

// Note: running all verifications in parallel might be too much for etherscan, comment out some of them if needed
async function main() {
  if (process.env.CHAIN_ETH_NETWORK == "localhost") {
    console.log("Skip contract verification on localhost");
    return;
  }
  if (!process.env.MISC_ETHERSCAN_API_KEY) {
    console.log("Skip contract verification given etherscan api key is missing");
    return;
  }
  const addresses = deployedAddressesFromEnv();
  const promises = [];

  const deployWalletAddress = "0x71d84c3404a6ae258E6471d4934B96a2033F9438";

  const deployWallet = Wallet.fromMnemonic(ethTestConfig.mnemonic, "m/44'/60'/0'/0/1").connect(provider);
  const deployer = new Deployer({
    deployWallet,
    addresses: deployedAddressesFromEnv(),
    ownerAddress: deployWalletAddress,
    verbose: true,
  });
  // TODO: Restore after switching to hardhat tasks (SMA-1711).
  // promises.push(verifyPromise(addresses.AllowList, [governor]));

  // Proxy
  // {
  //     Create dummy deployer to get constructor parameters for diamond proxy
  //     const deployer = new Deployer({
  //         deployWallet: ethers.Wallet.createRandom(),
  //         governorAddress: governor
  //     });

  //     const chainId = process.env.ETH_CLIENT_CHAIN_ID;
  //     const constructorArguments = [chainId, await deployer.initialProxyDiamondCut()];
  //     const promise = verifyPromise(addresses.ZkSync.DiamondProxy, constructorArguments);
  //     promises.push(promise);
  // }

  const promise1 = verifyPromise(addresses.StateTransition.GenesisUpgrade);
  promises.push(promise1);

  const executionDelay = getNumberFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY");
  const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
  const promise2 = verifyPromise(addresses.ValidatorTimeLock, [deployWalletAddress, executionDelay, eraChainId]);
  promises.push(promise2);

  const promise3 = verifyPromise(process.env.CONTRACTS_DEFAULT_UPGRADE_ADDR);
  promises.push(promise3);

  const promise4 = verifyPromise(process.env.CONTRACTS_HYPERCHAIN_UPGRADE_ADDR);
  promises.push(promise4);

  const promise5 = verifyPromise(addresses.TransparentProxyAdmin);
  promises.push(promise5);

  // bridgehub

  const promise6 = verifyPromise(addresses.Bridgehub.BridgehubImplementation);
  promises.push(promise6);

  const bridgehub = new Interface(hardhat.artifacts.readArtifactSync("Bridgehub").abi);
  const initCalldata1 = bridgehub.encodeFunctionData("initialize", [deployWalletAddress]);
  const promise7 = verifyPromise(addresses.Bridgehub.BridgehubProxy, [
    addresses.Bridgehub.BridgehubImplementation,
    addresses.TransparentProxyAdmin,
    initCalldata1,
  ]);
  promises.push(promise7);

  // stm

  // Contracts without constructor parameters
  for (const address of [
    addresses.StateTransition.GettersFacet,
    addresses.StateTransition.DiamondInit,
    addresses.StateTransition.AdminFacet,
    addresses.StateTransition.ExecutorFacet,
    addresses.StateTransition.Verifier,
  ]) {
    const promise = verifyPromise(address);
    promises.push(promise);
  }

  const promise = verifyPromise(addresses.StateTransition.MailboxFacet, [eraChainId]);
  promises.push(promise);

  const promise8 = verifyPromise(addresses.StateTransition.StateTransitionImplementation, [
    addresses.Bridgehub.BridgehubProxy,
    getNumberFromEnv("CONTRACTS_MAX_NUMBER_OF_HYPERCHAINS"),
  ]);
  promises.push(promise8);

  const stateTransitionManager = new Interface(hardhat.artifacts.readArtifactSync("StateTransitionManager").abi);
  const genesisBatchHash = getHashFromEnv("CONTRACTS_GENESIS_ROOT"); // TODO: confusing name
  const genesisRollupLeafIndex = getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
  const genesisBatchCommitment = getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT");
  const diamondCut = await deployer.initialZkSyncHyperchainDiamondCut([]);
  const protocolVersion = packSemver(...unpackStringSemVer(process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION));

  const initCalldata2 = stateTransitionManager.encodeFunctionData("initialize", [
    {
      owner: addresses.Governance,
      validatorTimelock: addresses.ValidatorTimeLock,
      chainCreationParams: {
        genesisUpgrade: addresses.StateTransition.GenesisUpgrade,
        genesisBatchHash,
        genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
        genesisBatchCommitment,
        diamondCut,
      },
      protocolVersion,
    },
  ]);

  const promise9 = verifyPromise(addresses.StateTransition.StateTransitionProxy, [
    addresses.StateTransition.StateTransitionImplementation,
    addresses.TransparentProxyAdmin,
    initCalldata2,
  ]);
  promises.push(promise9);

  // bridges
  const promise10 = verifyPromise(
    addresses.Bridges.ERC20BridgeImplementation,
    [addresses.Bridges.SharedBridgeProxy],
    undefined,
    "contracts/bridge/L1ERC20Bridge.sol:L1ERC20Bridge"
  );
  promises.push(promise10);

  const eraDiamondProxy = getAddressFromEnv("CONTRACTS_ERA_DIAMOND_PROXY_ADDR");
  const tokens = getTokens();
  const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;

  const promise12 = verifyPromise(addresses.Bridges.SharedBridgeImplementation, [
    l1WethToken,
    addresses.Bridgehub.BridgehubProxy,
    eraChainId,
    eraDiamondProxy,
  ]);
  promises.push(promise12);
  const initCalldata4 = new Interface(hardhat.artifacts.readArtifactSync("L1SharedBridge").abi).encodeFunctionData(
    "initialize",
    [deployWalletAddress]
  );
  const promise13 = verifyPromise(addresses.Bridges.SharedBridgeProxy, [
    addresses.Bridges.SharedBridgeImplementation,
    addresses.TransparentProxyAdmin,
    initCalldata4,
  ]);
  promises.push(promise13);

  const messages = await Promise.allSettled(promises);
  for (const message of messages) {
    console.log(message.status == "fulfilled" ? message.value : message.reason);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
