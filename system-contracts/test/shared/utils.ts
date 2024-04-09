import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import type { ZkSyncArtifact } from "@matterlabs/hardhat-zksync-deploy/dist/types";
import { BigNumber } from "ethers";
import type { BytesLike } from "ethers";
import * as hre from "hardhat";
import { ethers } from "hardhat";
import type { Contract } from "zksync-ethers";
import * as zksync from "zksync-ethers";
import { Provider, utils, Wallet } from "zksync-ethers";
import { Language } from "../../scripts/constants";
import { readYulBytecode, readZasmBytecode } from "../../scripts/utils";
import { AccountCodeStorageFactory, ContractDeployerFactory } from "../../typechain";
import {
  REAL_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TWO_IN_256,
} from "./constants";

const RICH_WALLETS = [
  {
    address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
    privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
  },
  {
    address: "0xa61464658AfeAf65CccaaFD3a512b69A83B77618",
    privateKey: "0xac1e735be8536c6534bb4f17f06f6afc73b2b5ba84ac2cfb12f7461b20c0bbe3",
  },
  {
    address: "0x0D43eB5B8a47bA8900d84AA36656c92024e9772e",
    privateKey: "0xd293c684d884d56f8d6abd64fc76757d3664904e309a0645baf8522ab6366d9e",
  },
  {
    address: "0xA13c10C0D5bd6f79041B9835c63f91de35A15883",
    privateKey: "0x850683b40d4a740aa6e745f889a6fdc8327be76e122f5aba645a5b02d0248db8",
  },
];

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const provider = new Provider((hre.network.config as any).url);

const wallet = new Wallet(RICH_WALLETS[0].privateKey, provider);
// TODO(EVM-392): refactor to avoid `any` here.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const deployer = new Deployer(hre, wallet as any);

export async function callFallback(contract: Contract, data: string) {
  // `eth_Call` revert is not parsed by ethers, so we send
  // transaction to catch the error and use `eth_Call` to the return data.
  await contract.fallback({ data });
  return contract.provider.call({
    to: contract.address,
    data,
  });
}

export function getWallets(): Wallet[] {
  const wallets: Wallet[] = [];
  for (let i = 0; i < RICH_WALLETS.length; i++) {
    wallets[i] = new Wallet(RICH_WALLETS[i].privateKey, provider);
  }
  return wallets;
}

export async function loadArtifact(name: string): Promise<ZkSyncArtifact> {
  return await deployer.loadArtifact(name);
}

export function loadYulBytecode(codeName: string, path: string): string {
  return readYulBytecode({
    codeName,
    path,
    lang: Language.Yul,
    address: "0x0000000000000000000000000000000000000000",
  });
}

export function loadZasmBytecode(codeName: string, path: string): string {
  return readZasmBytecode({
    codeName,
    path,
    lang: Language.Zasm,
    address: "0x0000000000000000000000000000000000000000",
  });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function deployContract(name: string, constructorArguments?: any[] | undefined): Promise<Contract> {
  const artifact = await loadArtifact(name);
  return await deployer.deploy(artifact, constructorArguments);
}

export async function deployContractYul(codeName: string, path: string): Promise<Contract> {
  const bytecode = loadYulBytecode(codeName, path);
  return deployBytecode(bytecode);
}

export async function deployContractZasm(codeName: string, path: string): Promise<Contract> {
  const bytecode = loadZasmBytecode(codeName, path);
  return deployBytecode(bytecode);
}

async function deployBytecode(bytecode: string): Promise<Contract> {
  return await deployer.deploy(
    {
      bytecode,
      factoryDeps: {},
      sourceMapping: "",
      _format: "",
      contractName: "",
      sourceName: "",
      abi: [],
      deployedBytecode: bytecode,
      linkReferences: {},
      deployedLinkReferences: {},
    },
    []
  );
}

export async function deployContractOnAddress(address: string, name: string) {
  const artifact = await loadArtifact(name);
  await setCode(address, artifact.bytecode, true);
}

export async function publishBytecode(bytecode: BytesLike) {
  await wallet.sendTransaction({
    type: 113,
    to: ethers.constants.AddressZero,
    data: "0x",
    customData: {
      factoryDeps: [ethers.utils.hexlify(bytecode)],
      gasPerPubdata: 50000,
    },
  });
}

export async function getCode(address: string): Promise<string> {
  return await provider.getCode(address);
}

// Force deploy bytecode on the address
export async function setCode(address: string, bytecode: BytesLike, callConstructor: boolean = false) {
  // TODO: think about factoryDeps with eth_sendTransaction
  try {
    // publish bytecode in a separate tx
    await publishBytecode(bytecode);
  } catch {
    // ignore error
  }

  const deployerAccount = await ethers.getImpersonatedSigner(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  const deployerContract = ContractDeployerFactory.connect(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, deployerAccount);

  const deployment = {
    bytecodeHash: zksync.utils.hashBytecode(bytecode),
    newAddress: address,
    callConstructor,
    value: 0,
    input: "0x",
  };
  await deployerContract.forceDeployOnAddress(deployment, ethers.constants.AddressZero);
}

export async function setConstructingCodeHash(address: string, bytecode: string) {
  const deployerAccount = await ethers.getImpersonatedSigner(REAL_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  const accountCodeStorage = AccountCodeStorageFactory.connect(
    REAL_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
    deployerAccount
  );

  const bytecodeHash = utils.hashBytecode(bytecode);
  bytecodeHash[1] = 1;
  await accountCodeStorage.storeAccountConstructingCodeHash(address, bytecodeHash);
}

export interface StateDiff {
  key: BytesLike;
  index: number;
  initValue: BigNumber;
  finalValue: BigNumber;
}

export function encodeStateDiffs(stateDiffs: StateDiff[]): string {
  const rawStateDiffs = [];
  for (const stateDiff of stateDiffs) {
    rawStateDiffs.push(
      ethers.utils.solidityPack(
        ["address", "bytes32", "bytes32", "uint64", "uint256", "uint256", "bytes"],
        [
          ethers.constants.AddressZero,
          ethers.constants.HashZero,
          stateDiff.key,
          stateDiff.index,
          stateDiff.initValue,
          stateDiff.finalValue,
          "0x" + "00".repeat(116),
        ]
      )
    );
  }
  return ethers.utils.hexlify(ethers.utils.concat(rawStateDiffs));
}

export function compressStateDiffs(enumerationIndexSize: number, stateDiffs: StateDiff[]): string {
  let numInitial = 0;
  const initial = [];
  const repeated = [];
  for (const stateDiff of stateDiffs) {
    const addition = stateDiff.finalValue.sub(stateDiff.initValue).add(TWO_IN_256).mod(TWO_IN_256);
    const subtraction = stateDiff.initValue.sub(stateDiff.finalValue).add(TWO_IN_256).mod(TWO_IN_256);
    let op = 3;
    let min = stateDiff.finalValue;
    if (addition.lt(min)) {
      min = addition;
      op = 1;
    }
    if (subtraction.lt(min)) {
      min = subtraction;
      op = 2;
    }
    if (min.gte(BigNumber.from(2).pow(248))) {
      min = stateDiff.finalValue;
      op = 0;
    }
    let len = 0;
    const minHex = min.eq(0) ? "0x" : min.toHexString();
    if (op > 0) {
      len = (minHex.length - 2) / 2;
    }
    const metadata = (len << 3) + op;
    if (stateDiff.index === 0) {
      numInitial += 1;
      initial.push(ethers.utils.solidityPack(["bytes32", "uint8", "bytes"], [stateDiff.key, metadata, minHex]));
    } else {
      const enumerationIndexType = "uint" + (enumerationIndexSize * 8).toString();
      repeated.push(
        ethers.utils.solidityPack([enumerationIndexType, "uint8", "bytes"], [stateDiff.index, metadata, minHex])
      );
    }
  }
  return ethers.utils.hexlify(
    ethers.utils.concat([ethers.utils.solidityPack(["uint16"], [numInitial]), ...initial, ...repeated])
  );
}
