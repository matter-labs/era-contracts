import { ContractFactory, Contract, providers, Wallet, ethers } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR } from "../core/const";
import type { PrivateInteropAddresses } from "../core/types";

// Dedicated deployer key for private interop contracts.
// Using a separate wallet (Anvil account #9) ensures the same nonce (0) on all chains,
// which gives deterministic addresses — required because initiateIndirectCall returns
// address(this) as the target l2Contract.
export const PRIVATE_DEPLOYER_KEY = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

export type { PrivateInteropAddresses };

type Logger = (line: string) => void;

export interface DeployOptions {
  /** Private key for the deployer wallet. Defaults to PRIVATE_DEPLOYER_KEY. */
  deployerKey?: string;
  /** If true, skip funding the deployer from the default Anvil account. */
  skipFunding?: boolean;
  /** Gas overrides for deploy transactions (large contracts). */
  deployGasOverrides?: { gasPrice?: ethers.BigNumber; gasLimit?: number; type?: number };
  /** Gas overrides for init/config transactions. */
  initGasOverrides?: { gasPrice?: ethers.BigNumber; gasLimit?: number; type?: number };
  /** Destination chain IDs to register in InteropCenter (for pre-v31 chains). */
  destinationChainIds?: number[];
}

/** Try calling a contract view function; return fallback on revert (for pre-v31 chains). */
async function tryCall<T>(contract: Contract, method: string, args: unknown[], fallback: T, log: Logger): Promise<T> {
  try {
    return await contract[method](...args);
  } catch {
    log(`    (${method} not available, using fallback)`);
    return fallback;
  }
}

/**
 * Deploy the full private interop stack on a given chain.
 * Order: AssetTracker -> NTV -> AssetRouter -> InteropCenter -> InteropHandler
 *
 * Works on both local Anvil and live testnets. For pre-v31 chains, system contract
 * calls that don't exist fall back to sensible defaults.
 */
export async function deployPrivateInteropStack(
  rpcUrl: string,
  chainId: number,
  l1ChainId: number,
  logger?: Logger,
  options?: DeployOptions
): Promise<PrivateInteropAddresses> {
  const log = logger || console.log;
  const opts = options || {};
  const provider = new providers.JsonRpcProvider(rpcUrl);
  const deployerKey = opts.deployerKey || PRIVATE_DEPLOYER_KEY;
  const deployerWallet = new Wallet(deployerKey, provider);

  // Fund the deployer if needed (Anvil only — live chains should be pre-funded)
  if (!opts.skipFunding) {
    const mainWallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
    const deployerBalance = await provider.getBalance(deployerWallet.address);
    if (deployerBalance.lt(ethers.utils.parseEther("1"))) {
      const fundTx = await mainWallet.sendTransaction({
        to: deployerWallet.address,
        value: ethers.utils.parseEther("10"),
      });
      await fundTx.wait();
    }
  }

  const wallet = deployerWallet;

  // Read system contract state — use tryCall for functions that may not exist on older chains
  const systemNtv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), provider);
  const baseTokenAssetId = await systemNtv.BASE_TOKEN_ASSET_ID();
  const wethToken = await tryCall(systemNtv, "WETH_TOKEN", [], ethers.constants.AddressZero, log);
  const l2TokenProxyBytecodeHash = await tryCall(
    systemNtv,
    "L2_TOKEN_PROXY_BYTECODE_HASH",
    [],
    ethers.constants.HashZero,
    log
  );
  const bridgedTokenBeacon = await tryCall(systemNtv, "bridgedTokenBeacon", [], ethers.constants.AddressZero, log);
  const baseTokenOriginToken = await tryCall(
    systemNtv,
    "BASE_TOKEN_ORIGIN_TOKEN",
    [],
    "0x0000000000000000000000000000000000000001",
    log
  );
  const baseTokenName = await tryCall(systemNtv, "BASE_TOKEN_NAME", [], "Ether", log);
  const baseTokenSymbol = await tryCall(systemNtv, "BASE_TOKEN_SYMBOL", [], "ETH", log);
  const baseTokenDecimals = await tryCall(systemNtv, "BASE_TOKEN_DECIMALS", [], 18, log);
  const baseTokenOriginChainId = await tryCall(systemNtv, "originChainId", [baseTokenAssetId], l1ChainId, log);

  // InteropCenter may not exist on pre-v31 chains
  const interopCenterCode = await provider.getCode(INTEROP_CENTER_ADDR);
  let zkTokenAssetId: string;
  if (interopCenterCode.length > 2) {
    const systemInteropCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
    zkTokenAssetId = await tryCall(systemInteropCenter, "ZK_TOKEN_ASSET_ID", [], ethers.constants.HashZero, log);
    if (zkTokenAssetId === ethers.constants.HashZero) {
      zkTokenAssetId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("dummy-zk-token"));
    }
  } else {
    log("    (InteropCenter not deployed, using dummy zkTokenAssetId)");
    zkTokenAssetId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("dummy-zk-token"));
  }

  const assetRouterCode = await provider.getCode("0x0000000000000000000000000000000000010003");
  if (assetRouterCode.length <= 2) {
    throw new Error("L2AssetRouter system contract not deployed — chain cannot support interop");
  }
  const systemAssetRouter = new Contract(
    "0x0000000000000000000000000000000000010003",
    getAbi("L2AssetRouter"),
    provider
  );
  const l1AssetRouter = await systemAssetRouter.L1_ASSET_ROUTER();

  // Deploy contracts
  const deployOverrides = opts.deployGasOverrides || {};
  const initOverrides = opts.initGasOverrides || {};

  async function deploy(name: string): Promise<Contract> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const factory = new ContractFactory(getAbi(name as any), getCreationBytecode(name as any), wallet);
    const contract = await factory.deploy(deployOverrides);
    await contract.deployed();
    log(`    ${name}: ${contract.address}`);
    return contract;
  }

  log("  Deploying PrivateL2AssetTracker...");
  const assetTracker = await deploy("PrivateL2AssetTracker");
  log("  Deploying PrivateL2NativeTokenVault...");
  const ntv = await deploy("PrivateL2NativeTokenVault");
  log("  Deploying PrivateL2AssetRouter...");
  const assetRouter = await deploy("PrivateL2AssetRouter");
  log("  Deploying PrivateInteropCenter...");
  const interopCenter = await deploy("PrivateInteropCenter");
  log("  Deploying PrivateInteropHandler...");
  const interopHandler = await deploy("PrivateInteropHandler");

  // Initialize
  log("  Initializing AssetTracker...");
  await (await assetTracker.initialize(l1ChainId, baseTokenAssetId, ntv.address, initOverrides)).wait();

  log("  Initializing NTV...");
  await (
    await ntv.initialize(
      l1ChainId,
      assetRouter.address,
      assetTracker.address,
      bridgedTokenBeacon,
      l2TokenProxyBytecodeHash,
      wethToken,
      { assetId: baseTokenAssetId, originChainId: baseTokenOriginChainId, originToken: baseTokenOriginToken },
      { name: baseTokenName, symbol: baseTokenSymbol, decimals: baseTokenDecimals },
      initOverrides
    )
  ).wait();

  log("  Initializing AssetRouter...");
  await (
    await assetRouter.initialize(
      l1ChainId,
      chainId,
      l1AssetRouter,
      baseTokenAssetId,
      ntv.address,
      interopCenter.address,
      interopHandler.address,
      initOverrides
    )
  ).wait();

  log("  Initializing InteropCenter...");
  await (
    await interopCenter.initialize(
      l1ChainId,
      wallet.address,
      zkTokenAssetId,
      assetRouter.address,
      ntv.address,
      initOverrides
    )
  ).wait();

  log("  Initializing InteropHandler...");
  await (await interopHandler.initialize(l1ChainId, interopCenter.address, ntv.address, initOverrides)).wait();

  // Register destination chains if specified (for pre-v31 chains)
  if (opts.destinationChainIds && opts.destinationChainIds.length > 0) {
    log("  Registering destination chains...");
    for (const destChainId of opts.destinationChainIds) {
      if (destChainId === chainId) continue;
      await (await interopCenter.setDestinationBaseTokenAssetId(destChainId, baseTokenAssetId, initOverrides)).wait();
      log(`    Registered chain ${destChainId}`);
    }
  }

  log(`  Private interop stack deployed and initialized on chain ${chainId}`);

  return {
    assetTracker: assetTracker.address,
    ntv: ntv.address,
    assetRouter: assetRouter.address,
    interopCenter: interopCenter.address,
    interopHandler: interopHandler.address,
  };
}

/**
 * Cross-register remote router addresses between all deployed chains.
 * Must be called after all chains have been deployed.
 */
export async function registerRemoteRouters(
  chains: Array<{ chainId: number; rpcUrl: string }>,
  addresses: Record<number, PrivateInteropAddresses>,
  deployerKey: string,
  logger?: Logger,
  gasOverrides?: { gasPrice?: ethers.BigNumber; gasLimit?: number; type?: number }
): Promise<void> {
  const log = logger || console.log;
  for (const chain of chains) {
    const addrs = addresses[chain.chainId];
    if (!addrs) continue;
    const provider = new providers.JsonRpcProvider(chain.rpcUrl);
    const wallet = new Wallet(deployerKey, provider);
    const ar = new Contract(addrs.assetRouter, getAbi("PrivateL2AssetRouter"), wallet);
    for (const other of chains) {
      if (other.chainId === chain.chainId) continue;
      const otherAddrs = addresses[other.chainId];
      if (!otherAddrs) continue;
      const overrides = gasOverrides || {};
      await (await ar.setRemoteRouter(other.chainId, otherAddrs.assetRouter, overrides)).wait();
      log(`  chain ${chain.chainId}: registered remote router for chain ${other.chainId}`);
    }
  }
}
