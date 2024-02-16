import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ethers } from "ethers";
import { SingletonFactoryFactory } from "../typechain";

import { getAddressFromEnv } from "./utils";

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

  const waitBlocks = (await deployWallet.provider.getNetwork()).chainId == 31337 ? 1 : 2; //hardhat chainId
  const receipt = await tx.wait(waitBlocks);
  const gasUsed = receipt.gasUsed;
  log(`${contractName} deployed, gasUsed: ${gasUsed.toString()}`);

  const deployedBytecodeAfter = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error(`Failed to deploy ${contractName} bytecode via create2 factory`);
  }

  return [expectedAddress, tx.hash];
}

export interface DeployedAddresses {
  Bridgehub: {
    BridgehubProxy: string;
    BridgehubImplementation: string;
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
  };
  BaseToken: string;
  TransparentProxyAdmin: string;
  Governance: string;
  ValidatorTimeLock: string;
  Create2Factory: string;
  Deployer: string;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
  return {
    Bridgehub: {
      BridgehubProxy: getAddressFromEnv("CONTRACTS_BRIDGEHUB_PROXY_ADDR"),
      BridgehubImplementation: getAddressFromEnv("CONTRACTS_BRIDGEHUB_IMPL_ADDR"),
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
    },
    BaseToken: getAddressFromEnv("CONTRACTS_BASE_TOKEN_ADDR"),
    TransparentProxyAdmin: getAddressFromEnv("CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR"),
    Create2Factory: getAddressFromEnv("CONTRACTS_CREATE2_FACTORY_ADDR"),
    ValidatorTimeLock: getAddressFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_ADDR"),
    Governance: getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR"),
    Deployer: getAddressFromEnv("CONTRACTS_DEPLOYER_ADDR"),
  };
}
