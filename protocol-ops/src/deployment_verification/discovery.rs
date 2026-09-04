//! Walks a deployed ecosystem starting from nothing but the Bridgehub proxy.
//!
//! Everything else — the CTM, the bridge layer, the proxy admins, the
//! implementations behind every proxy — is read off chain rather than taken
//! from a deployment output file, so the verifier checks what is actually
//! live rather than what a run claimed to deploy.

use alloy::primitives::{Address, FixedBytes, U256};
use alloy::providers::Provider;
use anyhow::Context;

use crate::common::ethereum::AlloyProvider;
use crate::deployment_verification::contracts::{
    IAssetRouterView, IBeaconView, IBridgehubView, ICtmView, INativeTokenVaultView, INullifierView,
    IVerifierView,
};

/// EIP-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
pub const EIP1967_IMPLEMENTATION_SLOT: FixedBytes<32> = FixedBytes(alloy::hex!(
    "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
));
/// EIP-1967 admin slot: `keccak256("eip1967.proxy.admin") - 1`.
pub const EIP1967_ADMIN_SLOT: FixedBytes<32> = FixedBytes(alloy::hex!(
    "b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
));

/// Reads an address out of a raw storage slot.
pub async fn address_at_slot(
    provider: &AlloyProvider,
    address: Address,
    slot: FixedBytes<32>,
) -> anyhow::Result<Address> {
    let word = provider
        .get_storage_at(address, U256::from_be_bytes(slot.0))
        .await
        .with_context(|| format!("eth_getStorageAt({address}, {slot})"))?;
    Ok(Address::from_slice(&word.to_be_bytes::<32>()[12..]))
}

/// Runs an optional getter. A revert means "this contract does not expose it"
/// — which is information, not a failure (`Ownable` getters on contracts that
/// were never `Ownable`, `IS_TESTNET_VERIFIER` on the production verifier).
/// Transport failures still surface, because those would silently turn a
/// misconfiguration into a clean report.
pub async fn probe<T>(call: alloy::contract::Result<T>, what: &str) -> anyhow::Result<Option<T>> {
    match call {
        Ok(value) => Ok(Some(value)),
        Err(alloy::contract::Error::TransportError(alloy::transports::RpcError::ErrorResp(_))) => {
            Ok(None)
        }
        // `Ok(())`-shaped empty returndata also means "no such function here".
        Err(alloy::contract::Error::AbiError(_)) => Ok(None),
        Err(err) => Err(anyhow::anyhow!("{what}: {err}")),
    }
}

/// The bridgehub layer, as it is wired on chain.
#[derive(Debug, Clone)]
pub struct CoreAddresses {
    pub bridgehub: Address,
    pub governance: Address,
    pub chain_admin: Address,
    pub proxy_admin: Address,
    pub message_root: Address,
    pub chain_asset_handler: Address,
    pub ctm_deployment_tracker: Address,
    pub chain_registration_sender: Address,
    pub asset_router: Address,
    pub nullifier: Address,
    pub native_token_vault: Address,
    pub interop_handler: Address,
    pub bridged_token_beacon: Address,
    pub bridged_standard_erc20: Address,
    pub l1_chain_id: u64,
    pub max_number_of_zk_chains: U256,
    pub era_chain_id: U256,
    pub l1_weth: Address,
    pub eth_token_asset_id: FixedBytes<32>,
}

pub async fn discover_core(
    provider: &AlloyProvider,
    bridgehub: Address,
) -> anyhow::Result<CoreAddresses> {
    let bh = IBridgehubView::new(bridgehub, provider);

    let asset_router = bh
        .assetRouter()
        .call()
        .await
        .context("bridgehub.assetRouter()")?;
    anyhow::ensure!(
        asset_router != Address::ZERO,
        "bridgehub.assetRouter() is zero — `setAddresses` was never run, the ecosystem is not \
         wired and no chain can be created"
    );

    let ar = IAssetRouterView::new(asset_router, provider);
    let nullifier = ar
        .L1_NULLIFIER()
        .call()
        .await
        .context("assetRouter.L1_NULLIFIER()")?;
    let native_token_vault = ar
        .nativeTokenVault()
        .call()
        .await
        .context("assetRouter.nativeTokenVault()")?;
    let ntv = INativeTokenVaultView::new(native_token_vault, provider);
    let bridged_token_beacon = ntv
        .bridgedTokenBeacon()
        .call()
        .await
        .context("nativeTokenVault.bridgedTokenBeacon()")?;
    let bridged_standard_erc20 = IBeaconView::new(bridged_token_beacon, provider)
        .implementation()
        .call()
        .await
        .context("bridgedTokenBeacon.implementation()")?;

    Ok(CoreAddresses {
        bridgehub,
        governance: bh.owner().call().await.context("bridgehub.owner()")?,
        chain_admin: bh.admin().call().await.context("bridgehub.admin()")?,
        proxy_admin: address_at_slot(provider, bridgehub, EIP1967_ADMIN_SLOT).await?,
        message_root: bh
            .messageRoot()
            .call()
            .await
            .context("bridgehub.messageRoot()")?,
        chain_asset_handler: bh
            .chainAssetHandler()
            .call()
            .await
            .context("bridgehub.chainAssetHandler()")?,
        ctm_deployment_tracker: bh
            .l1CtmDeployer()
            .call()
            .await
            .context("bridgehub.l1CtmDeployer()")?,
        chain_registration_sender: bh
            .chainRegistrationSender()
            .call()
            .await
            .context("bridgehub.chainRegistrationSender()")?,
        asset_router,
        nullifier,
        native_token_vault,
        interop_handler: ar
            .l1InteropHandler()
            .call()
            .await
            .context("assetRouter.l1InteropHandler()")?,
        bridged_token_beacon,
        bridged_standard_erc20,
        l1_chain_id: bh
            .L1_CHAIN_ID()
            .call()
            .await
            .context("bridgehub.L1_CHAIN_ID()")?
            .to::<u64>(),
        max_number_of_zk_chains: bh
            .MAX_NUMBER_OF_ZK_CHAINS()
            .call()
            .await
            .context("bridgehub.MAX_NUMBER_OF_ZK_CHAINS()")?,
        era_chain_id: ar
            .ERA_CHAIN_ID()
            .call()
            .await
            .context("assetRouter.ERA_CHAIN_ID()")?,
        l1_weth: ar
            .L1_WETH_TOKEN()
            .call()
            .await
            .context("assetRouter.L1_WETH_TOKEN()")?,
        eth_token_asset_id: ar
            .ETH_TOKEN_ASSET_ID()
            .call()
            .await
            .context("assetRouter.ETH_TOKEN_ASSET_ID()")?,
    })
}

/// The chain-type-manager layer.
#[derive(Debug, Clone)]
pub struct CtmAddresses {
    pub ctm: Address,
    pub is_zksync_os: bool,
    pub protocol_version: U256,
    pub semver: (u32, u32, u32),
    pub genesis_upgrade: Address,
    pub default_upgrade: Address,
    pub server_notifier: Address,
    pub server_notifier_proxy_admin: Address,
    pub validator_timelock: Address,
    pub bytecodes_supplier: Address,
    pub permissionless_validator: Address,
    pub interop_center: Address,
    pub verifier: Address,
    pub plonk_verifier: Address,
    /// `true` when the deployed verifier exposes `IS_TESTNET_VERIFIER`.
    pub verifier_is_testnet: bool,
    pub verification_key_hash: FixedBytes<32>,
    pub stored_batch_zero: FixedBytes<32>,
    pub initial_cut_hash: FixedBytes<32>,
    pub initial_force_deployment_hash: FixedBytes<32>,
}

pub async fn discover_ctm(provider: &AlloyProvider, ctm: Address) -> anyhow::Result<CtmAddresses> {
    let c = ICtmView::new(ctm, provider);
    let protocol_version = c
        .protocolVersion()
        .call()
        .await
        .context("ctm.protocolVersion()")?;
    let semver = c
        .getSemverProtocolVersion()
        .call()
        .await
        .context("ctm.getSemverProtocolVersion()")?;
    let verifier = c
        .protocolVersionVerifier(protocol_version)
        .call()
        .await
        .context("ctm.protocolVersionVerifier()")?;
    anyhow::ensure!(
        verifier != Address::ZERO,
        "ctm.protocolVersionVerifier({protocol_version}) is zero — chains on this version cannot \
         prove"
    );

    let v = IVerifierView::new(verifier, provider);
    let verifier_is_testnet = probe(v.IS_TESTNET_VERIFIER().call().await, "verifier")
        .await?
        .unwrap_or(false);
    let plonk_verifier = v
        .PLONK_VERIFIER()
        .call()
        .await
        .context("verifier.PLONK_VERIFIER()")?;

    let server_notifier = c
        .serverNotifierAddress()
        .call()
        .await
        .context("ctm.serverNotifierAddress()")?;

    Ok(CtmAddresses {
        ctm,
        is_zksync_os: c.isZKsyncOS().call().await.context("ctm.isZKsyncOS()")?,
        protocol_version,
        semver: (semver._0, semver._1, semver._2),
        genesis_upgrade: c
            .l1GenesisUpgrade()
            .call()
            .await
            .context("ctm.l1GenesisUpgrade()")?,
        default_upgrade: c
            .defaultUpgrade()
            .call()
            .await
            .context("ctm.defaultUpgrade()")?,
        server_notifier,
        server_notifier_proxy_admin: address_at_slot(provider, server_notifier, EIP1967_ADMIN_SLOT)
            .await?,
        validator_timelock: c
            .validatorTimelockPostV29()
            .call()
            .await
            .context("ctm.validatorTimelockPostV29()")?,
        bytecodes_supplier: c
            .L1_BYTECODES_SUPPLIER()
            .call()
            .await
            .context("ctm.L1_BYTECODES_SUPPLIER()")?,
        permissionless_validator: c
            .PERMISSIONLESS_VALIDATOR()
            .call()
            .await
            .context("ctm.PERMISSIONLESS_VALIDATOR()")?,
        interop_center: c
            .INTEROP_CENTER()
            .call()
            .await
            .context("ctm.INTEROP_CENTER()")?,
        verifier,
        plonk_verifier,
        verifier_is_testnet,
        verification_key_hash: IVerifierView::new(plonk_verifier, provider)
            .verificationKeyHash()
            .call()
            .await
            .context("plonkVerifier.verificationKeyHash()")?,
        stored_batch_zero: c
            .storedBatchZero()
            .call()
            .await
            .context("ctm.storedBatchZero()")?,
        initial_cut_hash: c
            .initialCutHash()
            .call()
            .await
            .context("ctm.initialCutHash()")?,
        initial_force_deployment_hash: c
            .initialForceDeploymentHash()
            .call()
            .await
            .context("ctm.initialForceDeploymentHash()")?,
    })
}

/// Reads the wiring the bridge layer sets on itself, so a missing
/// `setL1AssetRouter` / `setL1NativeTokenVault` / `setL1InteropHandler` shows
/// up as a mismatch rather than as a runtime revert months later.
pub struct BridgeWiring {
    pub nullifier_asset_router: Address,
    pub nullifier_native_token_vault: Address,
    pub nullifier_interop_handler: Address,
    pub ntv_weth: Address,
}

pub async fn read_bridge_wiring(
    provider: &AlloyProvider,
    core: &CoreAddresses,
) -> anyhow::Result<BridgeWiring> {
    let nullifier = INullifierView::new(core.nullifier, provider);
    let ntv = INativeTokenVaultView::new(core.native_token_vault, provider);
    Ok(BridgeWiring {
        nullifier_asset_router: nullifier
            .l1AssetRouter()
            .call()
            .await
            .context("nullifier.l1AssetRouter()")?,
        nullifier_native_token_vault: nullifier
            .l1NativeTokenVault()
            .call()
            .await
            .context("nullifier.l1NativeTokenVault()")?,
        nullifier_interop_handler: nullifier
            .l1InteropHandler()
            .call()
            .await
            .context("nullifier.l1InteropHandler()")?,
        ntv_weth: ntv.WETH_TOKEN().call().await.context("ntv.WETH_TOKEN()")?,
    })
}
