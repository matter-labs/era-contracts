import { ContractFactory, Contract, providers, Wallet, ethers } from "ethers";
import {
  getAbi,
  getCreationBytecode,
} from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  INTEROP_CENTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";

// Dedicated deployer key for private interop contracts.
// Using a separate wallet (Anvil account #9) ensures the same nonce (0) on all chains,
// which gives deterministic addresses — required because initiateIndirectCall returns
// address(this) as the target l2Contract.
const PRIVATE_DEPLOYER_KEY = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

export interface PrivateInteropAddresses {
  assetTracker: string;
  ntv: string;
  assetRouter: string;
  interopCenter: string;
  interopHandler: string;
}

type Logger = (line: string) => void;

/**
 * Deploy the full private interop stack on a given chain.
 * Order: AssetTracker -> NTV -> AssetRouter -> InteropCenter -> InteropHandler
 */
export async function deployPrivateInteropStack(
  rpcUrl: string,
  chainId: number,
  l1ChainId: number,
  logger?: Logger
): Promise<PrivateInteropAddresses> {
  const log = logger || console.log;
  const provider = new providers.JsonRpcProvider(rpcUrl);
  const mainWallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
  const deployerWallet = new Wallet(PRIVATE_DEPLOYER_KEY, provider);

  // Fund the deployer wallet (Anvil account #9 may not have ETH on L2 chains)
  const deployerBalance = await provider.getBalance(deployerWallet.address);
  if (deployerBalance.lt(ethers.utils.parseEther("1"))) {
    const fundTx = await mainWallet.sendTransaction({
      to: deployerWallet.address,
      value: ethers.utils.parseEther("10"),
    });
    await fundTx.wait();
  }

  // Use deployerWallet for deployments (deterministic nonce = 0 on all chains)
  const wallet = deployerWallet;

  // Read system contract state for initialization params
  const systemNtv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), provider);
  const baseTokenAssetId = await systemNtv.BASE_TOKEN_ASSET_ID();
  const wethToken = await systemNtv.WETH_TOKEN();
  const l2TokenProxyBytecodeHash = await systemNtv.L2_TOKEN_PROXY_BYTECODE_HASH();
  const bridgedTokenBeacon = await systemNtv.bridgedTokenBeacon();
  const baseTokenOriginToken = await systemNtv.BASE_TOKEN_ORIGIN_TOKEN();
  const baseTokenName = await systemNtv.BASE_TOKEN_NAME();
  const baseTokenSymbol = await systemNtv.BASE_TOKEN_SYMBOL();
  const baseTokenDecimals = await systemNtv.BASE_TOKEN_DECIMALS();

  const systemInteropCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  const zkTokenAssetId = await systemInteropCenter.ZK_TOKEN_ASSET_ID();

  const eraChainId = chainId; // Use chain's own ID as era chain ID

  // Read l1AssetRouter from L2AssetRouter
  const systemAssetRouter = new Contract(
    "0x0000000000000000000000000000000000010003",
    getAbi("L2AssetRouter"),
    provider
  );
  const l1AssetRouter = await systemAssetRouter.L1_ASSET_ROUTER();

  // Get origin chain ID for base token bridging data
  const baseTokenOriginChainId = await systemNtv.originChainId(baseTokenAssetId);

  log(`  Deploying PrivateL2AssetTracker...`);
  const assetTrackerFactory = new ContractFactory(
    getAbi("PrivateL2AssetTracker"),
    getCreationBytecode("PrivateL2AssetTracker"),
    wallet
  );
  // Deploy with a placeholder NTV address (will be updated)
  const assetTracker = await assetTrackerFactory.deploy();
  await assetTracker.deployed();
  log(`    AssetTracker: ${assetTracker.address}`);

  log(`  Deploying PrivateL2NativeTokenVault...`);
  const ntvFactory = new ContractFactory(
    getAbi("PrivateL2NativeTokenVault"),
    getCreationBytecode("PrivateL2NativeTokenVault"),
    wallet
  );
  const ntv = await ntvFactory.deploy();
  await ntv.deployed();
  log(`    NTV: ${ntv.address}`);

  log(`  Deploying PrivateL2AssetRouter...`);
  const assetRouterFactory = new ContractFactory(
    getAbi("PrivateL2AssetRouter"),
    getCreationBytecode("PrivateL2AssetRouter"),
    wallet
  );
  const assetRouter = await assetRouterFactory.deploy();
  await assetRouter.deployed();
  log(`    AssetRouter: ${assetRouter.address}`);

  log(`  Deploying PrivateInteropCenter...`);
  const interopCenterFactory = new ContractFactory(
    getAbi("PrivateInteropCenter"),
    getCreationBytecode("PrivateInteropCenter"),
    wallet
  );
  const interopCenter = await interopCenterFactory.deploy();
  await interopCenter.deployed();
  log(`    InteropCenter: ${interopCenter.address}`);

  log(`  Deploying PrivateInteropHandler...`);
  const interopHandlerFactory = new ContractFactory(
    getAbi("PrivateInteropHandler"),
    getCreationBytecode("PrivateInteropHandler"),
    wallet
  );
  const interopHandler = await interopHandlerFactory.deploy();
  await interopHandler.deployed();
  log(`    InteropHandler: ${interopHandler.address}`);

  // Initialize contracts in order
  log(`  Initializing AssetTracker...`);
  const initAssetTrackerTx = await assetTracker.initialize(
    l1ChainId,
    baseTokenAssetId,
    ntv.address
  );
  await initAssetTrackerTx.wait();

  log(`  Initializing NTV...`);
  const baseTokenBridgingData = {
    assetId: baseTokenAssetId,
    originChainId: baseTokenOriginChainId,
    originToken: baseTokenOriginToken,
  };
  const baseTokenMetadata = {
    name: baseTokenName,
    symbol: baseTokenSymbol,
    decimals: baseTokenDecimals,
  };
  const initNtvTx = await ntv.initialize(
    l1ChainId,
    assetRouter.address,
    assetTracker.address,
    bridgedTokenBeacon,
    l2TokenProxyBytecodeHash,
    wethToken,
    baseTokenBridgingData,
    baseTokenMetadata
  );
  await initNtvTx.wait();

  log(`  Initializing AssetRouter...`);
  const initAssetRouterTx = await assetRouter.initialize(
    l1ChainId,
    eraChainId,
    l1AssetRouter,
    baseTokenAssetId,
    ntv.address,
    interopCenter.address,
    interopHandler.address
  );
  await initAssetRouterTx.wait();

  log(`  Initializing InteropCenter...`);
  const initInteropCenterTx = await interopCenter.initialize(
    l1ChainId,
    wallet.address,
    zkTokenAssetId,
    assetRouter.address,
    ntv.address
  );
  await initInteropCenterTx.wait();

  log(`  Initializing InteropHandler...`);
  const initInteropHandlerTx = await interopHandler.initialize(
    l1ChainId,
    interopCenter.address,
    ntv.address
  );
  await initInteropHandlerTx.wait();

  log(`  Private interop stack deployed and initialized on chain ${chainId}`);

  return {
    assetTracker: assetTracker.address,
    ntv: ntv.address,
    assetRouter: assetRouter.address,
    interopCenter: interopCenter.address,
    interopHandler: interopHandler.address,
  };
}
