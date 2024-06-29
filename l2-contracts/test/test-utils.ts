import { ethers } from "ethers";
import * as hre from "hardhat";
import * as zksync from "zksync-ethers";
import type { BytesLike } from "ethers";
import { ContractDeployerFactory } from "../typechain/ContractDeployerFactory";

const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);

export function unapplyL1ToL2Alias(address: string): string {
  // We still add ADDRESS_MODULO to avoid negative numbers
  return ethers.utils.hexlify(
    ethers.BigNumber.from(address).sub(L1_TO_L2_ALIAS_OFFSET).add(ADDRESS_MODULO).mod(ADDRESS_MODULO)
  );
}

// Force deploy bytecode on the address
export async function setCode(
  deployerWallet: zksync.Wallet,
  address: string,
  bytecode: BytesLike,
  callConstructor: boolean = false,
  constructorArgs: BytesLike
) {
  const REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
  // TODO: think about factoryDeps with eth_sendTransaction
  try {
    // publish bytecode in a separate tx
    await publishBytecode(bytecode, deployerWallet);
  } catch {
    // ignore error
  }

  const deployerAccount = await hre.ethers.getImpersonatedSigner(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  const deployerContract = ContractDeployerFactory.connect(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, deployerAccount);

  const deployment = {
    bytecodeHash: zksync.utils.hashBytecode(bytecode),
    newAddress: address,
    callConstructor,
    value: 0,
    input: constructorArgs,
  };
  await deployerContract.forceDeployOnAddress(deployment, ethers.constants.AddressZero);
}

export async function publishBytecode(bytecode: BytesLike, deployerWallet: zksync.Wallet) {
  await deployerWallet.sendTransaction({
    type: 113,
    to: ethers.constants.AddressZero,
    data: "0x",
    customData: {
      factoryDeps: [ethers.utils.hexlify(bytecode)],
      gasPerPubdata: 50000,
    },
  });
}
