import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ethers } from "ethers";
import { Interface } from "ethers/lib/utils";
import { SingletonFactoryFactory } from "../typechain";

import {
  encodeNTVAssetId,
  getAddressFromEnv,
  getNumberFromEnv,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  ADDRESS_ONE,
} from "./utils";
import { IBridgehubFactory } from "../typechain/IBridgehubFactory";
import { IERC20Factory } from "../typechain/IERC20Factory";

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

export function hashL2Bytecode(bytecode: ethers.BytesLike): Uint8Array {
  // For getting the consistent length we first convert the bytecode to UInt8Array
  const bytecodeAsArray = ethers.utils.arrayify(bytecode);

  if (bytecodeAsArray.length % 32 != 0) {
    throw new Error("The bytecode length in bytes must be divisible by 32");
  }

  const hashStr = ethers.utils.sha256(bytecodeAsArray);
  const hash = ethers.utils.arrayify(hashStr);

  // Note that the length of the bytecode
  // should be provided in 32-byte words.
  const bytecodeLengthInWords = bytecodeAsArray.length / 32;
  if (bytecodeLengthInWords % 2 == 0) {
    throw new Error("Bytecode length in 32-byte words must be odd");
  }
  const bytecodeLength = ethers.utils.arrayify(bytecodeAsArray.length / 32);
  if (bytecodeLength.length > 2) {
    throw new Error("Bytecode length must be less than 2^16 bytes");
  }
  // The bytecode should always take the first 2 bytes of the bytecode hash,
  // so we pad it from the left in case the length is smaller than 2 bytes.
  const bytecodeLengthPadded = ethers.utils.zeroPad(bytecodeLength, 2);

  const codeHashVersion = new Uint8Array([1, 0]);
  hash.set(codeHashVersion, 0);
  hash.set(bytecodeLengthPadded, 2);

  return hash;
}

export async function create2DeployFromL1(
  chainId: ethers.BigNumberish,
  wallet: ethers.Wallet,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish,
  gasPrice?: ethers.BigNumberish,
  extraFactoryDeps?: ethers.BytesLike[],
  bridgehubAddress?: string,
  assetRouterAddress?: string
) {
  bridgehubAddress = bridgehubAddress ?? deployedAddressesFromEnv().Bridgehub.BridgehubProxy;
  const bridgehub = IBridgehubFactory.connect(bridgehubAddress, wallet);

  const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);
  gasPrice ??= await bridgehub.provider.getGasPrice();
  const expectedCost = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const baseTokenAddress = await bridgehub.baseToken(chainId);
  const baseTokenBridge = assetRouterAddress ?? deployedAddressesFromEnv().Bridges.SharedBridgeProxy;
  const ethIsBaseToken = ADDRESS_ONE == baseTokenAddress;

  if (!ethIsBaseToken) {
    const baseToken = IERC20Factory.connect(baseTokenAddress, wallet);
    const tx = await baseToken.approve(baseTokenBridge, expectedCost);
    await tx.wait();
  }
  const factoryDeps = extraFactoryDeps ? [bytecode, ...extraFactoryDeps] : [bytecode];

  return await bridgehub.requestL2TransactionDirect(
    {
      chainId,
      l2Contract: DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
      mintValue: expectedCost,
      l2Value: 0,
      l2Calldata: calldata,
      l2GasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: factoryDeps,
      refundRecipient: wallet.address,
    },
    { value: ethIsBaseToken ? expectedCost : 0, gasPrice }
  );
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
    L1NullifierImplementation: string;
    L1NullifierProxy: string;
    ERC20BridgeImplementation: string;
    ERC20BridgeProxy: string;
    SharedBridgeImplementation: string;
    SharedBridgeProxy: string;
    L2SharedBridgeProxy: string;
    L2SharedBridgeImplementation: string;
    L2LegacySharedBridgeProxy: string;
    L2LegacySharedBridgeImplementation: string;
    L2NativeTokenVaultImplementation: string;
    L2NativeTokenVaultProxy: string;
    NativeTokenVaultImplementation: string;
    NativeTokenVaultProxy: string;
    BridgedStandardERC20Implementation: string;
    BridgedTokenBeacon: string;
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
      L1NullifierImplementation: getAddressFromEnv("CONTRACTS_L1_NULLIFIER_IMPL_ADDR"),
      L1NullifierProxy: getAddressFromEnv("CONTRACTS_L1_NULLIFIER_PROXY_ADDR"),
      ERC20BridgeImplementation: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR"),
      ERC20BridgeProxy: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR"),
      SharedBridgeImplementation: getAddressFromEnv("CONTRACTS_L1_SHARED_BRIDGE_IMPL_ADDR"),
      SharedBridgeProxy: getAddressFromEnv("CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR"),
      L2NativeTokenVaultImplementation: getAddressFromEnv("CONTRACTS_L2_NATIVE_TOKEN_VAULT_IMPL_ADDR"),
      L2NativeTokenVaultProxy: getAddressFromEnv("CONTRACTS_L2_NATIVE_TOKEN_VAULT_PROXY_ADDR"),
      L2SharedBridgeImplementation: getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR"),
      L2SharedBridgeProxy: getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR"),
      L2LegacySharedBridgeProxy: getAddressFromEnv("CONTRACTS_L2_LEGACY_SHARED_BRIDGE_ADDR"),
      L2LegacySharedBridgeImplementation: getAddressFromEnv("CONTRACTS_L2_LEGACY_SHARED_BRIDGE_IMPL_ADDR"),
      NativeTokenVaultImplementation: getAddressFromEnv("CONTRACTS_L1_NATIVE_TOKEN_VAULT_IMPL_ADDR"),
      NativeTokenVaultProxy: getAddressFromEnv("CONTRACTS_L1_NATIVE_TOKEN_VAULT_PROXY_ADDR"),
      BridgedStandardERC20Implementation: getAddressFromEnv("CONTRACTS_L1_BRIDGED_STANDARD_ERC20_IMPL_ADDR"),
      BridgedTokenBeacon: getAddressFromEnv("CONTRACTS_L1_BRIDGED_TOKEN_BEACON_ADDR"),
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
