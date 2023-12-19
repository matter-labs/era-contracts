import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ethers } from "ethers";
import { SingletonFactoryFactory } from "../typechain";

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
  libraries?: any
): Promise<[string, string]> {
  // [address, txHash]

  const log = (msg: string) => {
    if (verbose) {
      console.log(msg);
    }
  };
  log(`Deploying ${contractName}`);

  const create2Factory = SingletonFactoryFactory.connect(create2FactoryAddress, deployWallet);
  const contractFactory = await hardhat.ethers.getContractFactory(contractName, {
    signer: deployWallet,
    libraries,
  });
  const bytecode = contractFactory.getDeployTransaction(...[...args, ethTxOptions]).data;
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
  const receipt = await tx.wait(2);

  const gasUsed = receipt.gasUsed;
  log(`${contractName} deployed, gasUsed: ${gasUsed.toString()}`);

  const deployedBytecodeAfter = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error("Failed to deploy bytecode via create2 factory");
  }

  return [expectedAddress, tx.hash];
}
