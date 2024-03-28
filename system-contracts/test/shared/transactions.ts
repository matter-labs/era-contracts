import type { BigNumberish, BytesLike, Transaction } from "ethers";
import * as zksync from "zksync-ethers";

// Interface encoding the transaction struct used for AA protocol
export interface TransactionData {
  txType: BigNumberish;
  from: BigNumberish;
  to: BigNumberish;
  gasLimit: BigNumberish;
  gasPerPubdataByteLimit: BigNumberish;
  maxFeePerGas: BigNumberish;
  maxPriorityFeePerGas: BigNumberish;
  paymaster: BigNumberish;
  nonce: BigNumberish;
  value: BigNumberish;
  // In the future, we might want to add some
  // new fields to the struct. The `txData` struct
  // is to be passed to account and any changes to its structure
  // would mean a breaking change to these accounts. In order to prevent this,
  // we should keep some fields as "reserved".
  // It is also recommended that their length is fixed, since
  // it would allow easier proof integration (in case we will need
  // some special circuit for preprocessing transactions).
  reserved: [BigNumberish, BigNumberish, BigNumberish, BigNumberish];
  data: BytesLike;
  signature: BytesLike;
  factoryDeps: BytesLike[];
  paymasterInput: BytesLike;
  // Reserved dynamic type for the future use-case. Using it should be avoided,
  // But it is still here, just in case we want to enable some additional functionality.
  reservedDynamic: BytesLike;
}

export function signedTxToTransactionData(tx: Transaction) {
  // Transform legacy transaction's `v` part of the signature
  // to a single byte used in the packed eth signature
  function unpackV(v: number) {
    if (v >= 35) {
      const chainId = Math.floor((v - 35) / 2);
      return v - chainId * 2 - 8;
    } else if (v <= 1) {
      return 27 + v;
    }

    throw new Error("Invalid `v`");
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function legacyTxToTransactionData(tx: any): TransactionData {
    return {
      txType: 0,
      from: tx.from!,
      to: tx.to!,
      gasLimit: tx.gasLimit!,
      gasPerPubdataByteLimit: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
      maxFeePerGas: tx.gasPrice!,
      maxPriorityFeePerGas: tx.gasPrice!,
      paymaster: 0,
      nonce: tx.nonce,
      value: tx.value || 0,
      reserved: [tx.chainId || 0, 0, 0, 0],
      data: tx.data!,
      signature: ethers.utils.hexConcat([tx.r, tx.s, new Uint8Array([unpackV(tx.v)])]),
      factoryDeps: [],
      paymasterInput: "0x",
      reservedDynamic: "0x",
    };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function eip2930TxToTransactionData(tx: any): TransactionData {
    return {
      txType: 1,
      from: tx.from!,
      to: tx.to!,
      gasLimit: tx.gasLimit!,
      gasPerPubdataByteLimit: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
      maxFeePerGas: tx.gasPrice!,
      maxPriorityFeePerGas: tx.gasPrice!,
      paymaster: 0,
      nonce: tx.nonce,
      value: tx.value || 0,
      reserved: [0, 0, 0, 0],
      data: tx.data!,
      signature: ethers.utils.hexConcat([tx.r, tx.s, unpackV(tx.v)]),
      factoryDeps: [],
      paymasterInput: "0x",
      reservedDynamic: "0x",
    };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function eip1559TxToTransactionData(tx: any): TransactionData {
    return {
      txType: 2,
      from: tx.from!,
      to: tx.to!,
      gasLimit: tx.gasLimit!,
      gasPerPubdataByteLimit: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
      maxFeePerGas: tx.maxFeePerGas,
      maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
      paymaster: 0,
      nonce: tx.nonce,
      value: tx.value || 0,
      reserved: [0, 0, 0, 0],
      data: tx.data!,
      signature: ethers.utils.hexConcat([tx.r, tx.s, unpackV(tx.v)]),
      factoryDeps: [],
      paymasterInput: "0x",
      reservedDynamic: "0x",
    };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function eip712TxToTransactionData(tx: any): TransactionData {
    return {
      txType: 113,
      from: tx.from!,
      to: tx.to!,
      gasLimit: tx.gasLimit!,
      gasPerPubdataByteLimit: tx.customData.gasPerPubdata || zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
      maxFeePerGas: tx.maxFeePerGas,
      maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
      paymaster: tx.customData.paymasterParams?.paymaster || 0,
      nonce: tx.nonce,
      value: tx.value || 0,
      reserved: [0, 0, 0, 0],
      data: tx.data!,
      signature: tx.customData.customSignature,
      factoryDeps: tx.customData.factoryDeps.map(zksync.utils.hashBytecode),
      paymasterInput: tx.customData.paymasterParams?.paymasterInput || "0x",
      reservedDynamic: "0x",
    };
  }

  const txType = tx.type ?? 0;

  switch (txType) {
    case 0:
      return legacyTxToTransactionData(tx);
    case 1:
      return eip2930TxToTransactionData(tx);
    case 2:
      return eip1559TxToTransactionData(tx);
    case 113:
      return eip712TxToTransactionData(tx);
    default:
      throw new Error("Unsupported tx type");
  }
}
