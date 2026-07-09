//! Stage 1 — the main upgrade ceremony.
//!
//! Non-stage call layout: 11 generated ecosystem-wide core calls
//! (indices 0..=10), then a 6-call block per `[ctms.<flavor>]` entry,
//! repeated in artifact order. Stage prepends one emergency-path
//! `pauseMigration()` call, so all generated calls shift by one there.
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
    super::get_expected_old_protocol_version_for_ctm_flavor,
};
use super::super::{
    fixed_force_deployment::FixedForceDeploymentsData,
    initialize_data_new_chain::InitializeDataNewChain, protocol_version::ProtocolVersion,
    set_new_version_upgrade,
};
use super::facets::{
    verify_default_upgrade_payload, verify_v31_chain_creation_facet_cuts,
    verify_v31_upgrade_facet_cuts,
};
use super::helpers::{
    expect_address_equal, expect_hex_equal, expect_named_address, protocol_label,
    required_ctm_address, verify_call_by_address, verify_call_by_name,
};
use super::{
    initializeL1V31UpgradeCall, setChainCreationParamsCall, upgradeAndCallCall, upgradeCall,
    CallList, GovernanceStage1Calls,
};

/// Number of generated ecosystem-wide stage-1 calls before any per-CTM block.
/// On stage, PUVT additionally requires one leading `pauseMigration()` call
/// because stage1 is executed through the emergency-upgrade path.
const STAGE1_GENERATED_PREFIX_LEN: usize = 9;
const STAGE1_PER_CTM_LEN: usize = 6;

/// Index of the per-CTM `ChainTypeManager` proxy upgrade within the
/// per-CTM block (offset relative to the start of that block).
const PER_CTM_OFFSET_CHECK_DEADLINE: usize = 0;
const PER_CTM_OFFSET_CHECK_MIGRATIONS_PAUSED: usize = 1;
const PER_CTM_OFFSET_UPGRADE_CTM: usize = 2;
const PER_CTM_OFFSET_SET_CHAIN_CREATION_PARAMS: usize = 3;
const PER_CTM_OFFSET_SET_NEW_VERSION_UPGRADE: usize = 4;
const PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK: usize = 5;

fn ctm_block_start(ctm_index: usize, call_offset: usize) -> usize {
    call_offset + STAGE1_GENERATED_PREFIX_LEN + ctm_index * STAGE1_PER_CTM_LEN
}

fn stage1_call_offset(verifiers: &Verifiers) -> usize {
    usize::from(verifiers.env.is_stage())
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
        self.verify_call_shape(&artifact.ctms, verifiers, result)
            .await?;
        self.verify_artifact_payloads(artifact, verifiers, result)
            .await
    }

    async fn verify_call_shape(
        &self,
        ctms: &[CtmArtifact],
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 1 calls ===");

        let call_offset = stage1_call_offset(verifiers);
        let mut errors = 0;
        if verifiers.env.is_stage() {
            // Stage executes stage1 through EmergencyUpgradeBoard, whose
            // emergency path unpauses migrations before forwarding the calls.
            // Re-pause first so the later checkMigrationsPaused() calls still
            // validate the intended stage0 state.
            errors += verify_call_by_name(
                &self.calls,
                0,
                "chain_asset_handler_proxy",
                "pauseMigration()",
                verifiers,
                result,
            );
        }
        for (index, target, method) in [
            // Upgrade Bridgehub proxy.
            (0, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 nullifier proxy.
            (1, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade L1 asset router proxy.
            (2, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade native token vault proxy.
            (3, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade message root proxy and initialize v31 state.
            (
                4,
                "transparent_proxy_admin",
                "upgradeAndCall(address,address,bytes)",
            ),
            // Upgrade CTM deployment tracker proxy.
            (5, "transparent_proxy_admin", "upgrade(address,address)"),
            // Upgrade chain asset handler proxy.
            (6, "transparent_proxy_admin", "upgrade(address,address)"),
            // Accept ChainRegistrationSender ownership.
            (7, "chain_registration_sender_proxy", "acceptOwnership()"),
            // Cache MessageRoot / AssetRouter inside L1ChainAssetHandler.
            (8, "chain_asset_handler_proxy", "setAddresses()"),
        ] {
            errors += verify_call_by_name(
                &self.calls,
                call_offset + index,
                target,
                method,
                verifiers,
                result,
            );
        }

        // Per-CTM block (6 calls per CTM, in artifact order):
        //   +0 timer.checkDeadline()
        //   +1 stage-validator.checkMigrationsPaused()
        //   +2 CTM proxy admin.upgrade(CTM proxy, new impl)
        //   +3 CTM proxy.setChainCreationParams(...)
        //   +4 CTM proxy.setNewVersionUpgrade(...)
        //   +5 VT proxy admin.upgrade(VT proxy, new impl)
        for (ctm_index, ctm) in ctms.iter().enumerate() {
            let block = ctm_block_start(ctm_index, call_offset);
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
                errors += 3;
            }

            // v31 swaps the per-CTM ValidatorTimelock implementation in-place
            // (the impl gains UPGRADER_ROLE + upgradeChainFromVersion). The
            // governance call routes through the same TUPP ProxyAdmin the
            // CTM proxy uses (they share a transparent proxy admin per CTM).
            if let Some(vt_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "validator_timelock_addr"],
                result,
            ) {
                let vt_proxy_admin = verifiers.network_verifier.get_proxy_admin(vt_proxy).await;
                let vt_proxy_admin_label =
                    format!("{}.validator_timelock_proxy_admin", ctm.flavor.label());
                errors += verify_call_by_address(
                    &self.calls,
                    block + PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK,
                    vt_proxy_admin,
                    &vt_proxy_admin_label,
                    "upgrade(address,address)",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }
        }

        let expected_call_count =
            call_offset + STAGE1_GENERATED_PREFIX_LEN + ctms.len() * STAGE1_PER_CTM_LEN;
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

        const UPGRADE_BRIDGEHUB: usize = 0;
        const UPGRADE_L1_NULLIFIER: usize = 1;
        const UPGRADE_L1_ASSET_ROUTER: usize = 2;
        const UPGRADE_NATIVE_TOKEN_VAULT: usize = 3;
        const UPGRADE_MESSAGE_ROOT: usize = 4;
        const UPGRADE_CTM_DEPLOYMENT_TRACKER: usize = 5;
        const UPGRADE_CHAIN_ASSET_HANDLER: usize = 6;

        let call_offset = stage1_call_offset(verifiers);
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
        ] {
            errors += verify_upgrade_call_args(
                &self.calls,
                call_offset + index,
                proxy_name,
                implementation_name,
                verifiers,
                result,
            );
        }

        // Verify MessageRoot upgradeAndCall payload.
        errors += verify_message_root_upgrade_call_args(
            &self.calls,
            call_offset + UPGRADE_MESSAGE_ROOT,
            verifiers,
            result,
        );

        // Per-CTM block: CTM proxy upgrade, setChainCreationParams,
        // setNewVersionUpgrade. Validated against each CTM's own
        // chain_upgrade_diamond_cut + contracts_config.
        for (i, ctm) in artifact.ctms.iter().enumerate() {
            let block = ctm_block_start(i, call_offset);
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
            errors += verify_validator_timelock_upgrade_call_args(
                &self.calls,
                block + PER_CTM_OFFSET_UPGRADE_VALIDATOR_TIMELOCK,
                ctm,
                verifiers,
                result,
            );
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

fn verify_message_root_upgrade_call_args(
    calls: &CallList,
    index: usize,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing MessageRoot upgradeAndCall call");
        return 1;
    };

    match upgradeAndCallCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            errors += expect_named_address(result, verifiers, &decoded.proxy, "message_root_proxy");
            errors += expect_named_address(
                result,
                verifiers,
                &decoded.implementation,
                "message_root_implementation_addr",
            );

            // `initializeL1V31Upgrade()` takes no args, so the inner payload
            // must be exactly its 4-byte selector. Decoding-only would accept
            // trailing bytes that alloy silently ignores.
            let expected_selector = initializeL1V31UpgradeCall::SELECTOR;
            if decoded.data.as_ref() == expected_selector.as_slice() {
                result.report_ok("MessageRoot upgrade payload calls initializeL1V31Upgrade")
            } else {
                result.report_error(&format!(
                    "MessageRoot upgradeAndCall payload must be exactly initializeL1V31Upgrade() selector 0x{}, got 0x{}",
                    hex::encode(expected_selector),
                    hex::encode(decoded.data.as_ref()),
                ));
                errors += 1;
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode MessageRoot upgradeAndCall: {err}"
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

fn verify_validator_timelock_upgrade_call_args(
    calls: &CallList,
    index: usize,
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error("Missing ValidatorTimelock upgrade call");
        return 1;
    };

    match upgradeCall::abi_decode(&call.data) {
        Ok(decoded) => {
            let mut errors = 0;
            if let Some(expected_proxy) = required_ctm_address(
                ctm,
                &["state_transition", "validator_timelock_addr"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.proxy,
                    expected_proxy,
                    &format!("{}.validator_timelock_proxy", ctm.flavor.label()),
                );
            } else {
                errors += 1;
            }
            if let Some(expected_impl) = required_ctm_address(
                ctm,
                &["state_transition", "validator_timelock_implementation_addr"],
                result,
            ) {
                errors += expect_address_equal(
                    result,
                    verifiers,
                    &decoded.implementation,
                    expected_impl,
                    &format!(
                        "{}.validator_timelock_implementation_addr",
                        ctm.flavor.label()
                    ),
                );
            } else {
                errors += 1;
            }
            if errors == 0 {
                result.report_ok(&format!(
                    "{} ValidatorTimelock upgrade payload uses expected proxy and implementation",
                    ctm.flavor.label()
                ));
            }
            errors
        }
        Err(err) => {
            result.report_error(&format!(
                "Failed to decode ValidatorTimelock upgrade call: {err}"
            ));
            1
        }
    }
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
        CtmFlavor::Era => {
            match genesis_config.genesis_rollup_leaf_index {
                Some(genesis_rollup_leaf_index) => {
                    if params.genesisIndexRepeatedStorageChanges != genesis_rollup_leaf_index {
                        result.report_error(&format!(
                            "Expected genesis index repeated storage changes to be {}, but got {}",
                            genesis_rollup_leaf_index, params.genesisIndexRepeatedStorageChanges
                        ));
                        errors += 1;
                    }
                }
                None => {
                    result.report_error(
                        "Era genesis config is missing required `genesis_rollup_leaf_index`",
                    );
                    errors += 1;
                }
            }

            match &genesis_config.genesis_batch_commitment {
                Some(genesis_batch_commitment) => {
                    if params.genesisBatchCommitment.to_string() != *genesis_batch_commitment {
                        result.report_error(&format!(
                            "Expected genesis batch commitment to be {}, but got {}",
                            genesis_batch_commitment, params.genesisBatchCommitment
                        ));
                        errors += 1;
                    }
                }
                None => {
                    result.report_error(
                        "Era genesis config is missing required `genesis_batch_commitment`",
                    );
                    errors += 1;
                }
            }
        }
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

    // Decode the chain-creation diamond cut's initCalldata and verify the three
    // bytecode hashes independently of the artifact hex.
    result.print_info(&format!(
        "-- InitializeDataNewChain field verification ({} setChainCreationParams) --",
        ctm.flavor.label()
    ));
    match InitializeDataNewChain::abi_decode(&params.diamondCut.initCalldata) {
        Ok(init_data) => init_data.verify(ctm.flavor, verifiers, result),
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
