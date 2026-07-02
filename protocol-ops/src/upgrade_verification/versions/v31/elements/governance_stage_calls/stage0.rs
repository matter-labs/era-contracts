//! Stage 0 — pre-upgrade governance calls.
//!
//! Stage-0 shape:
//!   `[ pauseMigration, startTimer (×N CTMs), <optional PUH-redeploy block>, <optional acceptOwnership tail> ]`
//!
//! The PUH-redeploy block is only emitted on **PUH-governed envs**
//! (`governance_kind = "puh"` in permanent-values — stage / mainnet today).
//! `upgrade-prepare-all` appends it via `puh_guardians::deploy_puh_guardians`
//! when `bridgehub.owner()` is a ProtocolUpgradeHandler proxy. It is four
//! calls, in this order:
//!   1. `upgradeAndCall(puh_proxy_admin, new_impl, "")` — swaps the PUH impl,
//!   2. `updateSecurityCouncil(new_security_council)`,
//!   3. `updateGuardians(new_guardians)`,
//!   4. `updateEmergencyUpgradeBoard(new_emergency_upgrade_board)`.
//!
//! The three `onlySelf` setters repoint the proxy at the freshly deployed
//! SecurityCouncil, Guardians and EmergencyUpgradeBoard (the board already
//! embeds the new SC + Guardians as immutables, so the set stays consistent).
//!
//! [`verify_puh_immutables`] reads every immutable getter on the *new* PUH
//! implementation and compares against either the current PUH (for "must-be-
//! unchanged" immutables) or an expected artifact-derived address (for newly
//! introduced immutables like `CHAIN_ASSET_HANDLER` and the per-flavor
//! `ERA_CHAIN_TYPE_MANAGER` / `ZKSYNC_OS_CHAIN_TYPE_MANAGER`).

use alloy::{
    hex,
    primitives::{Address, U256},
    sol_types::SolCall,
};
use anyhow::Context;

use crate::upgrade_verification::{
    artifacts::{CtmFlavor, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::helpers::{
    required_core_address, required_ctm_address, verify_address_has_code, verify_call_by_address,
    verify_call_by_name,
};
use super::{
    acceptOwnershipCall, updateEmergencyUpgradeBoardCall, updateGuardiansCall,
    updateSecurityCouncilCall, upgradeAndCallCall, CallList, GovernanceStage0Calls, Ownable2Step,
    ProtocolUpgradeHandler,
};

impl GovernanceStage0Calls {
    /// Stage 0 — pause migrations, start per-CTM upgrade timers, and (on
    /// PUH-governed envs) redeploy PUH/Guardians + accept deferred pendingOwner
    /// transfers.
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 0 calls ===");

        let mut errors = 0;
        // Call 0 — ChainAssetHandler.pauseMigration() freezes cross-chain
        // migrations during the upgrade window.
        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "pauseMigration()",
            verifiers,
            result,
        );

        // Calls 1..=N — per-CTM GovernanceUpgradeTimer.startTimer(), one per CTM.
        // The prepare emits these in env-config CTM order, which can differ from
        // `artifact.ctms` order, so match each CTM's timer to its startTimer call
        // by target (order-independent) rather than asserting a fixed position.
        let timer_window_end = (1 + artifact.ctms.len()).min(self.calls.elems.len());
        for ctm in artifact.ctms.iter() {
            let timer_label = format!("{}.upgrade_timer", ctm.flavor.label());
            let Some(timer) = required_ctm_address(
                ctm,
                &["deployed_addresses", "l1_governance_upgrade_timer"],
                result,
            ) else {
                errors += 1;
                continue;
            };
            match (1..timer_window_end).find(|&idx| self.calls.elems[idx].target == timer) {
                Some(idx) => {
                    errors += verify_call_by_address(
                        &self.calls,
                        idx,
                        timer,
                        &timer_label,
                        "startTimer()",
                        verifiers,
                        result,
                    );
                }
                None => {
                    result.report_error(&format!(
                        "Stage-0 startTimer() call for {timer_label} ({timer}) not found in the timer window [1, {timer_window_end})"
                    ));
                    errors += 1;
                }
            }
        }

        // Probe for PUH-governed env.
        let bridgehub_owner = verifiers.bridgehub_owner;
        let bridgehub_owner_admin = verifiers
            .network_verifier
            .get_proxy_admin(bridgehub_owner)
            .await;
        let puh_governed = bridgehub_owner_admin != Address::ZERO;

        let base_count = 1 + artifact.ctms.len();
        // `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
        // writes one deferred `acceptOwnership()` call per unique CTM whose
        // `pendingOwner` is governance at prepare time. Derive that target set
        // from live Bridgehub/CTM state and validate the stage-0 tail against
        // it (instead of matching by selector count only).
        let pre_gov_accept_targets = collect_pre_governance_accept_ownership_targets(
            artifact,
            verifiers,
            bridgehub_owner,
            result,
        )
        .await?;
        // PUH-redeploy block is 4 calls: upgradeAndCall + the three update*
        // setters (SecurityCouncil, Guardians, EmergencyUpgradeBoard).
        let pre_gov_accept_tail_start = if puh_governed {
            base_count + 4
        } else {
            base_count
        };
        let expected_call_count = pre_gov_accept_tail_start + pre_gov_accept_targets.len();

        if puh_governed {
            let expected_zk_governance = artifact.zk_governance.as_ref().context(
                "PUH-governed v31 artifact is missing required top-level [zk_governance] table",
            )?;
            // zk-governance redeploy block — PUH-governed envs only.
            // Call `base_count`     — PUH ProxyAdmin.upgradeAndCall(PUH proxy, new impl, "").
            // Call `base_count + 1` — PUH.updateSecurityCouncil(new security council).
            // Call `base_count + 2` — PUH.updateGuardians(new guardians).
            // Call `base_count + 3` — PUH.updateEmergencyUpgradeBoard(new board).
            let upgrade_idx = base_count;
            let update_security_council_idx = base_count + 1;
            let update_guardians_idx = base_count + 2;
            let update_emergency_board_idx = base_count + 3;
            // OZ v5 `TransparentUpgradeableProxyAdmin.upgradeAndCall` is the
            // selector used by `puh_guardians::encode_proxy_admin_upgrade` —
            // the v4 `upgrade(address,address)` selector reverts on the v5
            // admin. Data arg is empty (no follow-on call).
            errors += verify_call_by_address(
                &self.calls,
                upgrade_idx,
                bridgehub_owner_admin,
                "puh_proxy_admin",
                "upgradeAndCall(address,address,bytes)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(upgrade_idx) {
                match upgradeAndCallCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        if decoded.proxy != bridgehub_owner {
                            result.report_error(&format!(
                                "PUH upgrade call #{upgrade_idx} proxy arg {} does not match bridgehub.owner() {}",
                                decoded.proxy, bridgehub_owner
                            ));
                            errors += 1;
                        } else if decoded.implementation != expected_zk_governance.new_puh_impl {
                            result.report_error(&format!(
                                "PUH upgradeAndCall #{upgrade_idx} implementation {} does not match [zk_governance].new_puh_impl {}",
                                decoded.implementation, expected_zk_governance.new_puh_impl
                            ));
                            errors += 1;
                        } else if !decoded.data.is_empty() {
                            result.report_error(&format!(
                                "PUH upgradeAndCall #{upgrade_idx} data arg should be empty for a bare impl swap, got {} bytes",
                                decoded.data.len()
                            ));
                            errors += 1;
                        } else {
                            result.report_ok(&format!(
                                "PUH upgradeAndCall(proxy=bridgehub.owner()) → new impl {}",
                                decoded.implementation
                            ));
                            errors += verify_address_has_code(
                                &decoded.implementation,
                                "PUH new implementation",
                                verifiers,
                                result,
                            )
                            .await;
                            errors += verify_puh_immutables(
                                bridgehub_owner,
                                decoded.implementation,
                                artifact,
                                verifiers,
                                result,
                            )
                            .await?;
                        }
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode upgradeAndCall(...) at call #{upgrade_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
            errors += verify_call_by_address(
                &self.calls,
                update_security_council_idx,
                bridgehub_owner,
                "puh_proxy",
                "updateSecurityCouncil(address)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(update_security_council_idx) {
                match updateSecurityCouncilCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        result.report_ok(&format!(
                            "PUH updateSecurityCouncil(new={})",
                            decoded._newSecurityCouncil
                        ));
                        if decoded._newSecurityCouncil
                            == expected_zk_governance.new_security_council
                        {
                            result.report_ok(
                                "PUH updateSecurityCouncil target matches [zk_governance].new_security_council",
                            );
                        } else {
                            result.report_error(&format!(
                                "PUH updateSecurityCouncil #{update_security_council_idx} argument {} does not match [zk_governance].new_security_council {}",
                                decoded._newSecurityCouncil, expected_zk_governance.new_security_council
                            ));
                            errors += 1;
                        }
                        errors += verify_address_has_code(
                            &decoded._newSecurityCouncil,
                            "PUH new SecurityCouncil",
                            verifiers,
                            result,
                        )
                        .await;
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode updateSecurityCouncil(...) at call #{update_security_council_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
            errors += verify_call_by_address(
                &self.calls,
                update_guardians_idx,
                bridgehub_owner,
                "puh_proxy",
                "updateGuardians(address)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(update_guardians_idx) {
                match updateGuardiansCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        result.report_ok(&format!(
                            "PUH updateGuardians(new={})",
                            decoded._newGuardians
                        ));
                        if decoded._newGuardians == expected_zk_governance.new_guardians {
                            result.report_ok(
                                "PUH updateGuardians target matches [zk_governance].new_guardians",
                            );
                        } else {
                            result.report_error(&format!(
                                "PUH updateGuardians #{update_guardians_idx} argument {} does not match [zk_governance].new_guardians {}",
                                decoded._newGuardians, expected_zk_governance.new_guardians
                            ));
                            errors += 1;
                        }
                        errors += verify_address_has_code(
                            &decoded._newGuardians,
                            "PUH new Guardians",
                            verifiers,
                            result,
                        )
                        .await;
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode updateGuardians(...) at call #{update_guardians_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
            errors += verify_call_by_address(
                &self.calls,
                update_emergency_board_idx,
                bridgehub_owner,
                "puh_proxy",
                "updateEmergencyUpgradeBoard(address)",
                verifiers,
                result,
            );
            if let Some(call) = self.calls.elems.get(update_emergency_board_idx) {
                match updateEmergencyUpgradeBoardCall::abi_decode(&call.data) {
                    Ok(decoded) => {
                        result.report_ok(&format!(
                            "PUH updateEmergencyUpgradeBoard(new={})",
                            decoded._newEmergencyUpgradeBoard
                        ));
                        if decoded._newEmergencyUpgradeBoard
                            == expected_zk_governance.new_emergency_upgrade_board
                        {
                            result.report_ok(
                                "PUH updateEmergencyUpgradeBoard target matches [zk_governance].new_emergency_upgrade_board",
                            );
                        } else {
                            result.report_error(&format!(
                                "PUH updateEmergencyUpgradeBoard #{update_emergency_board_idx} argument {} does not match [zk_governance].new_emergency_upgrade_board {}",
                                decoded._newEmergencyUpgradeBoard, expected_zk_governance.new_emergency_upgrade_board
                            ));
                            errors += 1;
                        }
                        errors += verify_address_has_code(
                            &decoded._newEmergencyUpgradeBoard,
                            "PUH new EmergencyUpgradeBoard",
                            verifiers,
                            result,
                        )
                        .await;
                    }
                    Err(err) => {
                        result.report_error(&format!(
                            "Failed to decode updateEmergencyUpgradeBoard(...) at call #{update_emergency_board_idx}: {err}"
                        ));
                        errors += 1;
                    }
                }
            }
        }
        errors += verify_pre_governance_accept_ownership_tail(
            &self.calls,
            pre_gov_accept_tail_start,
            &pre_gov_accept_targets,
            verifiers,
            result,
        );

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
}

async fn collect_pre_governance_accept_ownership_targets(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    governance: Address,
    result: &mut VerificationResult,
) -> anyhow::Result<Vec<Address>> {
    // Candidates: the core ecosystem Ownable2Step contracts (AssetTracker,
    // ChainRegistrationSender) plus each CTM proxy with its ValidatorTimelock and
    // auxiliary ownership targets discovered from the generated artifact. v31's
    // prepare flow transfers any still-stale Ownable2Step contract to governance
    // and defers the accept to stage 0; include only candidates whose live
    // pendingOwner is governance at verify time. Both the core accepts and the
    // CTM-adjacent accepts flow through the same `ensureOwnable2StepTargets…` aux
    // mechanism, so they all land in (and are verified from) one trailing block.
    let mut candidates: Vec<Address> = Vec::new();
    for name in ["asset_tracker_proxy", "chain_registration_sender_proxy"] {
        match verifiers.address_verifier.get_by_name(name) {
            Some(addr) if addr != Address::ZERO => {
                if !candidates.contains(&addr) {
                    candidates.push(addr);
                }
            }
            _ => result.report_error(&format!(
                "{name} must be a known non-zero address while deriving stage-0 deferred acceptOwnership targets"
            )),
        }
    }
    for ctm in &artifact.ctms {
        if let Some(ctm_proxy) = required_ctm_address(
            ctm,
            &["state_transition", "chain_type_manager_proxy"],
            result,
        ) {
            if ctm_proxy == Address::ZERO {
                result.report_error(&format!(
                    "{}.chain_type_manager_proxy must not be zero while deriving stage-0 deferred acceptOwnership targets",
                    ctm.flavor.label()
                ));
            } else if !candidates.contains(&ctm_proxy) {
                candidates.push(ctm_proxy);
            }
        }
        if let Some(vt) = required_ctm_address(
            ctm,
            &["state_transition", "validator_timelock_addr"],
            result,
        ) {
            if vt != Address::ZERO && !candidates.contains(&vt) {
                candidates.push(vt);
            }
        }
        if let Some(timer) = required_ctm_address(
            ctm,
            &["deployed_addresses", "l1_governance_upgrade_timer"],
            result,
        ) {
            if timer != Address::ZERO && !candidates.contains(&timer) {
                candidates.push(timer);
            }
        }
        if ctm.value.get("rollup_da_pair").is_none() {
            if let Some(rollup_da_manager) =
                required_ctm_address(ctm, &["deployed_addresses", "l1_rollup_da_manager"], result)
            {
                if rollup_da_manager != Address::ZERO && !candidates.contains(&rollup_da_manager) {
                    candidates.push(rollup_da_manager);
                }
            }
        }
        if ctm.flavor == CtmFlavor::ZksyncOs {
            if let Some(verifier) =
                required_ctm_address(ctm, &["state_transition", "verifier_addr"], result)
            {
                if verifier != Address::ZERO && !candidates.contains(&verifier) {
                    candidates.push(verifier);
                }
            }
        }
    }

    let provider = verifiers.network_verifier.get_l1_provider();
    let mut targets = Vec::new();
    for candidate in candidates {
        let ownable = Ownable2Step::new(candidate, provider.clone());
        // The prepare flow transfers every still-non-governance-owned Ownable2Step
        // candidate to governance and emits a deferred `acceptOwnership()` for it,
        // while contracts already owned by governance get neither. So the expected
        // accept set is exactly the candidates whose live `owner()` is not
        // governance — independent of whether the transfer has already been
        // initiated (`pendingOwner == governance`, e.g. on a governance-replayed
        // fork) or is still pending an out-of-band step (e.g. an Atlas CTM and its
        // ValidatorTimelock / RollupDAManager owned by a legacy Governance, when
        // verifying raw against live before that ceremony runs). The live ownership
        // and transfer-progress state itself is verified separately in `rpc_state`
        // (`verify_v31_validator_timelocks` / `verify_v31_rollup_da_managers` / …),
        // so we deliberately do not re-flag it here.
        let owner = ownable.owner().call().await.with_context(|| {
            format!(
                "read owner() for {candidate} while deriving stage-0 deferred acceptOwnership targets"
            )
        })?;
        if owner != governance {
            targets.push(candidate);
        }
    }

    Ok(targets)
}

fn verify_pre_governance_accept_ownership_tail(
    calls: &CallList,
    tail_start: usize,
    expected_targets: &[Address],
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let accept_ownership_selector = acceptOwnershipCall::SELECTOR;
    let mut errors = 0usize;
    let mut seen_targets = Vec::new();

    for (index, call) in calls.elems.iter().enumerate() {
        let is_accept = call.data.len() >= 4 && call.data[0..4] == accept_ownership_selector;

        if index < tail_start && is_accept {
            result.report_error(&format!(
                "Deferred acceptOwnership() call found before stage-0 tail at index {index}"
            ));
            errors += 1;
        }

        if index < tail_start {
            continue;
        }

        if !is_accept {
            result.report_error(&format!(
                "Stage-0 deferred tail call #{index} must be acceptOwnership(), got selector 0x{}",
                hex::encode(&call.data[0..4.min(call.data.len())])
            ));
            errors += 1;
            continue;
        }
        if call.value != U256::ZERO {
            result.report_error(&format!(
                "Deferred acceptOwnership() call #{index} must have zero value, got {}",
                call.value
            ));
            errors += 1;
        }
        if call.data.len() != 4 {
            result.report_error(&format!(
                "Deferred acceptOwnership() call #{index} should have empty args (4-byte selector only), got {} bytes",
                call.data.len()
            ));
            errors += 1;
        }
        if !expected_targets.contains(&call.target) {
            result.report_error(&format!(
                "Deferred acceptOwnership() call #{index} targets unexpected address {} ({})",
                call.target,
                verifiers.address_verifier.name_or_unknown(&call.target)
            ));
            errors += 1;
            continue;
        }
        if seen_targets.contains(&call.target) {
            result.report_error(&format!(
                "Deferred acceptOwnership() call #{index} repeats target {}",
                call.target
            ));
            errors += 1;
        } else {
            seen_targets.push(call.target);
        }
    }

    let missing_targets: Vec<Address> = expected_targets
        .iter()
        .copied()
        .filter(|target| !seen_targets.contains(target))
        .collect();
    if !missing_targets.is_empty() {
        let missing = missing_targets
            .iter()
            .map(|address| {
                format!(
                    "{} ({})",
                    address,
                    verifiers.address_verifier.name_or_unknown(address)
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        result.report_error(&format!(
            "Stage-0 deferred acceptOwnership tail is missing expected target(s): {missing}"
        ));
        errors += 1;
    } else {
        result.report_ok(&format!(
            "Stage-0 deferred acceptOwnership tail matches {} expected target(s)",
            expected_targets.len()
        ));
    }

    errors
}

async fn verify_puh_immutables(
    current_puh_addr: Address,
    new_impl_addr: Address,
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let initial_error_count = result.errors;
    let provider = verifiers.network_verifier.get_l1_provider();
    let current_puh = ProtocolUpgradeHandler::new(current_puh_addr, provider.clone());
    let new_impl = ProtocolUpgradeHandler::new(new_impl_addr, provider.clone());

    compare_puh_shared_address(
        result,
        "PUH.L2_PROTOCOL_GOVERNOR()",
        current_puh.L2_PROTOCOL_GOVERNOR().call().await,
        new_impl.L2_PROTOCOL_GOVERNOR().call().await,
    );
    compare_puh_shared_address(
        result,
        "PUH.CHAIN_TYPE_MANAGER()",
        current_puh.CHAIN_TYPE_MANAGER().call().await,
        new_impl.CHAIN_TYPE_MANAGER().call().await,
    );
    compare_puh_shared_address(
        result,
        "PUH.BRIDGE_HUB()",
        current_puh.BRIDGE_HUB().call().await,
        new_impl.BRIDGE_HUB().call().await,
    );
    compare_puh_shared_address(
        result,
        "PUH.L1_NULLIFIER()",
        current_puh.L1_NULLIFIER().call().await,
        new_impl.L1_NULLIFIER().call().await,
    );
    compare_puh_shared_address(
        result,
        "PUH.L1_ASSET_ROUTER()",
        current_puh.L1_ASSET_ROUTER().call().await,
        new_impl.L1_ASSET_ROUTER().call().await,
    );
    compare_puh_shared_address(
        result,
        "PUH.L1_NATIVE_TOKEN_VAULT()",
        current_puh.L1_NATIVE_TOKEN_VAULT().call().await,
        new_impl.L1_NATIVE_TOKEN_VAULT().call().await,
    );

    let expected_chain_asset_handler = required_core_address(
        artifact,
        &[
            "upgrade_addresses",
            "bridgehub",
            "chain_asset_handler_proxy_addr",
        ],
        result,
    );
    if let Some(expected) = expected_chain_asset_handler {
        match new_impl.CHAIN_ASSET_HANDLER().call().await {
            Ok(actual) => {
                compare_puh_expected_address(result, "PUH.CHAIN_ASSET_HANDLER()", actual, expected)
            }
            Err(err) => result.report_error(&format!(
                "Failed to call new PUH.CHAIN_ASSET_HANDLER(): {err}"
            )),
        }
    }

    if let Some(era_ctm) = artifact
        .ctms
        .iter()
        .find(|ctm| ctm.flavor == CtmFlavor::Era)
    {
        let expected = required_ctm_address(
            era_ctm,
            &["state_transition", "chain_type_manager_proxy"],
            result,
        );
        if let Some(expected) = expected {
            match new_impl.ERA_CHAIN_TYPE_MANAGER().call().await {
                Ok(actual) => compare_puh_expected_address(
                    result,
                    "PUH.ERA_CHAIN_TYPE_MANAGER()",
                    actual,
                    expected,
                ),
                Err(err) => result.report_error(&format!(
                    "Failed to call new PUH.ERA_CHAIN_TYPE_MANAGER(): {err}"
                )),
            }
        }
    }

    if let Some(zkos_ctm) = artifact
        .ctms
        .iter()
        .find(|ctm| ctm.flavor == CtmFlavor::ZksyncOs)
    {
        let expected = required_ctm_address(
            zkos_ctm,
            &["state_transition", "chain_type_manager_proxy"],
            result,
        );
        if let Some(expected) = expected {
            match new_impl.ZKSYNC_OS_CHAIN_TYPE_MANAGER().call().await {
                Ok(actual) => compare_puh_expected_address(
                    result,
                    "PUH.ZKSYNC_OS_CHAIN_TYPE_MANAGER()",
                    actual,
                    expected,
                ),
                Err(err) => result.report_error(&format!(
                    "Failed to call new PUH.ZKSYNC_OS_CHAIN_TYPE_MANAGER(): {err}"
                )),
            }
        }
    }

    let expected_era_chain_id = verifiers.era_chain_id;
    match new_impl.ERA_CHAIN_ID().call().await {
        Ok(actual) if actual == U256::from(expected_era_chain_id) => result.report_ok(&format!(
            "PUH.ERA_CHAIN_ID() matches env era_chain_id ({expected_era_chain_id})"
        )),
        Ok(actual) => result.report_error(&format!(
            "PUH.ERA_CHAIN_ID() mismatch: expected {expected_era_chain_id}, got {actual}"
        )),
        Err(err) => result.report_error(&format!("Failed to call new PUH.ERA_CHAIN_ID(): {err}")),
    }

    Ok((result.errors - initial_error_count) as usize)
}

fn compare_puh_shared_address(
    result: &mut VerificationResult,
    label: &str,
    current: std::result::Result<Address, impl std::fmt::Display>,
    new: std::result::Result<Address, impl std::fmt::Display>,
) {
    match (current, new) {
        (Ok(current), Ok(new)) if current == new => {
            result.report_ok(&format!("{label} is unchanged ({new})"));
        }
        (Ok(current), Ok(new)) => result.report_error(&format!(
            "{label} mismatch: current PUH {current}, new implementation {new}"
        )),
        (Err(err), _) => result.report_error(&format!(
            "Failed to call current {label} for PUH immutable checks: {err}"
        )),
        (_, Err(err)) => result.report_error(&format!(
            "Failed to call new implementation {label} for PUH immutable checks: {err}"
        )),
    }
}

fn compare_puh_expected_address(
    result: &mut VerificationResult,
    label: &str,
    actual: Address,
    expected: Address,
) {
    if actual == expected {
        result.report_ok(&format!("{label} matches expected address ({expected})"));
    } else {
        result.report_error(&format!(
            "{label} mismatch: expected {expected}, got {actual}"
        ));
    }
}
