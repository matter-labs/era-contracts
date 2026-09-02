import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { ANVIL_BALANCE, BUNDLE_TARGET_TOKEN_FUNDING } from "./constants";
import { optionalTomlString, readJson, readToml } from "./file-system";
import type { BundleManifest } from "./types";

export interface FundBundleTargetsOptions {
  bridgehubAddress: string;
  zkAssetId: string;
  hasGateway: boolean;
  manifestPath: string;
  ecosystemTomlPath: string;
  deployerAddress: string;
}

export async function fundBundleTargets(
  provider: ethers.providers.JsonRpcProvider,
  options: FundBundleTargetsOptions
): Promise<void> {
  const bridgehub = new ethers.Contract(options.bridgehubAddress, getAbi("L1Bridgehub"), provider);
  const assetRouterAddress = ethers.utils.getAddress(await bridgehub.assetRouter());
  const assetRouter = new ethers.Contract(assetRouterAddress, getAbi("L1AssetRouter"), provider);
  const nativeTokenVaultAddress = ethers.utils.getAddress(await assetRouter.nativeTokenVault());
  const nativeTokenVault = new ethers.Contract(nativeTokenVaultAddress, getAbi("L1NativeTokenVault"), provider);
  const zkTokenAddress = ethers.utils.getAddress(await nativeTokenVault.tokenAddress(options.zkAssetId));

  console.log(`Asset router:      ${assetRouterAddress}`);
  console.log(`Native token vault: ${nativeTokenVaultAddress}`);
  console.log(`ZK token:           ${zkTokenAddress}`);
  await provider.send("anvil_setBalance", [nativeTokenVaultAddress, ANVIL_BALANCE.toHexString()]);

  const manifest = readJson<BundleManifest>(options.manifestPath);
  const targets = [...new Set(manifest.bundles.map((bundle) => ethers.utils.getAddress(bundle.target).toLowerCase()))]
    .sort()
    .map((address) => ethers.utils.getAddress(address));
  console.log(`Bundle targets:\n${targets.map((target) => `  ${target}`).join("\n")}`);
  const zkToken = new ethers.Contract(
    zkTokenAddress,
    getAbi("BridgedStandardERC20"),
    provider.getSigner(nativeTokenVaultAddress)
  );
  for (const target of targets) {
    await provider.send("anvil_setBalance", [target, ANVIL_BALANCE.toHexString()]);
    console.log(
      `  bridgeMint(${target}, ${BUNDLE_TARGET_TOKEN_FUNDING.toString()})${options.hasGateway ? "" : " [best-effort]"}`
    );
    try {
      await (await zkToken.bridgeMint(target, BUNDLE_TARGET_TOKEN_FUNDING)).wait();
    } catch (error) {
      if (options.hasGateway) throw error;
    }
  }

  const ecosystem = readToml(options.ecosystemTomlPath);
  const assetTrackerAddress = optionalTomlString(ecosystem, "asset_tracker_proxy_addr");
  if (!assetTrackerAddress) {
    console.warn(
      `  WARNING: asset_tracker_proxy_addr not found in ${options.ecosystemTomlPath} — skipping registerLegacyToken`
    );
    return;
  }
  const assetTracker = new ethers.Contract(
    ethers.utils.getAddress(assetTrackerAddress),
    getAbi("L1AssetTracker"),
    provider.getSigner(ethers.utils.getAddress(options.deployerAddress))
  );
  console.log(`  registerLegacyToken(${options.zkAssetId}) on ${assetTracker.address}`);
  try {
    await (await assetTracker.registerLegacyToken(options.zkAssetId)).wait();
  } catch {
    // The setup is intentionally idempotent: registration may already exist.
  }
}
