import { artifacts } from "hardhat";

import { Interface } from "ethers/lib/utils";
import { deployedAddressesFromEnv } from "../../l1-contracts/src.ts/deploy-utils";
import type { Deployer } from "../../l1-contracts/src.ts/deploy";
import { ADDRESS_ONE, getNumberFromEnv } from "../../l1-contracts/src.ts/utils";
import { IBridgehubFactory } from "../../l1-contracts/typechain/IBridgehubFactory";
import { web3Provider } from "../../l1-contracts/scripts/utils";

import type { BigNumber, BytesLike, Wallet } from "ethers";
import { ethers } from "ethers";
import type { Provider } from "zksync-ethers";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT, sleep } from "zksync-ethers/build/utils";

import { IERC20Factory } from "../typechain/IERC20Factory";

export const provider = web3Provider();

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(["string"], ["zksyncCreate2"]);
const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);

export const priorityTxMaxGasLimit = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");

export function applyL1ToL2Alias(address: string): string {
  return ethers.utils.hexZeroPad(
    ethers.utils.hexlify(ethers.BigNumber.from(address).add(L1_TO_L2_ALIAS_OFFSET).mod(ADDRESS_MODULO)),
    20
  );
}

export function unapplyL1ToL2Alias(address: string): string {
  // We still add ADDRESS_MODULO to avoid negative numbers
  return ethers.utils.hexZeroPad(
    ethers.utils.hexlify(
      ethers.BigNumber.from(address).sub(L1_TO_L2_ALIAS_OFFSET).add(ADDRESS_MODULO).mod(ADDRESS_MODULO)
    ),
    20
  );
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

export function computeL2Create2Address(
  deployWallet: Wallet,
  bytecode: BytesLike,
  constructorInput: BytesLike,
  create2Salt: BytesLike
) {
  const senderBytes = ethers.utils.hexZeroPad(deployWallet.address, 32);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const constructorInputHash = ethers.utils.keccak256(constructorInput);

  const data = ethers.utils.keccak256(
    ethers.utils.concat([CREATE2_PREFIX, senderBytes, create2Salt, bytecodeHash, constructorInputHash])
  );

  return ethers.utils.hexDataSlice(data, 12);
}

export async function create2DeployFromL1(
  chainId: ethers.BigNumberish,
  wallet: ethers.Wallet,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish,
  gasPrice?: ethers.BigNumberish,
  extraFactoryDeps?: ethers.BytesLike[]
) {
  const deployerSystemContracts = new Interface(artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);

  const factoryDeps = extraFactoryDeps ? [bytecode, ...extraFactoryDeps] : [bytecode];
  return await requestL2TransactionDirect(
    chainId,
    wallet,
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    calldata,
    l2GasLimit,
    gasPrice,
    factoryDeps
  );
}

export async function requestL2TransactionDirect(
  chainId: ethers.BigNumberish,
  wallet: ethers.Wallet,
  l2Contract: string,
  calldata: string,
  l2GasLimit: ethers.BigNumberish,
  gasPrice?: ethers.BigNumberish,
  factoryDeps?: ethers.BytesLike[]
) {
  const deployedAddresses = deployedAddressesFromEnv();
  const bridgehubAddress = deployedAddresses.Bridgehub.BridgehubProxy;
  const bridgehub = IBridgehubFactory.connect(bridgehubAddress, wallet);
  gasPrice ??= await bridgehub.provider.getGasPrice();

  const expectedCost = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const baseTokenAddress = await bridgehub.baseToken(chainId);
  const baseTokenBridge = deployedAddresses.Bridges.SharedBridgeProxy;
  const baseToken = IERC20Factory.connect(baseTokenAddress, wallet);
  const ethIsBaseToken = ADDRESS_ONE == baseTokenAddress;

  if (!ethIsBaseToken) {
    const tx = await baseToken.approve(baseTokenBridge, expectedCost);
    await tx.wait();
  }
  return await bridgehub.requestL2TransactionDirect(
    {
      chainId,
      l2Contract: l2Contract,
      mintValue: expectedCost,
      l2Value: 0,
      l2Calldata: calldata,
      l2GasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: factoryDeps ?? [],
      refundRecipient: wallet.address,
    },
    { value: ethIsBaseToken ? expectedCost : 0, gasPrice }
  );
}

export async function publishBytecodeFromL1(
  chainId: ethers.BigNumberish,
  wallet: ethers.Wallet,
  factoryDeps: ethers.BytesLike[],
  gasPrice?: ethers.BigNumberish
) {
  return await requestL2TransactionDirect(
    chainId,
    wallet,
    ethers.constants.AddressZero,
    "0x",
    priorityTxMaxGasLimit,
    gasPrice,
    factoryDeps
  );
}

export async function awaitPriorityOps(
  zksProvider: Provider,
  l1TxReceipt: ethers.providers.TransactionReceipt,
  zksyncInterface: ethers.utils.Interface
) {
  const deployL2TxHashes = l1TxReceipt.logs
    .map((log) => zksyncInterface.parseLog(log))
    .filter((event) => event.name === "NewPriorityRequest")
    .map((event) => event.args[1]);
  for (const txHash of deployL2TxHashes) {
    console.log("Awaiting L2 transaction with hash: ", txHash);
    let receipt = null;
    while (receipt == null) {
      receipt = await zksProvider.getTransactionReceipt(txHash);
      await sleep(100);
    }

    if (receipt.status != 1) {
      throw new Error("Failed to process L2 tx");
    }
  }
}

export type TxInfo = {
  data: string;
  target: string;
  value?: string;
};

export async function getL1TxInfo(
  deployer: Deployer,
  to: string,
  l2Calldata: string,
  refundRecipient: string,
  gasPrice: BigNumber,
  priorityTxMaxGasLimit: BigNumber,
  provider: ethers.providers.JsonRpcProvider
): Promise<TxInfo> {
  const zksync = deployer.stateTransitionContract(ethers.Wallet.createRandom().connect(provider));
  const l1Calldata = zksync.interface.encodeFunctionData("requestL2Transaction", [
    to,
    0,
    l2Calldata,
    priorityTxMaxGasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
    [], // It is assumed that the target has already been deployed
    refundRecipient,
  ]);

  const neededValue = await zksync.l2TransactionBaseCost(
    gasPrice,
    priorityTxMaxGasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT
  );

  return {
    target: zksync.address,
    data: l1Calldata,
    value: neededValue.toString(),
  };
}

const LOCAL_NETWORKS = ["localhost", "hardhat", "localhostL2"];

export function isCurrentNetworkLocal(): boolean {
  return LOCAL_NETWORKS.includes(process.env.CHAIN_ETH_NETWORK);
}
