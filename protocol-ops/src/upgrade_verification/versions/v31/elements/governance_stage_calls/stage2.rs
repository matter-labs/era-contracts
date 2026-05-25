//! Stage 2 — post-upgrade governance calls.
//!
//! Canonical shape:
//!   `[ (setHistoricalMigrationInterval × M, setSettlementLayerStatus)?,
//!      unpauseMigration,
//!      (checkProtocolUpgradePresence, checkMigrationsUnpaused) × N CTMs ]`
//!
//! The legacy-GW decommission prefix (M interval calls + 1 blacklist) is
//! present when `permanent-values/<env>.toml` carries a `[legacy_gateway]`
//! section. M equals the number of `[[legacy_gateway.chain_intervals]]`
//! entries and is env-dependent, so the verifier scans dynamically.
//!
//! [`verify_gateway_bring_up_calls`] handles the mandatory 16-call new-Gateway
//! appendix that `write_merged_ecosystem_toml` appends (registerLegacyToken
//! prefix + new-GW whitelist via `setSettlementLayerStatus` + GatewayVotePreparation
//! block: approve-then-priority-tx for `addChainTypeManager`,
//! `setAssetDeploymentTracker`, `registerCTMAssetOnL1`, two-bridges
//! set-asset-handler calls, RollupDAManager/ServerNotifier ownership accepts,
//! and the new GW settlement-fee setter).

use alloy::{
    hex,
    primitives::{keccak256, Address, Bytes, FixedBytes, U256},
    sol,
    sol_types::{SolCall, SolValue},
};

use crate::{
    common::env_config::ChainInterval,
    upgrade_verification::{
        artifacts::{EcosystemUpgradeArtifact, NewGatewayArtifact},
        constants::{
            GW_ASSET_TRACKER_ADDR, L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR,
            L2_CHAIN_ASSET_HANDLER_ADDR, L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT,
        },
        verifiers::{VerificationResult, Verifiers},
        versions::v31::MAX_PRIORITY_TX_GAS_LIMIT,
    },
};

use super::super::super::utils::compute_selector;

sol! {
    /// Mirrors `IChainAssetHandler.sol::MigrationInterval`. PUVT decodes
    /// every stage-2 `setHistoricalMigrationInterval` call's third arg into
    /// this struct so the per-field invariants can be cross-checked against
    /// `[[legacy_gateway.chain_intervals]]` in `permanent-values/<env>.toml`.
    #[derive(Debug)]
    struct MigrationInterval {
        uint256 migrateToGWBatchNumber;
        uint256 migrateFromGWBatchNumber;
        uint256 settlementLayerBatchLowerBound;
        uint256 settlementLayerBatchUpperBound;
        uint256 settlementLayerChainId;
        bool isActive;
    }
    function setHistoricalMigrationInterval(
        uint256 chainId,
        uint256 migrationNumber,
        MigrationInterval interval,
    );

    /// Stage-2 uses this twice with different `(chainId, status)`:
    /// `(legacy_gw, false)` in the decommission tail and
    /// `(new_gw, true)` in the new-GW bring-up appendix.
    function setSettlementLayerStatus(uint256 chainId, bool status);
}
use super::helpers::{required_ctm_address, verify_call_by_address, verify_call_by_name};
use super::{
    CallList, GovernanceStage2Calls, L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter,
};

impl GovernanceStage2Calls {
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        let mut errors = 0;

        // ── Legacy-GW decommission prefix (dynamic) ──────────────────
        // v31 `CoreUpgrade` prepends `N × setHistoricalMigrationInterval`
        // followed by one `setSettlementLayerStatus(legacy_gw_chain_id, false)`
        // before the canonical `unpauseMigration`. N is env-dependent
        // (`permanent-values/<env>.toml`'s `[[legacy_gateway.chain_intervals]]`),
        // so scan the head of the call list dynamically. Anything else stays
        // exactly where the canonical shape says it should be, just shifted
        // by `canonical_prefix`.
        let set_historical_selector = compute_selector(
            "setHistoricalMigrationInterval(uint256,uint256,(uint256,uint256,uint256,uint256,uint256,bool))",
        );
        let set_settlement_selector = compute_selector("setSettlementLayerStatus(uint256,bool)");

        let expected_intervals = &verifiers.legacy_gateway_chain_intervals;
        let expected_settlement_chain_id = U256::from(verifiers.legacy_gateway_chain_id);
        let mut decommission_count: usize = 0;
        for call in &self.calls.elems {
            if call.data.len() < 4
                || hex::encode(&call.data[0..4]) != set_historical_selector
            {
                break;
            }
            match expected_intervals.get(decommission_count) {
                Some(expected) => {
                    errors += check_historical_migration_interval(
                        decommission_count,
                        &call.data,
                        expected,
                        expected_settlement_chain_id,
                        result,
                    );
                }
                None => {
                    result.report_error(&format!(
                        "Stage 2 has more setHistoricalMigrationInterval calls than \
                         [[legacy_gateway.chain_intervals]] entries; unexpected call at index {decommission_count}"
                    ));
                    errors += 1;
                }
            }
            decommission_count += 1;
        }
        if decommission_count != expected_intervals.len() {
            result.report_error(&format!(
                "Stage 2 has {} setHistoricalMigrationInterval call(s) but env declares {} \
                 [[legacy_gateway.chain_intervals]] entries",
                decommission_count,
                expected_intervals.len(),
            ));
            errors += 1;
        }
        if decommission_count > 0 {
            result.report_ok(&format!(
                "Stage 2 decommission prefix: verified {decommission_count} \
                 setHistoricalMigrationInterval call(s) against [[legacy_gateway.chain_intervals]]"
            ));
            // Expect setSettlementLayerStatus(oldGwChainId, false) immediately
            // after the interval calls — blacklists the legacy GW.
            if decommission_count < self.calls.elems.len() {
                let call = &self.calls.elems[decommission_count];
                if call.data.len() >= 4
                    && hex::encode(&call.data[0..4]) == set_settlement_selector
                {
                    errors += verify_call_by_name(
                        &self.calls,
                        decommission_count,
                        "bridgehub_proxy",
                        "setSettlementLayerStatus(uint256,bool)",
                        verifiers,
                        result,
                    );
                    errors += check_set_settlement_layer_status(
                        decommission_count,
                        &call.data,
                        U256::from(verifiers.legacy_gateway_chain_id),
                        false,
                        "legacy GW blacklist",
                        result,
                    );
                    decommission_count += 1;
                } else {
                    result.report_error(
                        "Expected setSettlementLayerStatus(uint256,bool) after historical migration intervals",
                    );
                    errors += 1;
                }
            }
        }

        let canonical_prefix = decommission_count;
        let canonical_count = canonical_prefix + 1 + artifact.ctms.len() * 2;
        let expected_call_count = canonical_count + 16;

        errors += verify_call_by_name(
            &self.calls,
            canonical_prefix,
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

            let block = canonical_prefix + 1 + ctm_index * 2;
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

        match artifact.new_gateway.as_ref() {
            Some(new_gw) => {
                errors += verify_gateway_bring_up_calls(
                    &self.calls,
                    canonical_count,
                    new_gw,
                    verifiers,
                    result,
                )
                .await;
            }
            None => {
                result.report_error("v31 verification requires a [new_gateway] artifact block");
                errors += 1;
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

/// Verify the 16-call new-Gateway bring-up block.
///
/// This is the stage-2 appendix that bridges setup calls to the new Gateway
/// before the ecosystem upgrade is executed. The env config is the authority
/// for the target Gateway chain id, settlement fee, representative CTM and
/// priority-tx gas limit.
///
/// Block layout (offsets are relative to `base`):
///   0: registerLegacyToken(zkAssetId)
///   1: setSettlementLayerStatus(newGwChainId, true)  ← whitelist new GW
///   2: approve + 3: addChainTypeManager (direct)
///   4: setAssetDeploymentTracker
///   5: registerCTMAssetOnL1
///   6: approve + 7: setAssetHandler (two-bridges)
///   8: approve + 9: setCTMAssetAddress (two-bridges)
///  10: approve + 11: acceptOwnership RollupDAManager (direct)
///  12: approve + 13: acceptOwnership ServerNotifier (direct)
///  14: approve + 15: setGatewaySettlementFee (direct)
#[allow(clippy::too_many_arguments)]
async fn verify_gateway_bring_up_calls(
    calls: &CallList,
    base: usize,
    new_gw: &NewGatewayArtifact,
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
        // Whitelist the new Gateway as a settlement layer on L1 Bridgehub.
        (
            1,
            "bridgehub_proxy",
            "setSettlementLayerStatus(uint256,bool)",
        ),
        // addChainTypeManager L1→L2 (priority tx) — approve + direct.
        (3, "bridgehub_proxy", direct),
        // setAssetDeploymentTracker on L1AssetRouter (L1-side, no approve).
        (
            4,
            "l1_asset_router_proxy",
            "setAssetDeploymentTracker(bytes32,address)",
        ),
        // registerCTMAssetOnL1 on L1CTMDeploymentTracker (L1-side).
        (
            5,
            "ctm_deployment_tracker_proxy",
            "registerCTMAssetOnL1(address)",
        ),
        // setAssetHandler for chain assetId — approve + two-bridges.
        (7, "bridgehub_proxy", two_bridges),
        // chain-asset-handler registration for GW CTM — approve + two-bridges.
        (9, "bridgehub_proxy", two_bridges),
        // acceptOwnership on RollupDAManager — approve + direct.
        (11, "bridgehub_proxy", direct),
        // acceptOwnership on ServerNotifier — approve + direct.
        (13, "bridgehub_proxy", direct),
        // setGatewaySettlementFee on GW_ASSET_TRACKER_ADDR — approve + direct.
        (15, "bridgehub_proxy", direct),
    ];

    let mut errors = 0;
    for (offset, target_name, method) in expected {
        errors += verify_call_by_name(calls, base + offset, target_name, method, verifiers, result);
    }

    let Some(l1_asset_router) = named_address(verifiers, "l1_asset_router_proxy", result) else {
        return errors + 1;
    };
    let Some(ctm_deployment_tracker) =
        named_address(verifiers, "ctm_deployment_tracker_proxy", result)
    else {
        return errors + 1;
    };

    let expected_new_gw_chain_id = U256::from(verifiers.new_gateway_chain_id);
    let expected_l2_gas_limit = U256::from(MAX_PRIORITY_TX_GAS_LIMIT);
    let expected_l2_gas_per_pubdata_byte_limit = U256::from(L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT);
    // GatewayVotePreparation registers the representative/source CTM as the
    // L1 CTM asset; the newly deployed GW CTM appears in the L2 Bridgehub
    // add/setCTMAssetAddress payloads.
    let representative_ctm = verifiers.new_gateway_representative_ctm;
    let representative_ctm_registration_data = address_as_bytes32(representative_ctm);
    let representative_ctm_asset_id = ctm_asset_id(
        verifiers.expected_l1_chain_id,
        ctm_deployment_tracker,
        representative_ctm,
    );

    errors += check_register_legacy_token(calls, base, verifiers, result);
    if let Some(call) = calls.elems.get(base + 1) {
        errors += check_set_settlement_layer_status(
            base + 1,
            &call.data,
            U256::from(verifiers.new_gateway_chain_id),
            true,
            "new GW whitelist",
            result,
        );
    }
    errors += check_set_asset_deployment_tracker(
        calls,
        base + 4,
        representative_ctm_registration_data,
        ctm_deployment_tracker,
        result,
    );
    errors +=
        check_register_ctm_asset_on_l1(calls, base + 5, representative_ctm, verifiers, result);

    let direct_requests = [
        (
            3usize,
            "addChainTypeManager",
            L2_BRIDGEHUB_ADDR,
            "addChainTypeManager(address)",
        ),
        (
            11,
            "acceptOwnership RollupDAManager",
            match new_gw.gateway_rollup_da_manager_addr {
                Some(addr) => addr,
                None => {
                    result.report_error(
                        "[new_gateway.gateway_state_transition.rollup_da_manager_addr] is required \
                         for GW RollupDAManager acceptOwnership verification",
                    );
                    errors += 1;
                    Address::ZERO
                }
            },
            "acceptOwnership()",
        ),
        (
            13,
            "acceptOwnership ServerNotifier",
            match new_gw.gateway_server_notifier_addr {
                Some(addr) => addr,
                None => {
                    result.report_error(
                        "[new_gateway.gateway_state_transition.server_notifier_proxy_addr] is required \
                         for GW ServerNotifier acceptOwnership verification",
                    );
                    errors += 1;
                    Address::ZERO
                }
            },
            "acceptOwnership()",
        ),
        (
            15,
            "setGatewaySettlementFee",
            GW_ASSET_TRACKER_ADDR,
            "setGatewaySettlementFee(uint256)",
        ),
    ];
    for (offset, label, expected_l2_contract, expected_selector) in direct_requests {
        let idx = base + offset;
        let Some(decoded) = decode_direct_request(calls, idx) else {
            continue;
        };
        let req = match decoded {
            Ok(req) => req,
            Err(msg) => {
                result.report_error(&msg);
                errors += 1;
                continue;
            }
        };
        errors += check_priority_request_common(
            idx,
            label,
            req.chainId,
            req.mintValue,
            req.l2GasLimit,
            req.l2GasPerPubdataByteLimit,
            expected_new_gw_chain_id,
            expected_l2_gas_limit,
            expected_l2_gas_per_pubdata_byte_limit,
            result,
        );
        errors += check_l2_target(idx, label, req.l2Contract, expected_l2_contract, result);
        errors += check_l2_selector(idx, label, &req.l2Calldata, expected_selector, result);
        match offset {
            3 => {
                errors += check_inner_address_arg(
                    idx,
                    label,
                    expected_selector,
                    &req.l2Calldata,
                    new_gw.gateway_chain_type_manager_addr,
                    result,
                );
            }
            15 => {
                errors += check_set_gateway_settlement_fee(
                    idx,
                    &req.l2Calldata,
                    verifiers.new_gateway_settlement_fee,
                    result,
                );
            }
            _ => {}
        }
    }

    let two_bridge_requests = [
        (
            7usize,
            "setAssetHandlerAddress",
            l1_asset_router,
            L2_ASSET_ROUTER_ADDR,
            "setAssetHandlerAddress(uint256,bytes32,address)",
        ),
        (
            9,
            "setCTMAssetAddress",
            ctm_deployment_tracker,
            L2_BRIDGEHUB_ADDR,
            "setCTMAssetAddress(bytes32,address)",
        ),
    ];
    for (offset, label, expected_second_bridge, expected_l2_contract, expected_selector) in
        two_bridge_requests
    {
        let idx = base + offset;
        let Some(decoded) = decode_two_bridges_request(calls, idx) else {
            continue;
        };
        let req = match decoded {
            Ok(req) => req,
            Err(msg) => {
                result.report_error(&msg);
                errors += 1;
                continue;
            }
        };
        errors += check_priority_request_common(
            idx,
            label,
            req.chainId,
            req.mintValue,
            req.l2GasLimit,
            req.l2GasPerPubdataByteLimit,
            expected_new_gw_chain_id,
            expected_l2_gas_limit,
            expected_l2_gas_per_pubdata_byte_limit,
            result,
        );
        if req.secondBridgeAddress != expected_second_bridge {
            result.report_error(&format!(
                "GW priority tx #{idx} ({label}) secondBridgeAddress mismatch: expected {}, got {}",
                expected_second_bridge, req.secondBridgeAddress
            ));
            errors += 1;
        } else {
            result.report_ok(&format!(
                "GW priority tx #{idx} ({label}) secondBridgeAddress matches"
            ));
        }
        if req.secondBridgeValue != U256::ZERO {
            result.report_error(&format!(
                "GW priority tx #{idx} ({label}) secondBridgeValue must be 0 for GatewayVotePreparation, got {}",
                req.secondBridgeValue
            ));
            errors += 1;
        }
        match offset {
            7 => {
                errors += check_asset_router_second_bridge_calldata(
                    idx,
                    &req.secondBridgeCalldata,
                    representative_ctm_asset_id,
                    result,
                );
            }
            9 => {
                errors += check_ctm_tracker_second_bridge_calldata(
                    idx,
                    &req.secondBridgeCalldata,
                    representative_ctm,
                    new_gw.gateway_chain_type_manager_addr,
                    result,
                );
            }
            _ => {}
        }
        report_expected_two_bridge_inner_call(
            idx,
            label,
            expected_l2_contract,
            expected_selector,
            result,
        );
    }

    // All approve calls in this block target the same ZK base-token address,
    // approve the L1AssetRouter as spender, and their amount must exactly
    // match the following priority tx's mintValue.
    let approve_selector = compute_selector("approve(address,uint256)");
    let approve_pairs = [
        (2usize, 3usize),
        (6, 7),
        (8, 9),
        (10, 11),
        (12, 13),
        (14, 15),
    ];
    let mut approve_target: Option<Address> = None;
    for (approve_offset, priority_offset) in approve_pairs {
        let idx = base + approve_offset;
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
        let (spender, amount) = match <(Address, U256)>::abi_decode(&call.data[4..]) {
            Ok(args) => args,
            Err(err) => {
                result.report_error(&format!(
                    "Call #{idx}: failed to decode approve(address,uint256) args: {err}"
                ));
                errors += 1;
                continue;
            }
        };
        if spender != l1_asset_router {
            result.report_error(&format!(
                "Approve call #{idx} spender mismatch: expected l1_asset_router_proxy {}, got {}",
                l1_asset_router, spender
            ));
            errors += 1;
        }
        match priority_mint_value(calls, base + priority_offset) {
            Some(Ok(mint_value)) if amount == mint_value => {
                result.report_ok(&format!(
                    "Approve call #{idx} amount matches priority tx #{} mintValue ({amount})",
                    base + priority_offset
                ));
            }
            Some(Ok(mint_value)) => {
                result.report_error(&format!(
                    "Approve call #{idx} amount mismatch: expected following priority tx #{} mintValue {}, got {}",
                    base + priority_offset,
                    mint_value,
                    amount,
                ));
                errors += 1;
            }
            Some(Err(msg)) => {
                result.report_error(&msg);
                errors += 1;
            }
            None => {}
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

    errors
}

fn named_address(
    verifiers: &Verifiers,
    name: &str,
    result: &mut VerificationResult,
) -> Option<Address> {
    let address = verifiers
        .address_verifier
        .name_to_address
        .get(name)
        .copied();
    if address.is_none() {
        result.report_error(&format!("Expected address {name} is not known"));
    }
    address
}

fn address_as_bytes32(address: Address) -> FixedBytes<32> {
    let mut word = [0u8; 32];
    word[12..].copy_from_slice(address.as_slice());
    FixedBytes::from(word)
}

fn ctm_asset_id(l1_chain_id: u64, ctm_deployment_tracker: Address, ctm: Address) -> FixedBytes<32> {
    keccak256(
        (
            U256::from(l1_chain_id),
            ctm_deployment_tracker,
            address_as_bytes32(ctm),
        )
            .abi_encode(),
    )
}

fn decode_direct_request(
    calls: &CallList,
    idx: usize,
) -> Option<Result<L2TransactionRequestDirect, String>> {
    let call = calls.elems.get(idx)?;
    if call.data.len() < 4 {
        return Some(Err(format!(
            "Call #{idx}: requestL2TransactionDirect calldata is too short"
        )));
    }
    Some(
        L2TransactionRequestDirect::abi_decode(&call.data[4..]).map_err(|err| {
            format!("Call #{idx}: failed to decode L2TransactionRequestDirect: {err}")
        }),
    )
}

fn decode_two_bridges_request(
    calls: &CallList,
    idx: usize,
) -> Option<Result<L2TransactionRequestTwoBridgesOuter, String>> {
    let call = calls.elems.get(idx)?;
    if call.data.len() < 4 {
        return Some(Err(format!(
            "Call #{idx}: requestL2TransactionTwoBridges calldata is too short"
        )));
    }
    Some(
        L2TransactionRequestTwoBridgesOuter::abi_decode(&call.data[4..]).map_err(|err| {
            format!("Call #{idx}: failed to decode L2TransactionRequestTwoBridgesOuter: {err}")
        }),
    )
}

fn priority_mint_value(calls: &CallList, idx: usize) -> Option<Result<U256, String>> {
    let call = calls.elems.get(idx)?;
    if call.data.len() < 4 {
        return Some(Err(format!(
            "Call #{idx}: priority tx calldata is too short"
        )));
    }
    let selector = hex::encode(&call.data[0..4]);
    let direct_selector =
        compute_selector("requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))");
    let two_bridges_selector =
        compute_selector("requestL2TransactionTwoBridges((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))");
    if selector == direct_selector {
        decode_direct_request(calls, idx).map(|decoded| decoded.map(|req| req.mintValue))
    } else if selector == two_bridges_selector {
        decode_two_bridges_request(calls, idx).map(|decoded| decoded.map(|req| req.mintValue))
    } else {
        Some(Err(format!(
            "Call #{idx}: expected priority tx selector, got 0x{selector}"
        )))
    }
}

#[allow(clippy::too_many_arguments)]
fn check_priority_request_common(
    idx: usize,
    label: &str,
    chain_id: U256,
    mint_value: U256,
    l2_gas_limit: U256,
    l2_gas_per_pubdata_byte_limit: U256,
    expected_chain_id: U256,
    expected_l2_gas_limit: U256,
    expected_l2_gas_per_pubdata_byte_limit: U256,
    result: &mut VerificationResult,
) -> usize {
    let mut errors = 0;
    if chain_id != expected_chain_id {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) chainId mismatch: expected env [new_gateway].chain_id {expected_chain_id}, got {chain_id}"
        ));
        errors += 1;
    }
    if l2_gas_limit != expected_l2_gas_limit {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) l2GasLimit mismatch: expected GatewayVotePreparation MAX_PRIORITY_TX_GAS {expected_l2_gas_limit}, got {l2_gas_limit}"
        ));
        errors += 1;
    }
    if l2_gas_per_pubdata_byte_limit != expected_l2_gas_per_pubdata_byte_limit {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) l2GasPerPubdataByteLimit mismatch: expected REQUIRED_L2_GAS_PRICE_PER_PUBDATA {expected_l2_gas_per_pubdata_byte_limit}, got {l2_gas_per_pubdata_byte_limit}"
        ));
        errors += 1;
    }
    if errors == 0 {
        result.report_ok(&format!(
            "GW priority tx #{idx} ({label}) targets chain {chain_id}, l2GasLimit {l2_gas_limit}, l2GasPerPubdataByteLimit {l2_gas_per_pubdata_byte_limit}, mintValue {mint_value}"
        ));
    }
    errors
}

fn check_l2_target(
    idx: usize,
    label: &str,
    actual: Address,
    expected: Address,
    result: &mut VerificationResult,
) -> usize {
    if actual == expected {
        result.report_ok(&format!(
            "GW priority tx #{idx} ({label}) l2Contract matches"
        ));
        0
    } else {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) l2Contract mismatch: expected {expected}, got {actual}"
        ));
        1
    }
}

fn check_l2_selector(
    idx: usize,
    label: &str,
    calldata: &Bytes,
    expected_selector_sig: &str,
    result: &mut VerificationResult,
) -> usize {
    if calldata.len() < 4 {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) inner calldata is too short"
        ));
        return 1;
    }
    let actual_sel = hex::encode(&calldata[0..4]);
    let expected_sel = compute_selector(expected_selector_sig);
    if actual_sel == expected_sel {
        result.report_ok(&format!(
            "GW priority tx #{idx} ({label}) inner selector {expected_selector_sig} matches"
        ));
        0
    } else {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) inner selector mismatch: expected {expected_selector_sig} (0x{expected_sel}), got 0x{actual_sel}"
        ));
        1
    }
}

fn check_inner_address_arg(
    idx: usize,
    label: &str,
    selector_sig: &str,
    calldata: &Bytes,
    expected_arg: Address,
    result: &mut VerificationResult,
) -> usize {
    if calldata.len() < 4 + 32 {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) {selector_sig} calldata is too short"
        ));
        return 1;
    }
    let actual_arg = Address::from_slice(&calldata[4 + 12..4 + 32]);
    if actual_arg == expected_arg {
        result.report_ok(&format!(
            "GW priority tx #{idx} ({label}) {selector_sig} arg matches"
        ));
        0
    } else {
        result.report_error(&format!(
            "GW priority tx #{idx} ({label}) {selector_sig} arg mismatch: expected {expected_arg}, got {actual_arg}"
        ));
        1
    }
}

fn check_set_gateway_settlement_fee(
    idx: usize,
    calldata: &Bytes,
    expected_fee: U256,
    result: &mut VerificationResult,
) -> usize {
    if calldata.len() < 4 + 32 {
        result.report_error(&format!(
            "GW priority tx #{idx} setGatewaySettlementFee calldata is too short"
        ));
        return 1;
    }
    let fee = U256::from_be_slice(&calldata[4..36]);
    if fee == expected_fee {
        result.report_ok(&format!(
            "GW priority tx #{idx} setGatewaySettlementFee({fee}) matches env config"
        ));
        0
    } else {
        result.report_error(&format!(
            "GW priority tx #{idx} setGatewaySettlementFee mismatch: expected env settlement_fee {expected_fee}, got {fee}"
        ));
        1
    }
}

fn check_set_settlement_layer_status(
    idx: usize,
    calldata: &[u8],
    expected_chain_id: U256,
    expected_status: bool,
    label: &str,
    result: &mut VerificationResult,
) -> usize {
    let decoded = match setSettlementLayerStatusCall::abi_decode(calldata) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!(
                "Stage 2 call #{idx} ({label}): failed to decode setSettlementLayerStatus: {err}"
            ));
            return 1;
        }
    };
    let mut errors = 0;
    if decoded.chainId != expected_chain_id {
        result.report_error(&format!(
            "Stage 2 call #{idx} ({label}) setSettlementLayerStatus.chainId mismatch: expected {expected_chain_id}, got {}",
            decoded.chainId
        ));
        errors += 1;
    }
    if decoded.status != expected_status {
        result.report_error(&format!(
            "Stage 2 call #{idx} ({label}) setSettlementLayerStatus.status mismatch: expected {expected_status}, got {}",
            decoded.status
        ));
        errors += 1;
    }
    if errors == 0 {
        result.report_ok(&format!(
            "Stage 2 call #{idx} ({label}) setSettlementLayerStatus({expected_chain_id}, {expected_status}) verified"
        ));
    }
    errors
}

fn check_historical_migration_interval(
    idx: usize,
    calldata: &[u8],
    expected: &ChainInterval,
    expected_settlement_chain_id: U256,
    result: &mut VerificationResult,
) -> usize {
    let decoded = match setHistoricalMigrationIntervalCall::abi_decode(calldata) {
        Ok(decoded) => decoded,
        Err(err) => {
            result.report_error(&format!(
                "Stage 2 call #{idx}: failed to decode setHistoricalMigrationInterval: {err}"
            ));
            return 1;
        }
    };
    let mut errors = 0;
    let expect = |actual: U256, expected: U256, label: &str, errors: &mut usize, result: &mut VerificationResult| {
        if actual != expected {
            result.report_error(&format!(
                "Stage 2 call #{idx} ({label}) mismatch: expected {expected}, got {actual}"
            ));
            *errors += 1;
        }
    };
    expect(
        decoded.chainId,
        U256::from(expected.chain_id),
        "setHistoricalMigrationInterval.chainId",
        &mut errors,
        result,
    );
    // Deploy script ([CoreUpgrade_v31.s.sol:394]) always passes `0`.
    expect(
        decoded.migrationNumber,
        U256::ZERO,
        "setHistoricalMigrationInterval.migrationNumber",
        &mut errors,
        result,
    );
    expect(
        decoded.interval.migrateToGWBatchNumber,
        U256::from(expected.migrate_to_sl_batch),
        "MigrationInterval.migrateToGWBatchNumber",
        &mut errors,
        result,
    );
    expect(
        decoded.interval.migrateFromGWBatchNumber,
        U256::from(expected.migrate_from_sl_batch),
        "MigrationInterval.migrateFromGWBatchNumber",
        &mut errors,
        result,
    );
    expect(
        decoded.interval.settlementLayerBatchLowerBound,
        U256::from(expected.sl_batch_lower_bound),
        "MigrationInterval.settlementLayerBatchLowerBound",
        &mut errors,
        result,
    );
    expect(
        decoded.interval.settlementLayerBatchUpperBound,
        U256::from(expected.sl_batch_upper_bound),
        "MigrationInterval.settlementLayerBatchUpperBound",
        &mut errors,
        result,
    );
    expect(
        decoded.interval.settlementLayerChainId,
        expected_settlement_chain_id,
        "MigrationInterval.settlementLayerChainId",
        &mut errors,
        result,
    );
    if decoded.interval.isActive {
        result.report_error(&format!(
            "Stage 2 call #{idx}: MigrationInterval.isActive must be false for historical intervals (chain {} no longer settles on the legacy GW)",
            expected.chain_id
        ));
        errors += 1;
    }
    errors
}

fn check_register_legacy_token(
    calls: &CallList,
    base: usize,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(base) else {
        return 0;
    };
    if call.data.len() < 4 + 32 {
        result.report_error(&format!(
            "Call #{base}: registerLegacyToken(bytes32) calldata is too short"
        ));
        return 1;
    }
    let asset_id = FixedBytes::<32>::from_slice(&call.data[4..36]);
    if asset_id == verifiers.zk_token_asset_id {
        result.report_ok("registerLegacyToken asset id matches env zk_token_asset_id");
        0
    } else {
        result.report_error(&format!(
            "registerLegacyToken asset id mismatch: expected {}, got {}",
            verifiers.zk_token_asset_id, asset_id
        ));
        1
    }
}

fn check_set_asset_deployment_tracker(
    calls: &CallList,
    idx: usize,
    expected_registration_data: FixedBytes<32>,
    expected_tracker: Address,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(idx) else {
        return 0;
    };
    if call.data.len() < 4 {
        result.report_error(&format!(
            "Call #{idx}: setAssetDeploymentTracker calldata is too short"
        ));
        return 1;
    }
    let (registration_data, tracker) =
        match <(FixedBytes<32>, Address)>::abi_decode(&call.data[4..]) {
            Ok(args) => args,
            Err(err) => {
                result.report_error(&format!(
                "Call #{idx}: failed to decode setAssetDeploymentTracker(bytes32,address): {err}"
            ));
                return 1;
            }
        };
    let mut errors = 0;
    if registration_data != expected_registration_data {
        result.report_error(&format!(
            "Call #{idx}: setAssetDeploymentTracker registration data mismatch: expected {}, got {}",
            expected_registration_data, registration_data
        ));
        errors += 1;
    }
    if tracker != expected_tracker {
        result.report_error(&format!(
            "Call #{idx}: setAssetDeploymentTracker tracker mismatch: expected {}, got {}",
            expected_tracker, tracker
        ));
        errors += 1;
    }
    if errors == 0 {
        result.report_ok("setAssetDeploymentTracker args match representative CTM asset");
    }
    errors
}

fn check_register_ctm_asset_on_l1(
    calls: &CallList,
    idx: usize,
    expected_ctm: Address,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(idx) else {
        return 0;
    };
    if call.data.len() < 4 {
        result.report_error(&format!(
            "Call #{idx}: registerCTMAssetOnL1 calldata is too short"
        ));
        return 1;
    }
    let (ctm,) = match <(Address,)>::abi_decode(&call.data[4..]) {
        Ok(args) => args,
        Err(err) => {
            result.report_error(&format!(
                "Call #{idx}: failed to decode registerCTMAssetOnL1(address): {err}"
            ));
            return 1;
        }
    };
    if ctm == expected_ctm {
        result.report_ok(&format!(
            "registerCTMAssetOnL1 CTM matches Bridgehub.chainTypeManager({})",
            verifiers.new_gateway_representative_chain_id
        ));
        0
    } else {
        result.report_error(&format!(
            "registerCTMAssetOnL1 CTM mismatch: expected Bridgehub.chainTypeManager({}) {}, got {}",
            verifiers.new_gateway_representative_chain_id, expected_ctm, ctm
        ));
        1
    }
}

fn check_asset_router_second_bridge_calldata(
    idx: usize,
    calldata: &Bytes,
    expected_asset_id: FixedBytes<32>,
    result: &mut VerificationResult,
) -> usize {
    if calldata.first().copied() != Some(0x02) {
        result.report_error(&format!(
            "GW priority tx #{idx} setAssetHandlerAddress secondBridgeCalldata encoding mismatch: expected 0x02"
        ));
        return 1;
    }
    let (asset_id, handler) = match <(FixedBytes<32>, Address)>::abi_decode(&calldata[1..]) {
        Ok(args) => args,
        Err(err) => {
            result.report_error(&format!(
                "GW priority tx #{idx}: failed to decode L1AssetRouter secondBridgeCalldata: {err}"
            ));
            return 1;
        }
    };
    let mut errors = 0;
    if asset_id != expected_asset_id {
        result.report_error(&format!(
            "GW priority tx #{idx} setAssetHandlerAddress asset id mismatch: expected {}, got {}",
            expected_asset_id, asset_id
        ));
        errors += 1;
    }
    if handler != L2_CHAIN_ASSET_HANDLER_ADDR {
        result.report_error(&format!(
            "GW priority tx #{idx} setAssetHandlerAddress handler mismatch: expected {}, got {}",
            L2_CHAIN_ASSET_HANDLER_ADDR, handler
        ));
        errors += 1;
    }
    if errors == 0 {
        result.report_ok(
            "setAssetHandlerAddress secondBridgeCalldata matches representative CTM asset",
        );
    }
    errors
}

fn check_ctm_tracker_second_bridge_calldata(
    idx: usize,
    calldata: &Bytes,
    expected_l1_ctm: Address,
    expected_l2_ctm: Address,
    result: &mut VerificationResult,
) -> usize {
    if calldata.first().copied() != Some(0x01) {
        result.report_error(&format!(
            "GW priority tx #{idx} setCTMAssetAddress secondBridgeCalldata encoding mismatch: expected 0x01"
        ));
        return 1;
    }
    let (l1_ctm, l2_ctm) = match <(Address, Address)>::abi_decode(&calldata[1..]) {
        Ok(args) => args,
        Err(err) => {
            result.report_error(&format!(
                "GW priority tx #{idx}: failed to decode CTMDeploymentTracker secondBridgeCalldata: {err}"
            ));
            return 1;
        }
    };
    let mut errors = 0;
    if l1_ctm != expected_l1_ctm {
        result.report_error(&format!(
            "GW priority tx #{idx} setCTMAssetAddress L1 CTM mismatch: expected {}, got {}",
            expected_l1_ctm, l1_ctm
        ));
        errors += 1;
    }
    if l2_ctm != expected_l2_ctm {
        result.report_error(&format!(
            "GW priority tx #{idx} setCTMAssetAddress L2 CTM mismatch: expected {}, got {}",
            expected_l2_ctm, l2_ctm
        ));
        errors += 1;
    }
    if errors == 0 {
        result.report_ok(
            "setCTMAssetAddress secondBridgeCalldata matches representative and GW CTMs",
        );
    }
    errors
}

fn report_expected_two_bridge_inner_call(
    idx: usize,
    label: &str,
    expected_l2_contract: Address,
    expected_selector: &str,
    result: &mut VerificationResult,
) {
    // The inner L2 request is produced by the second bridge contract at
    // execution time, not carried directly in the outer calldata. We can still
    // derive the expected L2 target/selector from the decoded second-bridge
    // payload and report that provenance explicitly.
    result.report_ok(&format!(
        "GW priority tx #{idx} ({label}) second bridge is expected to emit L2 call {expected_selector} to {expected_l2_contract}"
    ));
}
