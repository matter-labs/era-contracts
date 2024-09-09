import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ethers } from "ethers";
import { SingletonFactoryFactory } from "../typechain";

import { encodeNTVAssetId, getAddressFromEnv, getNumberFromEnv } from "./utils";

export async function deployViaCreate2(
  deployWallet: ethers.Wallet,
  contractName: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[],
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  create2FactoryAddress: string,
  verbose: boolean = true,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  libraries?: any,
  bytecode?: ethers.utils.BytesLike
): Promise<[string, string]> {
  // [address, txHash]

  if (!bytecode) {
    const contractFactory = await hardhat.ethers.getContractFactory(contractName, {
      signer: deployWallet,
      libraries,
    });
    bytecode = contractFactory.getDeployTransaction(...args, ethTxOptions).data;
  }

  return await deployBytecodeViaCreate2(
    deployWallet,
    contractName,
    bytecode,
    create2Salt,
    ethTxOptions,
    create2FactoryAddress,
    verbose
  );
}

export async function deployBytecodeViaCreate2(
  deployWallet: ethers.Wallet,
  contractName: string,
  bytecode: ethers.BytesLike,
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  create2FactoryAddress: string,
  verbose: boolean = true
): Promise<[string, string]> {
  // [address, txHash]

  const log = (msg: string) => {
    if (verbose) {
      console.log(msg);
    }
  };
  log(`Deploying ${contractName}`);

  const create2Factory = SingletonFactoryFactory.connect(create2FactoryAddress, deployWallet);
  const expectedAddress = ethers.utils.getCreate2Address(
    create2Factory.address,
    create2Salt,
    ethers.utils.keccak256(bytecode)
  );

  const deployedBytecodeBefore = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeBefore) > 0) {
    log(`Contract ${contractName} already deployed`);
    return [expectedAddress, ethers.constants.HashZero];
  }

  const tx = await create2Factory.deploy(bytecode, create2Salt, ethTxOptions);
  const receipt = await tx.wait();

  const gasUsed = receipt.gasUsed;
  log(
    `${contractName} deployed, gasUsed: ${gasUsed.toString()}, tx hash: ${tx.hash}, expected address: ${expectedAddress}`
  );

  const deployedBytecodeAfter = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error(`Failed to deploy ${contractName} bytecode via create2 factory`);
  }

  return [expectedAddress, tx.hash];
}

export async function deployContractWithArgs(
  wallet: ethers.Wallet,
  contractName: string,
  // eslint-disable-next-line
  args: any[],
  ethTxOptions: ethers.providers.TransactionRequest
) {
  const factory = await hardhat.ethers.getContractFactory(contractName, wallet);

  return await factory.deploy(...args, ethTxOptions);
}

export interface DeployedAddresses {
  Bridgehub: {
    BridgehubProxy: string;
    BridgehubImplementation: string;
    CTMDeploymentTrackerImplementation: string;
    CTMDeploymentTrackerProxy: string;
    MessageRootImplementation: string;
    MessageRootProxy: string;
  };
  StateTransition: {
    StateTransitionProxy: string;
    StateTransitionImplementation: string;
    Verifier: string;
    AdminFacet: string;
    MailboxFacet: string;
    ExecutorFacet: string;
    GettersFacet: string;
    DiamondInit: string;
    GenesisUpgrade: string;
    DiamondUpgradeInit: string;
    DefaultUpgrade: string;
    DiamondProxy: string;
  };
  Bridges: {
    ERC20BridgeImplementation: string;
    ERC20BridgeProxy: string;
    SharedBridgeImplementation: string;
    SharedBridgeProxy: string;
    L2SharedBridgeProxy: string;
    L2SharedBridgeImplementation: string;
    L2NativeTokenVaultImplementation: string;
    L2NativeTokenVaultProxy: string;
    NativeTokenVaultImplementation: string;
    NativeTokenVaultProxy: string;
  };
  TransactionFilterer: {
    TxFiltererImplementation: string;
    TxFiltererProxy: string;
  };
  BaseTokenAssetId: string;
  BaseToken: string;
  TransparentProxyAdmin: string;
  L2ProxyAdmin: string;
  Governance: string;
  ChainAdmin: string;
  BlobVersionedHashRetriever: string;
  ValidatorTimeLock: string;
  RollupL1DAValidator: string;
  ValidiumL1DAValidator: string;
  RelayedSLDAValidator: string;
  Create2Factory: string;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
  let baseTokenAssetId = "0";
  try {
    baseTokenAssetId = getAddressFromEnv("CONTRACTS_BASE_TOKEN_ASSET_ID");
  } catch (error) {
    baseTokenAssetId = encodeNTVAssetId(
      parseInt(getNumberFromEnv("ETH_CLIENT_CHAIN_ID")),
      ethers.utils.hexZeroPad(getAddressFromEnv("CONTRACTS_BASE_TOKEN_ADDR"), 32)
    );
  }
  return {
    Bridgehub: {
      BridgehubProxy: getAddressFromEnv("CONTRACTS_BRIDGEHUB_PROXY_ADDR"),
      BridgehubImplementation: getAddressFromEnv("CONTRACTS_BRIDGEHUB_IMPL_ADDR"),
      CTMDeploymentTrackerImplementation: getAddressFromEnv("CONTRACTS_CTM_DEPLOYMENT_TRACKER_IMPL_ADDR"),
      CTMDeploymentTrackerProxy: getAddressFromEnv("CONTRACTS_CTM_DEPLOYMENT_TRACKER_PROXY_ADDR"),
      MessageRootImplementation: getAddressFromEnv("CONTRACTS_MESSAGE_ROOT_IMPL_ADDR"),
      MessageRootProxy: getAddressFromEnv("CONTRACTS_MESSAGE_ROOT_PROXY_ADDR"),
    },
    StateTransition: {
      StateTransitionProxy: getAddressFromEnv("CONTRACTS_STATE_TRANSITION_PROXY_ADDR"),
      StateTransitionImplementation: getAddressFromEnv("CONTRACTS_STATE_TRANSITION_IMPL_ADDR"),
      Verifier: getAddressFromEnv("CONTRACTS_VERIFIER_ADDR"),
      AdminFacet: getAddressFromEnv("CONTRACTS_ADMIN_FACET_ADDR"),
      MailboxFacet: getAddressFromEnv("CONTRACTS_MAILBOX_FACET_ADDR"),
      ExecutorFacet: getAddressFromEnv("CONTRACTS_EXECUTOR_FACET_ADDR"),
      GettersFacet: getAddressFromEnv("CONTRACTS_GETTERS_FACET_ADDR"),
      DiamondInit: getAddressFromEnv("CONTRACTS_DIAMOND_INIT_ADDR"),
      GenesisUpgrade: getAddressFromEnv("CONTRACTS_GENESIS_UPGRADE_ADDR"),
      DiamondUpgradeInit: getAddressFromEnv("CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR"),
      DefaultUpgrade: getAddressFromEnv("CONTRACTS_DEFAULT_UPGRADE_ADDR"),
      DiamondProxy: getAddressFromEnv("CONTRACTS_DIAMOND_PROXY_ADDR"),
    },
    Bridges: {
      ERC20BridgeImplementation: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR"),
      ERC20BridgeProxy: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR"),
      SharedBridgeImplementation: getAddressFromEnv("CONTRACTS_L1_SHARED_BRIDGE_IMPL_ADDR"),
      SharedBridgeProxy: getAddressFromEnv("CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR"),
      L2NativeTokenVaultImplementation: getAddressFromEnv("CONTRACTS_L2_NATIVE_TOKEN_VAULT_IMPL_ADDR"),
      L2NativeTokenVaultProxy: getAddressFromEnv("CONTRACTS_L2_NATIVE_TOKEN_VAULT_PROXY_ADDR"),
      L2SharedBridgeImplementation: getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR"),
      L2SharedBridgeProxy: getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR"),
      NativeTokenVaultImplementation: getAddressFromEnv("CONTRACTS_L1_NATIVE_TOKEN_VAULT_IMPL_ADDR"),
      NativeTokenVaultProxy: getAddressFromEnv("CONTRACTS_L1_NATIVE_TOKEN_VAULT_PROXY_ADDR"),
    },
    TransactionFilterer: {
      TxFiltererImplementation: getAddressFromEnv("CONTRACTS_TX_FILTERER_IMPL_ADDR"),
      TxFiltererProxy: getAddressFromEnv("CONTRACTS_TX_FILTERER_PROXY_ADDR"),
    },
    RollupL1DAValidator: getAddressFromEnv("CONTRACTS_L1_ROLLUP_DA_VALIDATOR"),
    ValidiumL1DAValidator: getAddressFromEnv("CONTRACTS_L1_VALIDIUM_DA_VALIDATOR"),
    RelayedSLDAValidator: getAddressFromEnv("CONTRACTS_L1_RELAYED_SL_DA_VALIDATOR"),
    BaseToken: getAddressFromEnv("CONTRACTS_BASE_TOKEN_ADDR"),
    BaseTokenAssetId: baseTokenAssetId,
    TransparentProxyAdmin: getAddressFromEnv("CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR"),
    L2ProxyAdmin: getAddressFromEnv("CONTRACTS_L2_PROXY_ADMIN_ADDR"),
    Create2Factory: getAddressFromEnv("CONTRACTS_CREATE2_FACTORY_ADDR"),
    BlobVersionedHashRetriever: getAddressFromEnv("CONTRACTS_BLOB_VERSIONED_HASH_RETRIEVER_ADDR"),
    ValidatorTimeLock: getAddressFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_ADDR"),
    Governance: getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR"),
    ChainAdmin: getAddressFromEnv("CONTRACTS_CHAIN_ADMIN_ADDR"),
  };
}
