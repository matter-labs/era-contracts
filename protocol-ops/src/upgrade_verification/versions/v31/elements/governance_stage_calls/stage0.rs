//! Stage 0 — pre-upgrade governance calls.
//!
//! Stage-0 shape:
//!   `[ pauseMigration, startTimer (×N CTMs), <optional PUH-redeploy pair>, <optional acceptOwnership tail> ]`
//!
//! The PUH-redeploy pair (`upgradeAndCall(puh_proxy_admin, new_impl, "")` +
//! `updateGuardians(new_guardians)`) is only emitted on **PUH-governed envs**
//! (`governance_kind = "puh"` in permanent-values — stage / mainnet today).
//! `upgrade-prepare-all` appends it via `puh_guardians::deploy_puh_guardians`
//! when `bridgehub.owner()` is a ProtocolUpgradeHandler proxy: first call
//! upgrades the PUH implementation on its ProxyAdmin, second call rewires
//! the new Guardians on the proxy itself.
//!
//! [`verify_puh_immutables`] reads every immutable getter on the *new* PUH
//! implementation and compares against either the current PUH (for "must-be-
//! unchanged" immutables) or an expected artifact-derived address (for newly
//! introduced immutables like `CHAIN_ASSET_HANDLER` and the per-flavor
//! `ERA_CHAIN_TYPE_MANAGER` / `ZKSYNC_OS_CHAIN_TYPE_MANAGER`).

use alloy::{
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
    updateGuardiansCall, upgradeAndCallCall, BridgehubOwnerView, GovernanceStage0Calls,
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

        // Calls 1..=N — per-CTM GovernanceUpgradeTimer.startTimer().
        // One call per `[ctms.<flavor>]` block, in artifact order.
        for (ctm_index, ctm) in artifact.ctms.iter().enumerate() {
            let timer_label = format!("{}.upgrade_timer", ctm.flavor.label());
            if let Some(timer) = required_ctm_address(
                ctm,
                &["deployed_addresses", "l1_governance_upgrade_timer"],
                result,
            ) {
                errors += verify_call_by_address(
                    &self.calls,
                    1 + ctm_index,
                    timer,
                    &timer_label,
                    "startTimer()",
                    verifiers,
                    result,
                );
            } else {
                errors += 1;
            }
        }

        // Probe for PUH-governed env.
        let bridgehub_owner = BridgehubOwnerView::new(
            verifiers.bridgehub_address,
            verifiers.network_verifier.get_l1_provider(),
        )
        .owner()
        .call()
        .await
        .context("read Bridgehub.owner() to detect PUH-governed env")?;
        let bridgehub_owner_admin = verifiers
            .network_verifier
            .get_proxy_admin(bridgehub_owner)
            .await;
        let puh_governed = bridgehub_owner_admin != Address::ZERO;

        let base_count = 1 + artifact.ctms.len();
        // `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
        // defers `acceptOwnership()` for each CTM whose pendingOwner is PUH
        // into stage 0 (via `pre-governance-accept-ownerships.toml`). Count
        // them by selector so PUVT doesn't false-error when the prior
        // transferOwnership ceremony left pendingOwners outstanding.
        let accept_ownership_selector: [u8; 4] = [0x79, 0xba, 0x50, 0x97];
        let pre_gov_accept_count = self
            .calls
            .elems
            .iter()
            .filter(|c| c.data.len() >= 4 && c.data[..4] == accept_ownership_selector)
            .count();
        let expected_call_count = if puh_governed {
            base_count + 2 + pre_gov_accept_count
        } else {
            base_count + pre_gov_accept_count
        };

        if puh_governed {
            // PUH/Guardians redeploy pair — PUH-governed envs only.
            // Call `base_count` — PUH ProxyAdmin.upgradeAndCall(PUH proxy, new impl, "").
            // Call `base_count + 1` — PUH.updateGuardians(new guardians).
            let upgrade_idx = base_count;
            let update_guardians_idx = base_count + 1;
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
        }

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

    if let Some(expected_era_chain_id) = verifiers.representative_era_chain_id {
        match new_impl.ERA_CHAIN_ID().call().await {
            Ok(actual) if actual == U256::from(expected_era_chain_id) => result.report_ok(
                &format!("PUH.ERA_CHAIN_ID() matches env era_chain_id ({expected_era_chain_id})"),
            ),
            Ok(actual) => result.report_error(&format!(
                "PUH.ERA_CHAIN_ID() mismatch: expected {expected_era_chain_id}, got {actual}"
            )),
            Err(err) => {
                result.report_error(&format!("Failed to call new PUH.ERA_CHAIN_ID(): {err}"))
            }
        }
    } else {
        result.report_error("Cannot verify PUH.ERA_CHAIN_ID(): env era_chain_id was not loaded");
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
