//! Stage 2 — post-upgrade governance calls.
//!
//! Canonical shape:
//!   `[ unpauseMigration, (checkProtocolUpgradePresence, checkMigrationsUnpaused) × N CTMs ]`
//!
//! When `[new_gateway]` is present in the merged ecosystem TOML,
//! [`verify_gateway_bring_up_calls`] handles the 15-call appendix that
//! `write_merged_ecosystem_toml` appends (registerLegacyToken prefix +
//! GatewayVotePreparation block: approve-then-priority-tx for
//! `addChainTypeManager`, `setAssetDeploymentTracker`, `registerCTMAssetOnL1`,
//! two-bridges set-asset-handler calls, RollupDAManager/ServerNotifier
//! ownership accepts, and the new GW settlement-fee setter).

use std::str::FromStr;

use alloy::{
    hex,
    primitives::{Address, U256},
    sol_types::SolValue,
};

use crate::upgrade_verification::{
    artifacts::EcosystemUpgradeArtifact,
    verifiers::{VerificationResult, Verifiers},
};

use super::super::super::utils::compute_selector;
use super::helpers::{required_ctm_address, verify_call_by_address, verify_call_by_name};
use super::{CallList, GovernanceStage2Calls, L2TransactionRequestDirect};

impl GovernanceStage2Calls {
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        let mut errors = 0;
        let canonical_count = 1 + artifact.ctms.len() * 2;
        let gw_count = if artifact.new_gateway.is_some() {
            15
        } else {
            0
        };
        let expected_call_count = canonical_count + gw_count;

        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "unpauseMigration()",
            verifiers,
            result,
        );

        for (ctm_index, ctm) in artifact.ctms.iter().enumerate() {
            let validator_label = format!("{}.upgrade_stage_validator", ctm.flavor.label());
            let Some(validator) = required_ctm_address(
                ctm,
                &["deployed_addresses", "upgrade_stage_validator"],
                result,
            ) else {
                errors += 2;
                continue;
            };

            let block = 1 + ctm_index * 2;
            errors += verify_call_by_address(
                &self.calls,
                block,
                validator,
                &validator_label,
                "checkProtocolUpgradePresence()",
                verifiers,
                result,
            );
            errors += verify_call_by_address(
                &self.calls,
                block + 1,
                validator,
                &validator_label,
                "checkMigrationsUnpaused()",
                verifiers,
                result,
            );
        }

        if let Some(new_gw) = artifact.new_gateway.as_ref() {
            errors += verify_gateway_bring_up_calls(
                &self.calls,
                canonical_count,
                artifact,
                new_gw,
                verifiers,
                result,
            )
            .await;
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

/// Verify the 15-call new-Gateway bring-up block. Checks each call's
/// (target, selector); for approve calls cross-checks they all target the
/// same base token; for priority txs cross-checks they all target the same
/// L2 chain id; and deep-decodes the three `requestL2TransactionDirect`
/// calls whose inner args we can derive from the artifact (`addChainTypeManager`,
/// `acceptOwnership` on RollupDAManager + ServerNotifier).
#[allow(clippy::too_many_arguments)]
async fn verify_gateway_bring_up_calls(
    calls: &CallList,
    base: usize,
    artifact: &EcosystemUpgradeArtifact,
    _new_gw: &crate::upgrade_verification::artifacts::NewGatewayArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    result.print_info("== Gov stage 2 new-Gateway bring-up ===");

    // (offset, target_name, method_signature)
    let direct = "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))";
    let two_bridges =
        "requestL2TransactionTwoBridges((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))";
    let expected: &[(usize, &str, &str)] = &[
        // L1AssetTracker.registerLegacyToken(zkAssetId) — prefix prepended
        // by `write_merged_ecosystem_toml` when `[new_gateway]` is present.
        (0, "asset_tracker_proxy", "registerLegacyToken(bytes32)"),
        // addChainTypeManager L1→L2 (priority tx) — approve + direct.
        (2, "bridgehub_proxy", direct),
        // setAssetDeploymentTracker on L1AssetRouter (L1-side, no approve).
        (
            3,
            "l1_asset_router_proxy",
            "setAssetDeploymentTracker(bytes32,address)",
        ),
        // registerCTMAssetOnL1 on L1CTMDeploymentTracker (L1-side).
        (
            4,
            "ctm_deployment_tracker_proxy",
            "registerCTMAssetOnL1(address)",
        ),
        // setAssetHandler for chain assetId — approve + two-bridges.
        (6, "bridgehub_proxy", two_bridges),
        // chain-asset-handler registration for GW CTM — approve + two-bridges.
        (8, "bridgehub_proxy", two_bridges),
        // acceptOwnership on RollupDAManager — approve + direct.
        (10, "bridgehub_proxy", direct),
        // acceptOwnership on ServerNotifier — approve + direct.
        (12, "bridgehub_proxy", direct),
        // setGatewaySettlementFee on GW_ASSET_TRACKER_ADDR — approve + direct.
        (14, "bridgehub_proxy", direct),
    ];

    let mut errors = 0;
    for (offset, target_name, method) in expected {
        errors += verify_call_by_name(calls, base + offset, target_name, method, verifiers, result);
    }

    // All approve calls in this block target the same ZK base-token address.
    // Their selector is `approve(address,uint256)` (0x095ea7b3) and the
    // spender is the L1AssetRouter — we check selector + cross-call target
    // consistency. The token's absolute address would need an extra RPC
    // round-trip (NTV.tokenAddress(zkAssetId)); cross-call consistency is
    // a sufficient shape check.
    let approve_selector = compute_selector("approve(address,uint256)");
    let approve_offsets = [1usize, 5, 7, 9, 11, 13];
    let mut approve_target: Option<Address> = None;
    for off in &approve_offsets {
        let idx = base + *off;
        let Some(call) = calls.elems.get(idx) else {
            result.report_error(&format!("Expected approve call #{idx} not found"));
            errors += 1;
            continue;
        };
        if call.data.len() < 4 || hex::encode(&call.data[0..4]) != approve_selector {
            result.report_error(&format!(
                "Call #{idx}: expected approve(address,uint256) selector 0x{approve_selector}, got 0x{}",
                hex::encode(&call.data[0..4.min(call.data.len())])
            ));
            errors += 1;
            continue;
        }
        match approve_target {
            None => approve_target = Some(call.target),
            Some(t) if t != call.target => {
                result.report_error(&format!(
                    "Approve call #{idx} target {} differs from earlier approve target {} — GW bring-up should approve a single base token",
                    call.target, t,
                ));
                errors += 1;
            }
            _ => {}
        }
    }
    if let Some(t) = approve_target {
        result.report_ok(&format!(
            "All 6 GW priority-tx approve calls target the same base token {t}"
        ));
    }

    // `chainId` is the first 32-byte field of every priority-tx struct
    // (both L2TransactionRequestDirect and L2TransactionRequestTwoBridgesOuter).
    // Decode + cross-check that every priority tx targets the SAME L2 chain.
    let priority_offsets = [2usize, 6, 8, 10, 12, 14];
    let mut priority_chain_id: Option<U256> = None;
    for off in &priority_offsets {
        let idx = base + *off;
        let Some(call) = calls.elems.get(idx) else {
            continue; // already counted as missing above
        };
        // ABI: 4-byte selector, then 32-byte offset to struct, then the
        // struct's first word = `chainId`.
        if call.data.len() < 4 + 32 + 32 {
            continue;
        }
        let chain_id_bytes: [u8; 32] = call.data[4 + 32..4 + 32 + 32]
            .try_into()
            .expect("32-byte chainId slice");
        let chain_id = U256::from_be_bytes(chain_id_bytes);
        match priority_chain_id {
            None => priority_chain_id = Some(chain_id),
            Some(prior) if prior != chain_id => {
                result.report_error(&format!(
                    "Priority tx #{idx} chainId {chain_id} differs from earlier priority tx chainId {prior} — GW bring-up should target a single L2 (the new gateway)",
                ));
                errors += 1;
            }
            _ => {}
        }
    }
    if let Some(cid) = priority_chain_id {
        result.report_ok(&format!(
            "All 6 GW priority txs target the same L2 chain id {cid}"
        ));
    }

    // Deep cross-check on the three `requestL2TransactionDirect` priority
    // txs whose targets/args we know how to derive from the artifact:
    //   - offset 2:  L2 Bridgehub ← addChainTypeManager(new_gw_ctm)
    //   - offset 10: GW RollupDAManager ← acceptOwnership()
    //   - offset 12: GW ServerNotifier ← acceptOwnership()
    // The remaining priority txs (offsets 6/8 two-bridges, 14 setSettlementFee)
    // are *not* deep-decoded yet — see follow-up note at the end of this fn.
    // L2 Bridgehub lives at the system-contract slot 0x10002 (see
    // `constants::L2_BRIDGEHUB_ADDR`).
    let l2_bridgehub_addr = Address::from_str("0x0000000000000000000000000000000000010002").ok();
    let check_direct_inner = |idx_offset: usize,
                              expected_target_label: &str,
                              expected_target: Option<Address>,
                              expected_selector_sig: &str,
                              expected_arg: Option<Address>,
                              errors: &mut usize,
                              result: &mut VerificationResult| {
        let idx = base + idx_offset;
        let Some(call) = calls.elems.get(idx) else {
            return;
        };
        // Skip the 4-byte requestL2TransactionDirect selector + 32-byte
        // tuple offset.
        let payload = match call.data.len().checked_sub(4) {
            Some(n) if n > 0 => &call.data[4..],
            _ => return,
        };
        let Ok(req) = L2TransactionRequestDirect::abi_decode(payload) else {
            result.report_warn(&format!(
                "Could not decode L2TransactionRequestDirect for GW priority tx #{idx}; skipping inner cross-check"
            ));
            return;
        };
        if let Some(expected) = expected_target {
            if req.l2Contract != expected {
                result.report_error(&format!(
                    "GW priority tx #{idx} ({expected_target_label}) l2Contract mismatch: expected {expected}, got {}",
                    req.l2Contract
                ));
                *errors += 1;
            } else {
                result.report_ok(&format!(
                    "GW priority tx #{idx} ({expected_target_label}) l2Contract matches"
                ));
            }
        }
        if req.l2Calldata.len() < 4 {
            return;
        }
        let actual_sel = hex::encode(&req.l2Calldata[0..4]);
        let expected_sel = compute_selector(expected_selector_sig);
        if actual_sel != expected_sel {
            result.report_error(&format!(
                "GW priority tx #{idx} ({expected_target_label}) inner selector mismatch: expected {expected_selector_sig} (0x{expected_sel}), got 0x{actual_sel}"
            ));
            *errors += 1;
            return;
        }
        if let Some(expected_arg) = expected_arg {
            if req.l2Calldata.len() >= 4 + 32 {
                let arg_bytes: [u8; 32] = req.l2Calldata[4..36].try_into().unwrap();
                let actual_arg = Address::from_slice(&arg_bytes[12..]);
                if actual_arg != expected_arg {
                    result.report_error(&format!(
                        "GW priority tx #{idx} ({expected_target_label}) {expected_selector_sig} arg mismatch: expected {expected_arg}, got {actual_arg}"
                    ));
                    *errors += 1;
                } else {
                    result.report_ok(&format!(
                        "GW priority tx #{idx} ({expected_target_label}) {expected_selector_sig}({actual_arg}) matches"
                    ));
                }
            }
        }
    };

    let new_gw_ctm = _new_gw.gateway_chain_type_manager_addr;
    check_direct_inner(
        2,
        "addChainTypeManager",
        l2_bridgehub_addr,
        "addChainTypeManager(address)",
        Some(new_gw_ctm),
        &mut errors,
        result,
    );
    check_direct_inner(
        10,
        "acceptOwnership RollupDAManager",
        _new_gw.gateway_rollup_da_manager_addr,
        "acceptOwnership()",
        None,
        &mut errors,
        result,
    );
    check_direct_inner(
        12,
        "acceptOwnership ServerNotifier",
        _new_gw.gateway_server_notifier_addr,
        "acceptOwnership()",
        None,
        &mut errors,
        result,
    );

    // Touch the artifact so future extensions (e.g. cross-checking
    // setSettlementFee's fee value, decoding the two-bridges payloads) can
    // pull additional context from it without churn.
    let _ = artifact;
    errors
}
