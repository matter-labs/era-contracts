// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish } from "ethers";
import { ethers } from "ethers";

import type { FacetCut } from "./diamondCut";

import type { Deployer } from "./deploy";
import { getTokens } from "./deploy-token";

import { ADDRESS_ONE } from "../src.ts/utils";

export const L2_BOOTLOADER_BYTECODE_HASH = "0x1000100000000000000000000000000000000000000000000000000000000000";
export const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = "0x1001000000000000000000000000000000000000000000000000000000000000";

export async function initialBridgehubDeployment(
  deployer: Deployer,
  extraFacets: FacetCut[],
  gasPrice: BigNumberish,
  onlyVerifier: boolean,
  create2Salt?: string,
  nonce?: number
) {
  nonce = nonce || (await deployer.deployWallet.getTransactionCount());
  create2Salt = create2Salt || ethers.utils.hexlify(ethers.utils.randomBytes(32));

  // Create2 factory already deployed on the public networks, only deploy it on local node
  if (process.env.CHAIN_ETH_NETWORK === "localhost" || process.env.CHAIN_ETH_NETWORK === "hardhat") {
    await deployer.deployCreate2Factory({ gasPrice, nonce });
    nonce++;

    await deployer.deployMulticall3(create2Salt, { gasPrice, nonce });
    nonce++;
  }

  if (onlyVerifier) {
    await deployer.deployVerifier(create2Salt, { gasPrice, nonce });
    return;
  }

  await deployer.deployDefaultUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  await deployer.deployGenesisUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  await deployer.deployValidatorTimelock(create2Salt, { gasPrice, nonce });
  nonce++;

  await deployer.deployGovernance(create2Salt, { gasPrice, nonce });
  nonce++;

  await deployer.deployChainAdmin(create2Salt, { gasPrice, nonce });
  await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  await deployer.deployBridgehubContract(create2Salt, gasPrice);
  await deployer.deployBlobVersionedHashRetriever(create2Salt, { gasPrice });
  await deployer.deployStateTransitionManagerContract(create2Salt, extraFacets, gasPrice);
  await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

  await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
  await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
  await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });
  await deployer.setParametersSharedBridge();
}

export async function registerHyperchain(
  deployer: Deployer,
  validiumMode: boolean,
  extraFacets: FacetCut[],
  gasPrice: BigNumberish,
  baseTokenName?: string,
  chainId?: string,
  useGovernance: boolean = false
) {
  const testnetTokens = getTokens();

  const baseTokenAddress = baseTokenName
    ? testnetTokens.find((token: { symbol: string }) => token.symbol == baseTokenName).address
    : ADDRESS_ONE;

  if (!(await deployer.bridgehubContract(deployer.deployWallet).tokenIsRegistered(baseTokenAddress))) {
    await deployer.registerToken(baseTokenAddress, useGovernance);
  }
  await deployer.registerHyperchain(
    baseTokenAddress,
    validiumMode,
    extraFacets,
    gasPrice,
    null,
    chainId,
    useGovernance
  );
}
