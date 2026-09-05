//! Stage 1 — the main upgrade ceremony.
//!
//! Call layout: 10 ecosystem-wide core calls, optionally followed by three
//! L1InteropHandler wiring calls, then a 10-call block per
//! `[ctms.<flavor>]` entry in artifact order.
//!
//! Two passes:
//! - [`verify_call_shape`] — every call's `(target, selector, value=0)`.
//! - [`verify_artifact_payloads`] — decodes each call's payload and checks
//!   it against the artifact (proxy/impl pairs, `setChainCreationParams`
//!   fields + facet decomp, `setNewVersionUpgrade` deep payload via the
//!   `set_new_version_upgrade` module).

use alloy::{
    hex,
    primitives::{Address, U256},
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::{
    super::expected_old_protocol_version_label, super::get_expected_new_protocol_version,
    super::get_expected_old_protocol_version_for_ctm_flavor,
};
use super::super::{
    fixed_force_deployment::FixedForceDeploymentsData, initialize_data_new_chain,
    protocol_version::ProtocolVersion, set_new_version_upgrade, L1InteropHandlerPreparationMode,
};
use super::facets::{
    verify_default_upgrade_payload, verify_v31_chain_creation_facet_cuts,
    verify_v31_upgrade_facet_cuts,
};
use super::helpers::{
    expect_address_equal, expect_hex_equal, expect_named_address, protocol_label,
    required_core_address, required_ctm_address, verify_call_by_address, verify_call_by_name,
};
use super::{
    acceptOwnershipCall, setChainCreationParamsCall, setDefaultUpgradeCall,
    setL1InteropHandlerCall, upgradeCall, CallList, GovernanceStage1Calls,
};

const STAGE1_CORE_BASE_LEN: usize = 10;
const STAGE1_CORE_WITH_INTEROP_WIRING_LEN: usize = 13;
const STAGE1_PER_CTM_LEN: usize = 10;

const PER_CTM_OFFSET_CHECK_DEADLINE: usize = 0;
const PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED: usize = 1;
const PER_CTM_OFFSET_UPGRADE_CTM: usize = 2;
const PER_CTM_OFFSET_SET_DEFAULT_UPGRADE: usize = 3;
const PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS: usize = 4;
const PER_CTM_OFFSET_CHECK_PRECONDITION_CHECKER: usize = 5;
const PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE: usize = 6;
const PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK: usize = 7;
const PER_CTM_OFFSET_UPGRADE_BYTECODES_SUPPLIER: usize = 8;
const PER_CTM_OFFSET_UPGRADE_PERMISSIONLESS_VALIDATOR: usize = 9;

#[derive(Clone, Copy)]
struct CtmComponentUpgrade {
    offset: usize,
    proxy_key: &'static str,
    implementation_key: &'static str,
    name: &'static str,
}

const CTM_COMPONENT_UPGRADES: [CtmComponentUpgrade; 3] = [
    CtmComponentUpgrade {
        offset: PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK,
        proxy_key: "validator_timelock_addr",
        implementation_key: "validator_timelock_implementation_addr",
        name: "ValidatorTimelock",
    },
    CtmComponentUpgrade {
        offset: PER_CTM_OFFSET_UPGRADE_BYTECODES_SUPPLIER,
        proxy_key: "bytecodes_supplier_addr",
        implementation_key: "bytecodes_supplier_implementation_addr",
        name: "BytecodesSupplier",
    },
    CtmComponentUpgrade {
        offset: PER_CTM_OFFSET_UPGRADE_PERMISSIONLESS_VALIDATOR,
        proxy_key: "permissionless_validator_addr",
        implementation_key: "permissionless_validator_implementation_addr",
        name: "PermissionlessValidator",
    },
];

fn ctm_block_start(ctm_index: usize, core_call_count: usize) -> usize {
    core_call_count + ctm_index * STAGE1_PER_CTM_LEN
}

pub(crate) fn infer_l1_interop_handler_preparation_mode(
    stage1_call_count: usize,
    ctm_count: usize,
) -> anyhow::Result<L1InteropHandlerPreparationMode> {
    let reuse_call_count = ctm_block_start(ctm_count, STAGE1_CORE_BASE_LEN);
    let deploy_and_wire_call_count =
        ctm_block_start(ctm_count, STAGE1_CORE_WITH_INTEROP_WIRING_LEN);

    match stage1_call_count {
        count if count == reuse_call_count => Ok(L1InteropHandlerPreparationMode::Reuse),
        count if count == deploy_and_wire_call_count => {
            Ok(L1InteropHandlerPreparationMode::DeployAndWire)
        }
        count => anyhow::bail!(
            "Stage 1 must contain either {reuse_call_count} calls for a reused L1InteropHandler or \
             {deploy_and_wire_call_count} calls for a newly prepared L1InteropHandler; got {count}"
        ),
    }
}

impl GovernanceStage1Calls {
    /// Stage 1 — migration pause, core proxy upgrades and address refresh,
    /// optional L1InteropHandler wiring, then each CTM's upgrade calls.
    ///
    /// Split into two passes: `verify_call_shape` checks target+selector for
    /// every call; `verify_artifact_payloads` decodes args and cross-checks
    /// against the artifact's declared addresses and structs.
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        l1_interop_handler_mode: L1InteropHandlerPreparationMode,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        let core_call_count = match l1_interop_handler_mode {
            L1InteropHandlerPreparationMode::DeployAndWire => STAGE1_CORE_WITH_INTEROP_WIRING_LEN,
            L1InteropHandlerPreparationMode::Reuse => STAGE1_CORE_BASE_LEN,
        };

        self.verify_call_shape(&artifact.ctms, core_call_count, verifiers, result)
            .await?;
        self.verify_artifact_payloads(artifact, core_call_count, verifiers, result)
            .await
    }

    async fn verify_call_shape(
        &self,
        ctms: &[CtmArtifact],
        core_call_count: usize,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 calls ===");

        let mut errors = 0;
        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "pauseMigration()",
            verifiers,
            result,
        );
        for (index, target, method) in [
            // Upgrade Bridgehub proxy.
            (1, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 nullifier proxy.
            (2, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 asset router proxy.
            (3, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade native token vault proxy.
            (4, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade message root proxy.
            (5, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade CTM deployment tracker proxy.
            (6, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade chain asset handler proxy.
            (7, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade ChainRegistrationSender proxy.
            (8, "transparent_proxy_admin", "upgrade(address,address)"),
            // Cache MessageRoot / AssetRouter inside L1ChainAssetHandler.
            (9, "chain_asset_handler_proxy", "setAddresses()"),
        ] {
            errors += verify_call_by_name(&self.calls, index, target, method, verifiers, result);
        }

        if core_call_count == STAGE1_CORE_WITH_INTEROP_WIRING_LEN {
            for (index, target, method) in [
                (10, "l1_interop_handler_proxy", "acceptOwnership()"),
                (11, "l1_nullifier_proxy", "setL1InteropHandler(address)"),
                (12, "l1_asset_router_proxy", "setL1InteropHandler(address)"),
            ] {
                errors +=
                    verify_call_by_name(&self.calls, index, target, method, verifiers, result);
            }
        }

        // Per-CTM block (10 calls per CTM, in artifact order):
        //   +0 timer.checkDeadline()
        //   +1 stage-validator.checkMigrationsPaused()
        //   +2 CTM proxy admin.upgrade(CTM proxy, new impl)
        //   +3 CTM proxy.setDefaultUpgrade(...)
        //   +4 CTM proxy.setChainCreationParams(...)
        //   +5 stage-validator.checkUpgradePreconditionChecker(...)
        //   +6 CTM proxy.setNewVersionUpgrade(...)
        //   +7 VT proxy admin.upgrade(VT proxy, new impl)
        //   +8 BytecodesSupplier proxy admin.upgrade(proxy, new impl)
        //   +9 PermissionlessValidator proxy admin.upgrade(proxy, new impl)
        for (ctm_index, ctm) in ctms.iter().enumerate() {
            let block = ctm_block_start(ctm_index, core_call_count);
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
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_CHECK_PRECONDITION_CHECKER,
                    validator,
                    &validator_label,
                    "checkUpgradePreconditionChecker(uint256,address)",
                    verifiers,
                    result,
                );
            } else {
                errors += 2;
            }

            if let Some(ctm_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "chain_type_manager_proxy"],
                result,
            ) {
                let ctm_proxy_admin_label =
                    format!("{}.chain_type_manager_proxy_admin", ctm.flavor.label());
                match verifiers
                    .network_verifier
                    .try_get_proxy_admin(ctm_proxy)
                    .await
                {
                    Ok(ctm_proxy_admin) => {
                        errors += verify_call_by_address(
                            &self.calls,
                            block + PER_CTM_OFFSET_UPGRADE_CTM,
                            ctm_proxy_admin,
                            &ctm_proxy_admin_label,
                            "upgrade(address,address)",
                            verifiers,
                            result,
                        );
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to resolve {ctm_proxy_admin_label} from {ctm_proxy}: {err}"
                        ));
                        errors += 1;
                    }
                }
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

            for component in CTM_COMPONENT_UPGRADES {
                if let Some(proxy) =
                    required_ctm_address(ctm, &["state_transition", component.proxy_key], result)
                {
                    let proxy_admin_label = format!(
                        "{}.{}_proxy_admin",
                        ctm.flavor.label(),
                        component.proxy_key.trim_end_matches("_addr")
                    );
                    match verifiers.network_verifier.try_get_proxy_admin(proxy).await {
                        Ok(proxy_admin) => {
                            errors += verify_call_by_address(
                                &self.calls,
                                block + component.offset,
                                proxy_admin,
                                &proxy_admin_label,
                                "upgrade(address,address)",
                                verifiers,
                                result,
                            );
                        }
                        Err(err) => {
                            result.report_error(&format!(
                                "Failed to resolve {proxy_admin_label} from {proxy}: {err}"
                            ));
                            errors += 1;
                        }
                    }
                } else {
                    errors += 1;
                }
            }
        }
        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }

    async fn verify_artifact_payloads(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        core_call_count: usize,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 payloads ===");

        const UPGRADE_BRIDGEHUB: usize = 1;
        const UPGRADE_L1_NULLIFIER: usize = 2;
        const UPGRADE_L1_ASSET_ROUTER: usize = 3;
        const UPGRADE_NATIVE_TOKEN_VAULT: usize = 4;
        const UPGRADE_MESSAGE_ROOT: usize = 5;
        const UPGRADE_CTM_DEPLOYMENT_TRACKER: usize = 6;
        const UPGRADE_CHAIN_ASSET_HANDLER: usize = 7;
        const UPGRADE_CHAIN_REGISTRATION_SENDER: usize = 8;

        let mut errors = 0;
        errors += verify_no_arg_calldata(&self.calls, 0, "pauseMigration", result);
        errors += verify_no_arg_calldata(&self.calls, 9, "setAddresses", result);

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
            (
                UPGRADE_MESSAGE_ROOT,
                "message_root_proxy",
                "message_root_implementation_addr",
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

        if core_call_count == STAGE1_CORE_WITH_INTEROP_WIRING_LEN {
            errors +=
                verify_interop_handler_wiring_payloads(&self.calls, artifact, verifiers, result);
        }

        // Validate every per-CTM payload against that CTM's artifact section.
        for (i, ctm) in artifact.ctms.iter().enumerate() {
            let block = ctm_block_start(i, core_call_count);
            result.print_info(&format!(
                "-- CTM[{i}] = {} ----------------------",
                ctm.flavor.label()
            ));
            errors += verify_no_arg_calldata(
                &self.calls,
                block + PER_CTM_OFFSET_CHECK_DEADLINE,
                "checkDeadline",
                result,
            );
            errors += verify_no_arg_calldata(
                &self.calls,
                block + PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED,
                "checkMigrationsPaused",
                result,
            );
            errors += verify_ctm_upgrade_call_args(
                &self.calls,
                block + PER_CTM_OFFSET_UPGRADE_CTM,
                ctm,
                verifiers,
                result,
            );
            errors += verify_set_default_upgrade_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_DEFAULT_UPGRADE,
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
            errors += verify_upgrade_precondition_checker_payload(
                &self.calls,
                block + PER_CTM_OFFSET_CHECK_PRECONDITION_CHECKER,
                ctm,
                result,
            );
            errors += verify_set_new_version_upgrade_payload(
                &self.calls,
                block + PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE,
                ctm,
                verifiers,
                result,
            )
            .await?;
            for component in CTM_COMPONENT_UPGRADES {
                errors += verify_ctm_component_upgrade_call_args(
                    &self.calls,
                    block + component.offset,
                    ctm,
                    component,
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

fn verify_no_arg_calldata(
    calls: &CallList,
    index: usize,
    function_name: &str,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing {function_name} call"));
        return 1;
    };
    if call.data.len() == 4 {
        0
    } else {
        result.report_error(&format!("{function_name} calldata is not canonical"));
        1
    }
}

fn verify_upgrade_precondition_checker_payload(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing checkUpgradePreconditionChecker call");
        return 1;
    };

    let expected_version = U256::from(ctm.contracts_config.old_protocol_version);
    let Some(expected_checker) = required_ctm_address(
        ctm,
        &["state_transition", "upgrade_precondition_checker_addr"],
        result,
    ) else {
        return 1;
    };

    match validate_upgrade_precondition_checker_call(&call.data, expected_version, expected_checker)
    {
        Ok(()) => {
            result.report_ok(&format!(
                "{} checker-registration guard matches the reviewed version and checker",
                ctm.flavor.label()
            ));
            0
        }
        Err(err) => {
            result.report_error(&format!(
                "{} checker-registration guard is invalid: {err}",
                ctm.flavor.label()
            ));
            1
        }
    }
}

fn validate_upgrade_precondition_checker_call(
    calldata: &[u8],
    expected_version: U256,
    expected_checker: Address,
) -> anyhow::Result<()> {
    let decoded = super::checkUpgradePreconditionCheckerCall::abi_decode(calldata)
        .context("failed to decode checkUpgradePreconditionChecker")?;
    anyhow::ensure!(
        decoded.abi_encode() == calldata,
        "checkUpgradePreconditionChecker calldata is not canonical"
    );
    anyhow::ensure!(
        decoded._oldProtocolVersion == expected_version,
        "old protocol version mismatch: expected {expected_version}, got {}",
        decoded._oldProtocolVersion
    );
    anyhow::ensure!(
        decoded._expectedChecker == expected_checker,
        "checker address mismatch: expected {expected_checker}, got {}",
        decoded._expectedChecker
    );
    Ok(())
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
            if decoded.abi_encode() != call.data {
                result.report_error(&format!(
                    "Upgrade calldata at stage1 index {index} is not canonical"
                ));
                errors += 1;
            }
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

fn verify_interop_handler_wiring_payloads(
    calls: &CallList,
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(accept_call) = calls.elems.get(10) else {
        result.report_error("Missing L1InteropHandler acceptOwnership call");
        return 1;
    };

    let mut errors = 0;
    match acceptOwnershipCall::abi_decode(&accept_call.data) {
        Ok(decoded) if decoded.abi_encode() == accept_call.data => {}
        Ok(_) => {
            result.report_error("L1InteropHandler acceptOwnership calldata is not canonical");
            errors += 1;
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode L1InteropHandler acceptOwnership: {err}"
            ));
            errors += 1;
        }
    }

    let Some(expected_handler) = required_core_address(
        artifact,
        &[
            "upgrade_addresses",
            "bridges",
            "l1_interop_handler_proxy_addr",
        ],
        result,
    ) else {
        return errors + 1;
    };
    for (index, component) in [(11, "L1Nullifier"), (12, "L1AssetRouter")] {
        let Some(call) = calls.elems.get(index) else {
            result.report_error(&format!("Missing {component}.setL1InteropHandler call"));
            errors += 1;
            continue;
        };
        match setL1InteropHandlerCall::abi_decode(&call.data) {
            Ok(decoded) => {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded._handler,
                    expected_handler,
                    "core.upgrade_addresses.bridges.l1_interop_handler_proxy_addr",
                );
                if decoded.abi_encode() != call.data {
                    result.report_error(&format!(
                        "{component}.setL1InteropHandler calldata is not canonical"
                    ));
                    errors += 1;
                }
            }
            Err(err) => {
                result.report_error(&format!(
                    "Failed to decode {component}.setL1InteropHandler: {err}"
                ));
                errors += 1;
            }
        }
    }
    errors
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
            if decoded.abi_encode() != call.data {
                result.report_error("ChainTypeManager upgrade calldata is not canonical");
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

fn verify_ctm_component_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    component: CtmComponentUpgrade,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!("Missing {} upgrade call", component.name));
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            if let Some(expected_proxy) =
                required_ctm_address(ctm, &["state_transition", component.proxy_key], result)
            {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.proxy,
                    expected_proxy,
                    &format!("{}.{}", ctm.flavor.label(), component.proxy_key),
                );
            } else {
                errors += 1;
            }
            if let Some(expected_impl) = required_ctm_address(
                ctm,
                &["state_transition", component.implementation_key],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.implementation,
                    expected_impl,
                    &format!("{}.{}", ctm.flavor.label(), component.implementation_key),
                );
            } else {
                errors += 1;
            }
            if decoded.abi_encode() != call.data {
                result.report_error(&format!(
                    "{} upgrade calldata is not canonical",
                    component.name
                ));
                errors += 1;
            }
            if errors == 0 {
                result.report_ok(&format!(
                    "{} {} upgrade payload uses expected proxy and implementation",
                    ctm.flavor.label(),
                    component.name
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode {} upgrade call: {err}",
                component.name
            ));
            1
        }
    }
}

fn verify_set_default_upgrade_payload(
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
    let decoded = match setDefaultUpgradeCall::abi_decode(&call.data) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!("Failed to decode setDefaultUpgrade: {err}"));
            return 1;
        }
    };

    let mut errors = 0;
    if let Some(expected) =
        required_ctm_address(ctm, &["state_transition", "default_upgrade_addr"], result)
    {
        errors += expect_address_equal(
            result,
            verifiers,
            &decoded._defaultUpgrade,
            expected,
            &format!("{}.default_upgrade_addr", ctm.flavor.label()),
        );
    } else {
        errors += 1;
    }
    if decoded.abi_encode() != call.data {
        result.report_error("setDefaultUpgrade calldata is not canonical");
        errors += 1;
    }
    errors
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
    let mut errors = 0;
    if decoded.abi_encode() != call.data {
        result.report_error("setChainCreationParams calldata is not canonical");
        errors += 1;
    }
    let params = decoded._chainCreationParams;

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

    let expected_genesis_index_repeated_storage_changes = 0_u64;
    if params.genesisIndexRepeatedStorageChanges != expected_genesis_index_repeated_storage_changes
    {
        result.report_error(&format!(
            "Expected ZKsync OS genesis index repeated storage changes to be {}, but got {}",
            expected_genesis_index_repeated_storage_changes,
            params.genesisIndexRepeatedStorageChanges
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
        verify_v31_chain_creation_facet_cuts(&params.diamondCut.facetCuts, ctm, verifiers, result)
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

    // The chain-creation diamond cut's initCalldata must be empty from v34 onwards.
    result.print_info(&format!(
        "-- chain-creation initCalldata verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    initialize_data_new_chain::verify_chain_creation_init_calldata(
        &params.diamondCut.initCalldata,
        result,
    );

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
    if data.abi_encode() != *calldata {
        result.report_error("setNewVersionUpgrade calldata is not canonical");
        errors += 1;
    }
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
    let expected_old_protocol_version: U256 =
        get_expected_old_protocol_version_for_ctm_flavor(ctm.flavor).into();
    if artifact_old_protocol_version != expected_old_protocol_version {
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

    errors += verify_v31_upgrade_facet_cuts(&diamond_cut.facetCuts, ctm, verifiers, result).await?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn checker_call(version: U256, checker: Address) -> Vec<u8> {
        super::super::checkUpgradePreconditionCheckerCall::new((version, checker)).abi_encode()
    }

    #[test]
    fn exact_stage1_layout_determines_interop_handler_preparation_mode() {
        let ctm_count = 2;
        let reuse_call_count = ctm_block_start(ctm_count, STAGE1_CORE_BASE_LEN);
        let deploy_and_wire_call_count =
            ctm_block_start(ctm_count, STAGE1_CORE_WITH_INTEROP_WIRING_LEN);

        assert_eq!(
            infer_l1_interop_handler_preparation_mode(reuse_call_count, ctm_count).unwrap(),
            L1InteropHandlerPreparationMode::Reuse
        );
        assert_eq!(
            infer_l1_interop_handler_preparation_mode(deploy_and_wire_call_count, ctm_count)
                .unwrap(),
            L1InteropHandlerPreparationMode::DeployAndWire
        );
        assert!(
            infer_l1_interop_handler_preparation_mode(reuse_call_count + 1, ctm_count).is_err()
        );
    }

    #[test]
    fn reuse_mode_does_not_require_proxy_deployment_provenance() {
        let ctm_count = 1;
        let reuse_call_count = ctm_block_start(ctm_count, STAGE1_CORE_BASE_LEN);
        let mode = infer_l1_interop_handler_preparation_mode(reuse_call_count, ctm_count).unwrap();

        assert_eq!(mode, L1InteropHandlerPreparationMode::Reuse);
        assert!(!mode.requires_proxy_deployment_provenance());
    }

    #[test]
    fn checker_call_must_be_canonical_and_match_expected_values() {
        let version = U256::from(32);
        let checker = Address::repeat_byte(0x11);
        let canonical = checker_call(version, checker);
        validate_upgrade_precondition_checker_call(&canonical, version, checker).unwrap();

        let mut wrong_selector = canonical.clone();
        wrong_selector[0] ^= 0xff;
        let err = validate_upgrade_precondition_checker_call(&wrong_selector, version, checker)
            .unwrap_err();
        assert!(format!("{err:#}").contains("failed to decode"));

        let mut trailing_byte = canonical.clone();
        trailing_byte.push(0);
        let err = validate_upgrade_precondition_checker_call(&trailing_byte, version, checker)
            .unwrap_err();
        assert!(format!("{err:#}").contains("not canonical"));

        let wrong_version = checker_call(version + U256::from(1), checker);
        let err = validate_upgrade_precondition_checker_call(&wrong_version, version, checker)
            .unwrap_err();
        assert!(format!("{err:#}").contains("old protocol version mismatch"));

        let wrong_checker = checker_call(version, Address::repeat_byte(0x22));
        let err = validate_upgrade_precondition_checker_call(&wrong_checker, version, checker)
            .unwrap_err();
        assert!(format!("{err:#}").contains("checker address mismatch"));
    }
}
