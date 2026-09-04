//! Stage 1 — the main upgrade ceremony.
//!
//! Call layout, mirroring `DefaultCoreUpgrade.prepareStage1GovernanceCalls`
//! followed by one `DefaultCTMUpgrade.prepareStage1GovernanceCalls` block per
//! `[ctms.<flavor>]` entry, in artifact order:
//!
//!   core   0        `chain_asset_handler_proxy.pauseMigration()`
//!   core   1..=8    `transparent_proxy_admin.upgrade(<8 core proxies>)`
//!   core   9..=10   `setL1InteropHandler` on the nullifier and asset router —
//!                   emitted only when this run deployed the handler, so the
//!                   pair is present iff the artifact's
//!                   `l1_interop_handler_proxy_addr` is in this upgrade's
//!                   CREATE2 deployments.
//!   per-CTM +0..=+8 see [`STAGE1_PER_CTM_LEN`].
//!
//! The leading `pauseMigration()` is unconditional in v33: it re-asserts the
//! stage-0 pause that `PUH.executeEmergencyUpgrade` clears on the emergency
//! path, and is a harmless no-op on the ordinary governance path.
//!
//! Two passes:
//! - [`verify_call_shape`] — every call's `(target, selector, value=0)`.
//! - [`verify_artifact_payloads`] — decodes each call's payload and checks
//!   it against the artifact (proxy/impl pairs, `setChainCreationParams`
//!   fields + facet decomp, `setNewVersionUpgrade` deep payload via the
//!   `set_new_version_upgrade` module).

use alloy::{
    hex,
    primitives::U256,
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::{
    super::expected_old_protocol_version_label, super::get_expected_new_protocol_version,
    super::is_expected_old_protocol_version_for_ctm_flavor,
};
use super::super::{
    fixed_force_deployment::FixedForceDeploymentsData,
    initialize_data_new_chain::InitializeDataNewChain, protocol_version::ProtocolVersion,
    set_new_version_upgrade,
};
use super::facets::{
    verify_default_upgrade_payload, verify_v33_chain_creation_facet_cuts,
    verify_v33_upgrade_facet_cuts,
};
use super::helpers::{
    expect_address_equal, expect_hex_equal, expect_named_address, protocol_label,
    required_ctm_address, verify_call_by_address, verify_call_by_name,
};
use super::{
    setChainCreationParamsCall, setDefaultUpgradeCall, setL1InteropHandlerCall, upgradeCall,
    CallList, GovernanceStage1Calls,
};

/// `pauseMigration()` + the eight core proxy upgrades. Always present.
const STAGE1_CORE_PREFIX_LEN: usize = 9;
/// The `setL1InteropHandler` pair, present only when this run deployed the
/// handler — see [`interop_handler_wiring_len`].
const STAGE1_INTEROP_WIRING_LEN: usize = 2;

/// Offsets within one per-CTM block, mirroring the `allCalls` assembly in
/// `DefaultCTMUpgrade.prepareStage1GovernanceCalls`. `prepareDAValidatorCall`
/// sits between `setNewVersionUpgrade` and the version-specific tail but is
/// empty in v33, and the v33 CTM script adds no version-specific stage-1
/// calls, so neither contributes an offset here.
const PER_CTM_OFFSET_CHECK_DEADLINE: usize = 0;
const PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED: usize = 1;
const PER_CTM_OFFSET_UPGRADE_CTM: usize = 2;
const PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK: usize = 3;
const PER_CTM_OFFSET_UPGRADE_BYTECODES_SUPPLIER: usize = 4;
const PER_CTM_OFFSET_UPGRADE_PERMISSIONLESS_VALIDATOR: usize = 5;
const PER_CTM_OFFSET_SET_DEFAULT_UPGRADE: usize = 6;
const PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS: usize = 7;
const PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE: usize = 8;
const STAGE1_PER_CTM_LEN: usize = 9;

fn ctm_block_start(ctm_index: usize, core_len: usize) -> usize {
    core_len + ctm_index * STAGE1_PER_CTM_LEN
}

/// `CoreUpgrade_v33.prepareVersionSpecificStage1GovernanceCallsL1` emits the
/// two `setL1InteropHandler` calls only when the run deployed the handler
/// itself. Rather than trust the call list to say so, decide from this
/// upgrade's own CREATE2 deployments: a handler proxy that was deployed here
/// must be wired here.
fn interop_handler_wiring_len(artifact: &EcosystemUpgradeArtifact, verifiers: &Verifiers) -> usize {
    let deployed_here = optional_core_address(
        artifact,
        &[
            "upgrade_addresses",
            "bridges",
            "l1_interop_handler_proxy_addr",
        ],
    )
    .is_some_and(|addr| {
        verifiers
            .network_verifier
            .create2_known_bytecodes
            .contains_key(&addr)
    });
    if deployed_here {
        STAGE1_INTEROP_WIRING_LEN
    } else {
        0
    }
}

fn optional_core_address(
    artifact: &EcosystemUpgradeArtifact,
    path: &[&str],
) -> Option<alloy::primitives::Address> {
    let mut current = &artifact.core;
    for segment in path {
        current = current.get(*segment)?;
    }
    current.as_str()?.parse().ok()
}

impl GovernanceStage1Calls {
    /// Stage 1 — proxy impl swaps for the 7 core contracts (incl. MessageRoot
    /// reinit), ChainRegistrationSender ownership handoff, ChainAssetHandler
    /// address refresh, then per-CTM: timer checkDeadline, migrations-paused
    /// sanity, CTM impl swap, `setChainCreationParams`, `setNewVersionUpgrade`,
    /// VT impl swap.
    ///
    /// Split into two passes: `verify_call_shape` checks target+selector for
    /// every call; `verify_artifact_payloads` decodes args and cross-checks
    /// against the artifact's declared addresses and structs.
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        self.verify_call_shape(artifact, verifiers, result).await?;
        self.verify_artifact_payloads(artifact, verifiers, result)
            .await
    }

    async fn verify_call_shape(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 calls ===");

        let ctms = &artifact.ctms;
        let wiring_len = interop_handler_wiring_len(artifact, verifiers);
        let core_len = STAGE1_CORE_PREFIX_LEN + wiring_len;
        let mut errors = 0;

        // Re-assert the stage-0 migration pause. `PUH.executeEmergencyUpgrade`
        // unpauses migrations as a built-in pre-step, which would make the
        // per-CTM `checkMigrationsPaused()` revert; on the ordinary governance
        // path this simply re-applies a pause that is already in place.
        let mut shape: Vec<(&str, &str)> = vec![("chain_asset_handler_proxy", "pauseMigration()")];
        // The eight core proxy impl swaps, in `prepareUpgradeProxiesCalls`
        // order: Bridgehub, L1Nullifier, L1AssetRouter, L1NativeTokenVault,
        // L1MessageRoot, CTMDeploymentTracker, L1ChainAssetHandler,
        // ChainRegistrationSender. L1MessageRoot is a plain `upgrade` in v33 —
        // the v31 `initializeL1V31Upgrade` reinitializer was removed once every
        // ecosystem had consumed it.
        shape.extend(std::iter::repeat_n(
            ("transparent_proxy_admin", "upgrade(address,address)"),
            8,
        ));
        if wiring_len > 0 {
            shape.push(("l1_nullifier_proxy", "setL1InteropHandler(address)"));
            shape.push(("l1_asset_router_proxy", "setL1InteropHandler(address)"));
        }
        for (index, (target, method)) in shape.into_iter().enumerate() {
            errors += verify_call_by_name(&self.calls, index, target, method, verifiers, result);
        }

        // Per-CTM block (6 calls per CTM, in artifact order):
        //   +0 timer.checkDeadline()
        //   +1 stage-validator.checkMigrationsPaused()
        //   +2 CTM proxy admin.upgrade(CTM proxy, new impl)
        //   +3 CTM proxy.setChainCreationParams(...)
        //   +4 CTM proxy.setNewVersionUpgrade(...)
        //   +5 VT proxy admin.upgrade(VT proxy, new impl)
        for (ctm_index, ctm) in ctms.iter().enumerate() {
            let block = ctm_block_start(ctm_index, core_len);
            let timer_label = format!("{}.upgrade_timer", ctm.flavor.label());
            let validator_label = format!("{}.upgrade_stage_validator", ctm.flavor.label());
            let ctm_proxy_label = format!("{}.chain_type_manager_proxy", ctm.flavor.label());

            if let Some(timer) = required_ctm_address(
                ctm,
                &["deployed_addresses", "l1_governance_upgrade_timer"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_CHECK_DEADLINE,
                    timer,
                    &timer_label,
                    "checkDeadline()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }
            if let Some(validator) = required_ctm_address(
                ctm,
                &["deployed_addresses", "upgrade_stage_validator"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED,
                    validator,
                    &validator_label,
                    "checkMigrationsPaused()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }

            if let Some(ctm_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_proxy"],
                result,
            ) {
                let ctm_proxy_admin = verifiers.network_verifier.get_proxy_admin(ctm_proxy).await;
                let ctm_proxy_admin_label =
                    format!("{}.chain_type_manager_proxy_admin", ctm.flavor.label());
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_UPGRADE_CTM,
                    ctm_proxy_admin,
                    &ctm_proxy_admin_label,
                    "upgrade(address,address)",
                    verifiers,
                    result,
                );
                // Must follow the CTM impl swap: `setDefaultUpgrade` only
                // exists on the new implementation.
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_SET_DEFAULT_UPGRADE,
                    ctm_proxy,
                    &ctm_proxy_label,
                    "setDefaultUpgrade(address)",
                    verifiers,
                    result,
                );
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS,
                    ctm_proxy,
                    &ctm_proxy_label,
                    "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))",
                    verifiers,
                    result,
                );
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE,
                    ctm_proxy,
                    &ctm_proxy_label,
                    "setNewVersionUpgrade(((address,uint8,bool,bytes4[])[],address,bytes),uint256,uint256,uint256,address)",
                    verifiers,
                    result,
                );
            } else {
                errors += 4;
            }

            // v33 swaps the per-CTM ValidatorTimelock implementation in-place
            // (the impl gains UPGRADER_ROLE + upgradeChainFromVersion). The
            // governance call routes through the same TUPP ProxyAdmin the
            // CTM proxy uses (they share a transparent proxy admin per CTM).
            // The three proxies v33 keeps rather than redeploys. Each has its
            // own ProxyAdmin instance, so resolve the admin per proxy instead
            // of assuming the CTM-wide one (`_buildProxyUpgrade`).
            for (offset, field, label_suffix) in [
                (
                    PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK,
                    "validator_timelock_addr",
                    "validator_timelock_proxy_admin",
                ),
                (
                    PER_CTM_OFFSET_UPGRADE_BYTECODES_SUPPLIER,
                    "bytecodes_supplier_addr",
                    "bytecodes_supplier_proxy_admin",
                ),
                (
                    PER_CTM_OFFSET_UPGRADE_PERMISSIONLESS_VALIDATOR,
                    "permissionless_validator_addr",
                    "permissionless_validator_proxy_admin",
                ),
            ] {
                if let Some(proxy) = required_ctm_address(ctm, &["state_transition", field], result)
                {
                    let proxy_admin = verifiers.network_verifier.get_proxy_admin(proxy).await;
                    let label = format!("{}.{}", ctm.flavor.label(), label_suffix);
                    errors += verify_call_by_address(
                        &self.calls,
                        block + offset,
                        proxy_admin,
                        &label,
                        "upgrade(address,address)",
                        verifiers,
                        result,
                    );
                } else {
                    errors += 1;
                }
            }
        }

        let expected_call_count = core_len + ctms.len() * STAGE1_PER_CTM_LEN;
        match self.calls.elems.len().cmp(&expected_call_count) {
            std::cmp::Ordering::Less => {
                result.report_error(&format!(
                    "Too few calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Greater => {
                result.report_error(&format!(
                    "Too many calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Equal => {}
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }

    async fn verify_artifact_payloads(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 payloads ===");

        // Absolute stage-1 indices; index 0 is the leading `pauseMigration()`.
        const UPGRADE_BRIDGEHUB: usize = 1;
        const UPGRADE_L1_NULLIFIER: usize = 2;
        const UPGRADE_L1_ASSET_ROUTER: usize = 3;
        const UPGRADE_NATIVE_TOKEN_VAULT: usize = 4;
        const UPGRADE_MESSAGE_ROOT: usize = 5;
        const UPGRADE_CTM_DEPLOYMENT_TRACKER: usize = 6;
        const UPGRADE_CHAIN_ASSET_HANDLER: usize = 7;
        const UPGRADE_CHAIN_REGISTRATION_SENDER: usize = 8;
        const SET_INTEROP_HANDLER_ON_NULLIFIER: usize = 9;
        const SET_INTEROP_HANDLER_ON_ASSET_ROUTER: usize = 10;

        let wiring_len = interop_handler_wiring_len(artifact, verifiers);
        let core_len = STAGE1_CORE_PREFIX_LEN + wiring_len;
        let mut errors = 0;

        for (index, proxy_name, implementation_name) in [
            // Verify Bridgehub proxy upgrade payload.
            (
                UPGRADE_BRIDGEHUB,
                "bridgehub_proxy",
                "bridgehub_implementation_addr",
            ),
            // Verify L1 nullifier proxy upgrade payload.
            (
                UPGRADE_L1_NULLIFIER,
                "l1_nullifier_proxy",
                "l1_nullifier_implementation_addr",
            ),
            // Verify L1 asset router proxy upgrade payload.
            (
                UPGRADE_L1_ASSET_ROUTER,
                "l1_asset_router_proxy",
                "l1_asset_router_implementation_addr",
            ),
            // Verify native token vault proxy upgrade payload.
            (
                UPGRADE_NATIVE_TOKEN_VAULT,
                "native_token_vault",
                "native_token_vault_implementation_addr",
            ),
            // Verify CTM deployment tracker proxy upgrade payload.
            (
                UPGRADE_CTM_DEPLOYMENT_TRACKER,
                "ctm_deployment_tracker_proxy",
                "ctm_deployment_tracker_implementation_addr",
            ),
            // Verify chain asset handler proxy upgrade payload.
            (
                UPGRADE_CHAIN_ASSET_HANDLER,
                "chain_asset_handler_proxy",
                "chain_asset_handler_implementation_addr",
            ),
            // Verify MessageRoot proxy upgrade payload. Plain `upgrade` in
            // v33 — the v31 reinitializer is gone.
            (
                UPGRADE_MESSAGE_ROOT,
                "message_root_proxy",
                "message_root_implementation_addr",
            ),
            // Verify ChainRegistrationSender proxy upgrade payload.
            (
                UPGRADE_CHAIN_REGISTRATION_SENDER,
                "chain_registration_sender_proxy",
                "chain_registration_sender_implementation_addr",
            ),
        ] {
            errors += verify_upgrade_call_args(
                &self.calls,
                index,
                proxy_name,
                implementation_name,
                verifiers,
                result,
            );
        }

        // Both wiring calls must point at the handler proxy this run deployed.
        if wiring_len > 0 {
            for (index, caller) in [
                (SET_INTEROP_HANDLER_ON_NULLIFIER, "L1Nullifier"),
                (SET_INTEROP_HANDLER_ON_ASSET_ROUTER, "L1AssetRouter"),
            ] {
                errors += verify_set_interop_handler_call_args(
                    &self.calls,
                    index,
                    caller,
                    verifiers,
                    result,
                );
            }
        }

        // Per-CTM block: CTM proxy upgrade, setChainCreationParams,
        // setNewVersionUpgrade. Validated against each CTM's own
        // chain_upgrade_diamond_cut + contracts_config.
        for (i, ctm) in artifact.ctms.iter().enumerate() {
            let block = ctm_block_start(i, core_len);
            result.print_info(&format!(
                "-- CTM[{i}] = {} ----------------------",
                ctm.flavor.label()
            ));
            errors += verify_ctm_upgrade_call_args(
                &self.calls,
                block + PER_CTM_OFFSET_UPGRADE_CTM,
                ctm,
                verifiers,
                result,
            );
            errors += verify_set_chain_creation_params_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS,
                ctm,
                verifiers,
                result,
            )
            .await;
            errors += verify_set_new_version_upgrade_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE,
                ctm,
                verifiers,
                result,
            )
            .await?;
            errors += verify_set_default_upgrade_call_args(
                &self.calls,
                block + PER_CTM_OFFSET_SET_DEFAULT_UPGRADE,
                ctm,
                verifiers,
                result,
            );
            for (offset, proxy_field, impl_source, display_name) in [
                (
                    PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK,
                    "validator_timelock_addr",
                    KeptProxyImplSource::ArtifactField("validator_timelock_implementation_addr"),
                    "ValidatorTimelock",
                ),
                (
                    PER_CTM_OFFSET_UPGRADE_BYTECODES_SUPPLIER,
                    "bytecodes_supplier_addr",
                    KeptProxyImplSource::Create2File("l1-contracts/BytecodesSupplier"),
                    "BytecodesSupplier",
                ),
                (
                    PER_CTM_OFFSET_UPGRADE_PERMISSIONLESS_VALIDATOR,
                    "permissionless_validator_addr",
                    KeptProxyImplSource::Create2File("l1-contracts/PermissionlessValidator"),
                    "PermissionlessValidator",
                ),
            ] {
                errors += verify_kept_proxy_upgrade_call_args(
                    &self.calls,
                    block + offset,
                    ctm,
                    proxy_field,
                    impl_source,
                    display_name,
                    verifiers,
                    result,
                );
            }
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }
}

fn verify_upgrade_call_args(
    calls: &CallList,
    index: usize,
    proxy_name: &str,
    implementation_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing upgrade call at stage1 index {index}"));
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            errors += expect_named_address(result, verifiers, &decoded.proxy, proxy_name);
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.implementation,
                implementation_name,
            );
            if errors == 0 {
                result.report_ok(&format!(
                    "Upgrade payload for {proxy_name} uses {implementation_name}"
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode upgrade call at stage1 index {index}: {err}"
            ));
            1
        }
    }
}

fn verify_ctm_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing ChainTypeManager upgrade call");
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            if let Some(expected_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_proxy"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.proxy,
                    expected_proxy,
                    &format!("{}.chain_type_manager_proxy", ctm.flavor.label()),
                );
            } else {
                errors += 1;
            }
            if let Some(expected_impl) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_implementation_addr"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.implementation,
                    expected_impl,
                    &format!(
                        "{}.chain_type_manager_implementation_addr",
                        ctm.flavor.label()
                    ),
                );
            } else {
                errors += 1;
            }
            if errors == 0 {
                result.report_ok(&format!(
                    "{} ChainTypeManager upgrade payload uses expected proxy and implementation",
                    ctm.flavor.label()
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode ChainTypeManager upgrade call: {err}"
            ));
            1
        }
    }
}

/// Payload check for one of the three proxies v33 keeps and re-implements
/// (ValidatorTimelock, BytecodesSupplier, PermissionlessValidator).
///
/// `impl_field` is the artifact field naming the new implementation. Only
/// ValidatorTimelock publishes one; for the other two the artifact records
/// just the proxy, so `impl_source` falls back to this upgrade's CREATE2
/// deployments and requires that the call points at the single contract of
/// that name deployed here. That is the stronger check of the two — it ties
/// the governance call to a contract with verified provenance rather than to
/// another line of the same file.
#[allow(clippy::too_many_arguments)]
fn verify_kept_proxy_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    proxy_field: &str,
    impl_source: KeptProxyImplSource<'_>,
    display_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing {display_name} upgrade call"));
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            if let Some(expected_proxy) =
                required_ctm_address(ctm, &["state_transition", proxy_field], result)
            {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.proxy,
                    expected_proxy,
                    &format!("{}.{proxy_field}", ctm.flavor.label()),
                );
            } else {
                errors += 1;
            }

            match impl_source {
                KeptProxyImplSource::ArtifactField(impl_field) => {
                    if let Some(expected_impl) =
                        required_ctm_address(ctm, &["state_transition", impl_field], result)
                    {
                        errors += expect_address_equal(
                            result,
                            verifiers,
                            &decoded.implementation,
                            expected_impl,
                            &format!("{}.{impl_field}", ctm.flavor.label()),
                        );
                    } else {
                        errors += 1;
                    }
                }
                KeptProxyImplSource::Create2File(file) => {
                    match verifiers
                        .network_verifier
                        .create2_known_bytecodes
                        .get(&decoded.implementation)
                    {
                        Some(deployed_file) if deployed_file == file => result.report_ok(&format!(
                            "{display_name} impl {} was deployed by this upgrade as {file}",
                            decoded.implementation
                        )),
                        Some(deployed_file) => {
                            result.report_error(&format!(
                                "{display_name} upgrade points at {}, which this upgrade deployed as {deployed_file}, not {file}",
                                decoded.implementation,
                            ));
                            errors += 1;
                        }
                        None => {
                            result.report_error(&format!(
                                "{display_name} upgrade points at {}, which is not among this upgrade's CREATE2 deployments",
                                decoded.implementation,
                            ));
                            errors += 1;
                        }
                    }
                }
            }

            if errors == 0 {
                result.report_ok(&format!(
                    "{} {display_name} upgrade payload uses expected proxy and implementation",
                    ctm.flavor.label()
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode {display_name} upgrade call: {err}"
            ));
            1
        }
    }
}

/// `setDefaultUpgrade` must store the CTM's *generic* upgrade contract
/// (`DefaultUpgradeZKsyncOS`), not the one-shot cut used by this release.
/// The distinction matters: the stored address is what every *later* patch
/// upgrade reuses, so pointing it at the one-shot contract would silently
/// re-run this release's migration on a future upgrade.
fn verify_set_default_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing setDefaultUpgrade call");
        return 1;
    };

    match setDefaultUpgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let Some(expected) = required_ctm_address(
                ctm,
                &["state_transition", "ctm_stored_default_upgrade_addr"],
                result,
            ) else {
                return 1;
            };
            let mut errors = expect_address_equal(
                result,
                verifiers,
                &decoded.newUpgrade,
                expected,
                &format!("{}.ctm_stored_default_upgrade_addr", ctm.flavor.label()),
            );
            // Guard the whole point of the field: the stored generic upgrade
            // must not be this release's one-shot contract.
            if let Some(one_shot) =
                required_ctm_address(ctm, &["state_transition", "default_upgrade_addr"], result)
            {
                if decoded.newUpgrade == one_shot {
                    result.report_error(&format!(
                        "{} setDefaultUpgrade stores the one-shot upgrade {one_shot}; it must store the generic DefaultUpgrade contract",
                        ctm.flavor.label(),
                    ));
                    errors += 1;
                }
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!("Failed to decode setDefaultUpgrade call: {err}"));
            1
        }
    }
}

/// Both `setL1InteropHandler` calls must pass the handler proxy this upgrade
/// deployed.
fn verify_set_interop_handler_call_args(
    calls: &CallList,
    index: usize,
    caller: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing {caller}.setL1InteropHandler call"));
        return 1;
    };

    match setL1InteropHandlerCall::abi_decode(&call.data) {
        Ok(decoded) => expect_named_address(
            result,
            verifiers,
            &decoded.handler,
            "l1_interop_handler_proxy",
        ),
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode {caller}.setL1InteropHandler call: {err}"
            ));
            1
        }
    }
}

/// Where the expected new implementation for a kept proxy comes from.
enum KeptProxyImplSource<'a> {
    /// A `[ctms.<flavor>.state_transition]` field naming the implementation.
    ArtifactField(&'a str),
    /// The contract file the implementation must have been CREATE2-deployed
    /// from in this upgrade, for proxies the artifact records without one.
    Create2File(&'a str),
}

async fn verify_set_chain_creation_params_payload(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing setChainCreationParams call");
        return 1;
    };

    let decoded = match setChainCreationParamsCall::abi_decode(&call.data) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!("Failed to decode setChainCreationParams: {err}"));
            return 1;
        }
    };
    let params = decoded._chainCreationParams;

    let mut errors = 0;
    if let Some(expected_genesis_upgrade) =
        required_ctm_address(ctm, &["state_transition", "genesis_upgrade_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &params.genesisUpgrade,
            expected_genesis_upgrade,
            &format!("{}.genesis_upgrade_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }
    if let Some(expected_diamond_init) =
        required_ctm_address(ctm, &["state_transition", "diamond_init_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &params.diamondCut.initAddress,
            expected_diamond_init,
            &format!("{}.diamond_init_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    let genesis_config = verifiers.genesis_config_for_ctm(ctm.flavor);
    if params.genesisBatchHash.to_string() != genesis_config.genesis_root {
        result.report_error(&format!(
            "Expected genesis batch hash to be {}, but got {}",
            genesis_config.genesis_root, params.genesisBatchHash
        ));
        errors += 1;
    }

    match ctm.flavor {
        CtmFlavor::ZksyncOs => {
            let expected_genesis_index_repeated_storage_changes = 0_u64;
            if params.genesisIndexRepeatedStorageChanges
                != expected_genesis_index_repeated_storage_changes
            {
                result.report_error(&format!(
                    "Expected ZKsync OS genesis index repeated storage changes to be {}, but got {}",
                    expected_genesis_index_repeated_storage_changes, params.genesisIndexRepeatedStorageChanges
                ));
                errors += 1;
            }

            let expected_genesis_batch_commitment = U256::from(1);
            let actual_genesis_batch_commitment =
                U256::from_be_slice(params.genesisBatchCommitment.as_slice());
            if actual_genesis_batch_commitment != expected_genesis_batch_commitment {
                result.report_error(&format!(
                    "Expected ZKsync OS genesis batch commitment to be bytes32(1), but got {}",
                    params.genesisBatchCommitment
                ));
                errors += 1;
            }
        }
    }

    errors += expect_hex_equal(
        result,
        "chain creation diamond cut",
        &ctm.contracts_config.diamond_cut_data,
        &hex::encode(params.diamondCut.abi_encode()),
    );
    errors += expect_hex_equal(
        result,
        "force deployments data",
        &ctm.contracts_config.force_deployments_data,
        &hex::encode(&params.forceDeploymentsData),
    );

    result.print_info(&format!(
        "-- chain creation facet cut decomposition ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    errors +=
        verify_v33_chain_creation_facet_cuts(&params.diamondCut.facetCuts, ctm, verifiers, result)
            .await;

    // Decode forceDeploymentsData and verify each field independently so the
    // artifact hex is not merely trusted as a self-referential source of truth.
    result.print_info(&format!(
        "-- forceDeploymentsData field verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    match FixedForceDeploymentsData::abi_decode(&params.forceDeploymentsData) {
        Ok(fixed_data) => {
            if let Err(err) = fixed_data.verify(verifiers, result).await {
                result.report_error(&format!(
                    "forceDeploymentsData field verification failed: {err}"
                ));
                errors += 1;
            }
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode setChainCreationParams forceDeploymentsData: {err}"
            ));
            errors += 1;
        }
    }

    // Decode the chain-creation diamond cut's initCalldata and verify the three
    // bytecode hashes independently of the artifact hex.
    result.print_info(&format!(
        "-- InitializeDataNewChain field verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    match InitializeDataNewChain::abi_decode(&params.diamondCut.initCalldata) {
        Ok(init_data) => init_data.verify(ctm.flavor, result),
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode InitializeDataNewChain from chain-creation initCalldata: {err}"
            ));
            errors += 1;
        }
    }

    errors
}

async fn verify_set_new_version_upgrade_payload(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let calldata = &calls
        .elems
        .get(index)
        .context("missing setNewVersionUpgrade call")?
        .data;
    let data = set_new_version_upgrade::setNewVersionUpgradeCall::abi_decode(calldata)
        .context("decoding setNewVersionUpgrade")?;

    let mut errors = 0;
    let artifact_old_protocol_version = U256::from(ctm.contracts_config.old_protocol_version);
    let artifact_new_protocol_version = U256::from(ctm.contracts_config.new_protocol_version);

    if data.oldProtocolVersion != artifact_old_protocol_version {
        result.report_error(&format!(
            "setNewVersionUpgrade old protocol version mismatch: expected {} from TOML, got {}",
            artifact_old_protocol_version, data.oldProtocolVersion
        ));
        errors += 1;
    } else {
        result.report_ok(&format!(
            "{} setNewVersionUpgrade old protocol version matches TOML ({})",
            ctm.flavor.label(),
            protocol_label(artifact_old_protocol_version)
        ));
    }

    let decoded_old_protocol_version = ProtocolVersion::from(artifact_old_protocol_version);
    // Patch-insensitive: see `is_expected_old_protocol_version_for_ctm_flavor`.
    if !is_expected_old_protocol_version_for_ctm_flavor(decoded_old_protocol_version, ctm.flavor) {
        result.report_error(&format!(
            "{} CTM old protocol version must be {}, got {}",
            ctm.flavor.label(),
            expected_old_protocol_version_label(ctm.flavor),
            decoded_old_protocol_version
        ));
        errors += 1;
    } else {
        result.report_ok(&format!(
            "{} CTM old protocol version is {}",
            ctm.flavor.label(),
            expected_old_protocol_version_label(ctm.flavor)
        ));
    }

    if let Some(ctm_addr) = required_ctm_address(
        ctm,
        &["state_transition", "chain_type_manager_proxy"],
        result,
    ) {
        match verifiers
            .network_verifier
            .try_get_ctm_protocol_version(ctm_addr)
            .await
        {
            Ok(onchain_old_protocol_version)
                if onchain_old_protocol_version == data.oldProtocolVersion =>
            {
                result.report_ok("setNewVersionUpgrade old protocol version matches on-chain CTM");
            }
            Ok(onchain_old_protocol_version) => {
                result.report_error(&format!(
                    "setNewVersionUpgrade old protocol version mismatch: on-chain CTM is {}, calldata uses {}",
                    onchain_old_protocol_version, data.oldProtocolVersion
                ));
                errors += 1;
            }
            Err(err) => result.report_warn(&format!(
                "Skipping on-chain CTM protocolVersion check; RPC unavailable or contract call failed: {err}"
            )),
        }
    }

    if data.oldProtocolVersionDeadline != U256::MAX {
        result.report_error("Wrong old protocol version deadline for stage1 call");
        errors += 1;
    }

    if data.newProtocolVersion != artifact_new_protocol_version {
        result.report_error(&format!(
            "setNewVersionUpgrade new protocol version mismatch: expected {} from TOML, got {}",
            artifact_new_protocol_version, data.newProtocolVersion
        ));
        errors += 1;
    }

    let decoded_new_protocol_version = ProtocolVersion::from(artifact_new_protocol_version);
    if decoded_new_protocol_version != get_expected_new_protocol_version() {
        result.report_error(&format!(
            "Invalid new protocol version in TOML. Expected {}, got {}",
            get_expected_new_protocol_version(),
            decoded_new_protocol_version
        ));
        errors += 1;
    }

    if let Some(expected_verifier) =
        required_ctm_address(ctm, &["state_transition", "verifier_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &data.verifier,
            expected_verifier,
            &format!("{}.verifier_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    let diamond_cut = data.diamondCut;
    errors += expect_hex_equal(
        result,
        "chain upgrade diamond cut",
        &ctm.chain_upgrade_diamond_cut,
        &hex::encode(diamond_cut.abi_encode()),
    );
    if let Some(expected_default_upgrade) =
        required_ctm_address(ctm, &["state_transition", "default_upgrade_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &diamond_cut.initAddress,
            expected_default_upgrade,
            &format!("{}.default_upgrade_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }

    errors += verify_v33_upgrade_facet_cuts(&diamond_cut.facetCuts, ctm, verifiers, result).await?;
    // Phase 5: when the artifact names a `bytecodes_supplier_addr` we also
    // verify that every L2 upgrade tx `factoryDeps` entry has been published
    // in `BytecodesSupplier` on the live L1 RPC. The legacy PUVT performed
    // this check unconditionally; the calldata-only verifier dropped it, and
    // we restore it here.
    let bytecodes_supplier_addr = required_ctm_address(
        ctm,
        &["state_transition", "bytecodes_supplier_addr"],
        result,
    );
    errors += verify_default_upgrade_payload(
        &diamond_cut.initCalldata,
        artifact_new_protocol_version,
        &ctm.contracts_config.force_deployments_data,
        verifiers,
        result,
        bytecodes_supplier_addr,
        ctm.flavor,
    )
    .await?;

    Ok(errors)
}
