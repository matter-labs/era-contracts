use anyhow::Result;

use crate::upgrade_verification::{
    artifacts::{required_address_in_value as required_address, EcosystemUpgradeArtifact},
    constants::EIP1967_PROXY_ADMIN_SLOT,
    verifiers::{VerificationResult, Verifiers},
    versions::v31::utils::network_verifier::{
        Bridgehub as BridgehubContract, ChainTypeManager, L1AssetRouter, Ownable,
    },
};

use alloy::{
    hex::FromHex,
    primitives::{Address, FixedBytes, U256},
    providers::Provider,
};

const CREATE2_FACTORY_CONTRACT_NAME: &str = "Create2Factory";

/// Core proxies whose EIP-1967 admin slot must match the ecosystem
/// `transparent_proxy_admin`.
/// These are the proxies that the v31 governance stage 1 calls upgrade.
const CORE_PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN: &[&str] = &[
    "bridgehub_proxy",
    "l1_nullifier_proxy",
    "l1_asset_router_proxy",
    "native_token_vault",
    "message_root_proxy",
    "ctm_deployment_tracker_proxy",
    "chain_asset_handler_proxy",
    "asset_tracker_proxy",
];

/// Phase 5 RPC state checks (see `puvt-what-to-do.md`).
///
/// This is intentionally the *non-overlapping* slice of legacy PUVT's
/// post-deploy work — it covers checks that aren't subsumed by Phase 6
/// (deployment provenance):
/// - The L1 RPC chain id (sanity).
/// - Runtime bytecode at the configured Create2Factory address.
/// - Runtime bytecode at the ecosystem `transparent_proxy_admin` address.
/// - EIP-1967 proxy-admin slot for every v31 stage-1 proxy → must equal the
///   ecosystem `transparent_proxy_admin`.
/// - Pre-upgrade AssetRouter → NTV wiring when the getter exists on the live
///   proxy.
///
/// Per-implementation deployed-bytecode and constructor-arg checks live in
/// deployment provenance: they use init bytecode + constructor args (via
/// `expect_create2_params`), which handles Solidity `immutable` substitution
/// correctly. The flat-table runtime-hash check previously here was strictly
/// weaker and produced misleading errors for every contract with immutables;
/// Phase 6 supersedes it.
///
/// Bytecode-supplier `publishingBlock` checks for the L2 upgrade tx
/// `factoryDeps` are restored separately inside
/// `set_new_version_upgrade::verify_factory_deps` so they sit alongside the
/// rest of the L2 upgrade tx checks.
pub(crate) async fn verify_v31_artifact_state(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    create2_factory: Address,
    result: &mut VerificationResult,
) -> Result<()> {
    result.print_info("== RPC state checks ==");

    verify_l1_chain_id(verifiers, result).await;
    result
        .expect_deployed_bytecode(verifiers, &create2_factory, CREATE2_FACTORY_CONTRACT_NAME)
        .await;
    verify_v31_proxy_admins(artifact, verifiers, result).await?;
    verify_v31_core_wiring(verifiers, result).await;
    verify_v31_timer_admin_state(artifact, verifiers, result).await?;
    verify_v31_ctm_permissionless_validator(artifact, verifiers, result).await?;

    Ok(())
}

async fn verify_l1_chain_id(verifiers: &Verifiers, result: &mut VerificationResult) {
    match verifiers.network_verifier.try_get_l1_chain_id().await {
        Ok(chain_id) => result.report_ok(&format!("L1 RPC chain id: {chain_id}")),
        Err(err) => result.report_error(&format!("Failed to fetch L1 RPC chain id: {err}")),
    }
}

async fn verify_v31_proxy_admins(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let expected_core_admin = required_address(
        &artifact.core,
        "core",
        &["upgrade_addresses", "shared", "transparent_proxy_admin"],
    )?;

    result
        .expect_deployed_bytecode(verifiers, &expected_core_admin, "TransparentProxyAdmin")
        .await;

    let admin_slot = match FixedBytes::<32>::from_hex(EIP1967_PROXY_ADMIN_SLOT) {
        Ok(slot) => slot,
        Err(err) => {
            result.report_error(&format!("Invalid EIP-1967 admin slot literal: {err}"));
            return Ok(());
        }
    };

    let provider = verifiers.network_verifier.get_l1_provider();
    for proxy_name in CORE_PROXIES_UNDER_TRANSPARENT_PROXY_ADMIN {
        let Some(proxy_addr) = verifiers.address_verifier.name_to_address.get(*proxy_name) else {
            result.report_warn(&format!(
                "Skipping proxy-admin check for {proxy_name}: address not present in artifact"
            ));
            continue;
        };
        let raw = match provider
            .get_storage_at(*proxy_addr, U256::from_be_bytes(admin_slot.0))
            .await
        {
            Ok(value) => value.to_be_bytes::<32>(),
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping proxy-admin check for {proxy_name}; eth_getStorageAt failed: {err}"
                ));
                continue;
            }
        };
        let actual_admin = Address::from_slice(&raw[12..]);
        if actual_admin == expected_core_admin {
            result.report_ok(&format!(
                "Proxy admin for {proxy_name} matches transparent_proxy_admin"
            ));
        } else {
            result.report_error(&format!(
                "Proxy admin mismatch for {proxy_name}: expected {expected_core_admin}, got {actual_admin}"
            ));
        }
    }

    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let expected_admin = required_address(
            &ctm.value,
            &scope,
            &["deployed_addresses", "transparent_proxy_admin"],
        )?;
        let proxy_addr = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;

        let raw = match provider
            .get_storage_at(proxy_addr, U256::from_be_bytes(admin_slot.0))
            .await
        {
            Ok(value) => value.to_be_bytes::<32>(),
            Err(err) => {
                result.report_warn(&format!(
                    "Skipping proxy-admin check for {label}.chain_type_manager_proxy; eth_getStorageAt failed: {err}"
                ));
                continue;
            }
        };
        let actual_admin = Address::from_slice(&raw[12..]);
        if actual_admin == expected_admin {
            result.report_ok(&format!(
                "Proxy admin for {label}.chain_type_manager_proxy matches {label}.transparent_proxy_admin"
            ));
        } else {
            result.report_error(&format!(
                "Proxy admin mismatch for {label}.chain_type_manager_proxy: expected {expected_admin}, got {actual_admin}"
            ));
        }
    }

    Ok(())
}

async fn verify_v31_core_wiring(verifiers: &Verifiers, result: &mut VerificationResult) {
    let provider = verifiers.network_verifier.get_l1_provider();

    if let (Some(asset_router_proxy), Some(expected_ntv)) = (
        verifiers
            .address_verifier
            .name_to_address
            .get("l1_asset_router_proxy"),
        verifiers
            .address_verifier
            .name_to_address
            .get("native_token_vault"),
    ) {
        let asset_router = L1AssetRouter::new(*asset_router_proxy, provider.clone());
        match asset_router.nativeTokenVault().call().await {
            Ok(actual) if actual == *expected_ntv => {
                result.report_ok("L1AssetRouter.nativeTokenVault() points at native_token_vault")
            }
            Ok(actual) => result.report_error(&format!(
                "L1AssetRouter.nativeTokenVault() mismatch: expected {expected_ntv}, got {actual}"
            )),
            Err(err) => result.report_warn(&format!(
                "Skipping L1AssetRouter.nativeTokenVault() check; call failed: {err}"
            )),
        }
    }

    if let Some(expected_tracker) = verifiers
        .address_verifier
        .name_to_address
        .get("asset_tracker_proxy")
    {
        // Stage 1 accepts the AssetTracker ownership transfer; record the
        // current owner for context (ownership end-state validation requires
        // governance address knowledge added later in Phase 6).
        let tracker = Ownable::new(*expected_tracker, provider.clone());
        match tracker.owner().call().await {
            Ok(owner) => result.report_ok(&format!("AssetTracker owner: {owner}")),
            Err(err) => result.report_warn(&format!(
                "Skipping AssetTracker.owner() check; call failed: {err}"
            )),
        }
    }
}

/// Sanity-check the live ownership state that should match the timer
/// constructor addresses recorded under `[ctms.<flavor>.admin]`.
///
/// `CtmArtifact.value` is the raw `[ctms.<flavor>]` TOML table, so these
/// fields do not need a dedicated typed artifact struct to be loadable.
async fn verify_v31_timer_admin_state(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    let bridgehub = BridgehubContract::new(verifiers.bridgehub_address, provider.clone());
    let bridgehub_owner = match bridgehub.owner().call().await {
        Ok(owner) => Some(owner),
        Err(err) => {
            result.report_error(&format!(
                "Failed to call Bridgehub.owner() for GovernanceUpgradeTimer admin checks: {err}"
            ));
            None
        }
    };

    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let expected_timer_governance =
            required_address(&ctm.value, &scope, &["admin", "timer_governance_addr"])?;
        let expected_ecosystem_admin =
            required_address(&ctm.value, &scope, &["admin", "ecosystem_admin_addr"])?;

        if let Some(actual_timer_governance) = bridgehub_owner {
            if actual_timer_governance == expected_timer_governance {
                result.report_ok(&format!(
                    "{label}.admin.timer_governance_addr matches Bridgehub.owner()"
                ));
            } else {
                result.report_error(&format!(
                    "{label}.admin.timer_governance_addr mismatch: artifact {expected_timer_governance}, Bridgehub.owner() {actual_timer_governance}"
                ));
            }
        }

        let ctm_proxy = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_proxy"],
        )?;
        let ctm_owner = ChainTypeManager::new(ctm_proxy, provider.clone())
            .owner()
            .call()
            .await;
        match ctm_owner {
            Ok(actual_ecosystem_admin) if actual_ecosystem_admin == expected_ecosystem_admin => {
                result.report_ok(&format!(
                    "{label}.admin.ecosystem_admin_addr matches chain_type_manager_proxy.owner()"
                ));
            }
            Ok(actual_ecosystem_admin) => result.report_error(&format!(
                "{label}.admin.ecosystem_admin_addr mismatch: artifact {expected_ecosystem_admin}, chain_type_manager_proxy.owner() {actual_ecosystem_admin}"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.chain_type_manager_proxy.owner() for GovernanceUpgradeTimer admin checks: {err}"
            )),
        }
    }

    Ok(())
}

async fn verify_v31_ctm_permissionless_validator(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> Result<()> {
    let provider = verifiers.network_verifier.get_l1_provider();
    for ctm in &artifact.ctms {
        let label = ctm.flavor.label();
        let scope = format!("ctms.{label}");
        let ctm_impl = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "chain_type_manager_implementation_addr"],
        )?;
        let expected_permissionless_validator = required_address(
            &ctm.value,
            &scope,
            &["state_transition", "permissionless_validator_addr"],
        )?;

        if expected_permissionless_validator == Address::ZERO {
            result.report_error(&format!(
                "{label}.permissionless_validator_addr is address(0); v31 CTM implementations must be constructed with a PermissionlessValidator proxy"
            ));
            continue;
        }

        let ctm_view = ChainTypeManager::new(ctm_impl, provider.clone());
        match ctm_view.PERMISSIONLESS_VALIDATOR().call().await {
            Ok(actual) if actual == expected_permissionless_validator => result.report_ok(&format!(
                "{label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR() matches permissionless_validator_addr"
            )),
            Ok(actual) => result.report_error(&format!(
                "{label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR() mismatch: expected {expected_permissionless_validator}, got {actual}"
            )),
            Err(err) => result.report_error(&format!(
                "Failed to call {label}.chain_type_manager_implementation PERMISSIONLESS_VALIDATOR(): {err}"
            )),
        }
    }
    Ok(())
}
