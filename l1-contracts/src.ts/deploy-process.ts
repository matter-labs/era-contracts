// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish } from "ethers";
import { ethers } from "ethers";

import type { FacetCut } from "./diamondCut";

import type { Deployer } from "./deploy";
import { getTokens } from "./deploy-token";

import {
  ADDRESS_ONE,
  L2_BRIDGEHUB_ADDRESS,
  L2_MESSAGE_ROOT_ADDRESS,
  isCurrentNetworkLocal,
  encodeNTVAssetId,
} from "../src.ts/utils";

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
  create2Salt = create2Salt || ethers.utils.hexlify(ethers.utils.randomBytes(32));

  // Create2 factory already deployed on the public networks, only deploy it on local node
  if (isCurrentNetworkLocal()) {
    if (!deployer.isZkMode()) {
      await deployer.deployCreate2Factory({ gasPrice, nonce });
      nonce = nonce || nonce == 0 ? ++nonce : nonce;
    } else {
      await deployer.updateCreate2FactoryZkMode();
    }

    await deployer.deployMulticall3(create2Salt, { gasPrice, nonce });
    nonce = nonce || nonce == 0 ? ++nonce : nonce;
  }

  if (onlyVerifier) {
    await deployer.deployVerifier(create2Salt, { gasPrice, nonce });
    return;
  }

  await deployer.deployDefaultUpgrade(create2Salt, {
    gasPrice,
  });
  nonce = nonce ? ++nonce : nonce;

  await deployer.deployGenesisUpgrade(create2Salt, {
    gasPrice,
  });
  nonce = nonce ? ++nonce : nonce;

  await deployer.deployDAValidators(create2Salt, { gasPrice });
  // Governance will be L1 governance, but we want to deploy it here for the init process.
  await deployer.deployGovernance(create2Salt, { gasPrice });
  await deployer.deployChainAdmin(create2Salt, { gasPrice });
  await deployer.deployValidatorTimelock(create2Salt, { gasPrice });

  if (!deployer.isZkMode()) {
    // proxy admin is already deployed when SL's L2SharedBridge is registered
    await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
    await deployer.deployBridgehubContract(create2Salt, gasPrice);
  } else {
    deployer.addresses.Bridgehub.BridgehubProxy = L2_BRIDGEHUB_ADDRESS;
    deployer.addresses.Bridgehub.MessageRootProxy = L2_MESSAGE_ROOT_ADDRESS;

    console.log(`CONTRACTS_BRIDGEHUB_IMPL_ADDR=${L2_BRIDGEHUB_ADDRESS}`);
    console.log(`CONTRACTS_BRIDGEHUB_PROXY_ADDR=${L2_BRIDGEHUB_ADDRESS}`);
    console.log(`CONTRACTS_MESSAGE_ROOT_IMPL_ADDR=${L2_MESSAGE_ROOT_ADDRESS}`);
    console.log(`CONTRACTS_MESSAGE_ROOT_PROXY_ADDR=${L2_MESSAGE_ROOT_ADDRESS}`);
  }

  // L2 Asset Router Bridge already deployed
  if (!deployer.isZkMode()) {
    await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
    await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
    await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });
    await deployer.setParametersSharedBridge();
  }

  if (deployer.isZkMode()) {
    await deployer.updateBlobVersionedHashRetrieverZkMode();
  } else {
    await deployer.deployBlobVersionedHashRetriever(create2Salt, { gasPrice });
  }
  await deployer.deployChainTypeManagerContract(create2Salt, extraFacets, gasPrice);
  await deployer.setChainTypeManagerInValidatorTimelock({ gasPrice });
}

export async function registerZKChain(
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

  const baseTokenAssetId = encodeNTVAssetId(deployer.l1ChainId, ethers.utils.hexZeroPad(baseTokenAddress, 32));
  if (!(await deployer.bridgehubContract(deployer.deployWallet).assetIdIsRegistered(baseTokenAssetId))) {
    await deployer.registerTokenBridgehub(baseTokenAddress, useGovernance);
  }
  if (baseTokenAddress !== ADDRESS_ONE) {
    await deployer.registerTokenInNativeTokenVault(baseTokenAddress);
  }
  await deployer.registerZKChain(
    encodeNTVAssetId(deployer.l1ChainId, ethers.utils.hexZeroPad(baseTokenAddress, 32)),
    validiumMode,
    extraFacets,
    gasPrice,
    false,
    null,
    chainId,
    useGovernance,
    true
  );
}
