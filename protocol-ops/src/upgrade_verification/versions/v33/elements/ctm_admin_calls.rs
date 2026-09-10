//! `[ctms.<flavor>.ctm_admin_calls]` — the ChainAdmin-executed bundle that
//! swaps each CTM's `ServerNotifier` implementation.
//!
//! This section sits outside the three governance stages: it is executed by the
//! CTM's ChainAdmin rather than by governance, which is why it is emitted as
//! its own bundle (`DefaultCTMUpgrade.prepareDefaultCTMAdminCalls`). Being
//! outside the stages is not a reason to be outside verification — the call
//! installs a new implementation behind a live proxy, so it carries the same
//! weight as a stage-1 proxy swap.
//!
//! Nothing here is taken from the artifact alone. The ServerNotifier proxy is
//! read from the live CTM (`serverNotifierAddress()`), its ProxyAdmin from the
//! proxy's EIP-1967 slot, and both ownership hops from chain state; the new
//! implementation must be a `ServerNotifier` this upgrade CREATE2-deployed.
//! An artifact whose `server_notifier_upgrade` is replaced wholesale — with
//! junk, or with a well-formed call to somewhere else — fails here.

use alloy::{
    hex,
    primitives::{Address, U256},
    sol_types::{SolCall, SolValue},
};

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::utils::network_verifier::{ChainTypeManager, Ownable};
use super::call_list::Call;
use super::governance_stage_calls::{ctm_address, upgradeCall};

/// `AllContractsHashes.json` key for the implementation this bundle installs.
const SERVER_NOTIFIER_FILE: &str = "l1-contracts/ServerNotifier";

pub(crate) async fn verify_ctm_admin_calls(
    artifact: &EcosystemUpgradeArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== CTM admin calls (ServerNotifier upgrade) ===");

    for ctm in &artifact.ctms {
        verify_one_ctm_admin_calls(ctm, verifiers, result).await;
    }

    Ok(())
}

async fn verify_one_ctm_admin_calls(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) {
    let label = ctm.flavor.label();

    let Some(section) = ctm.value.get("ctm_admin_calls") else {
        result.report_error(&format!(
            "ctms.{label} has no [ctm_admin_calls] section; the ServerNotifier upgrade bundle is missing"
        ));
        return;
    };

    // Decode the bundle. `CallList::parse` panics on malformed input, which
    // would turn a verification failure into a crash, so decode leniently and
    // report instead.
    let Some(raw) = section
        .get("server_notifier_upgrade")
        .and_then(|v| v.as_str())
    else {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls is missing `server_notifier_upgrade`"
        ));
        return;
    };
    let Ok(bytes) = hex::decode(raw) else {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls.server_notifier_upgrade is not valid hex"
        ));
        return;
    };
    let Ok(calls) = <Vec<Call>>::abi_decode(&bytes) else {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls.server_notifier_upgrade does not decode as Call[]"
        ));
        return;
    };

    let [call] = calls.as_slice() else {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls must hold exactly one call, got {}",
            calls.len()
        ));
        return;
    };

    if call.value != U256::ZERO {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls call must send no value, got {}",
            call.value
        ));
    }

    // Resolve the proxy from the live CTM rather than the artifact.
    let ctm_proxy = match ctm_address(
        ctm,
        &["state_transition", "chain_type_manager_proxy"],
        result,
    ) {
        Some(addr) => addr,
        None => return,
    };
    let provider = verifiers.network_verifier.get_l1_provider();
    let server_notifier_proxy = match ChainTypeManager::new(ctm_proxy, provider.clone())
        .serverNotifierAddress()
        .call()
        .await
    {
        Ok(addr) => addr,
        Err(err) => {
            result.report_error(&format!(
                "Failed to call {label} ChainTypeManager.serverNotifierAddress(): {err}"
            ));
            return;
        }
    };

    let expected_target = verifiers
        .network_verifier
        .get_proxy_admin(server_notifier_proxy)
        .await;
    if call.target != expected_target {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls targets {}, expected the ServerNotifier ProxyAdmin {expected_target}",
            call.target
        ));
        return;
    }

    let Ok(decoded) = upgradeCall::abi_decode(&call.data) else {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls call does not decode as upgrade(address,address)"
        ));
        return;
    };

    if decoded.proxy != server_notifier_proxy {
        result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls upgrades proxy {}, but the CTM's ServerNotifier is {server_notifier_proxy}",
            decoded.proxy
        ));
    }

    // The implementation must be the one the artifact declares *and* a
    // ServerNotifier this upgrade deployed. The first alone would be
    // self-referential.
    if let Some(declared) = ctm_address(
        ctm,
        &["state_transition", "server_notifier_implementation_addr"],
        result,
    ) {
        if decoded.implementation != declared {
            result.report_error(&format!(
                "ctms.{label}.ctm_admin_calls installs {}, but the artifact declares {declared}",
                decoded.implementation
            ));
        }
    }
    match verifiers
        .network_verifier
        .create2_known_bytecodes
        .get(&decoded.implementation)
    {
        Some(file) if file == SERVER_NOTIFIER_FILE => {}
        Some(file) => result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls installs {}, which this upgrade deployed as {file}, not {SERVER_NOTIFIER_FILE}",
            decoded.implementation
        )),
        None => result.report_error(&format!(
            "ctms.{label}.ctm_admin_calls installs {}, which is not among this upgrade's CREATE2 deployments",
            decoded.implementation
        )),
    }

    // The two recorded signers are what a reviewer uses to know who must
    // execute this bundle, so they must match live ownership.
    verify_recorded_owner(
        result,
        verifiers,
        section,
        "chain_admin",
        expected_target,
        &format!("ctms.{label}.ctm_admin_calls.chain_admin"),
        &format!("ServerNotifier ProxyAdmin {expected_target} owner()"),
    )
    .await;

    if let Some(chain_admin) = section
        .get("chain_admin")
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<Address>().ok())
    {
        verify_recorded_owner(
            result,
            verifiers,
            section,
            "chain_admin_owner",
            chain_admin,
            &format!("ctms.{label}.ctm_admin_calls.chain_admin_owner"),
            &format!("ChainAdmin {chain_admin} owner()"),
        )
        .await;
    }

    result.report_ok(&format!(
        "{label} ctm_admin_calls upgrades ServerNotifier {server_notifier_proxy} to {} via ProxyAdmin {expected_target}",
        decoded.implementation
    ));
}

/// Compares a recorded address field against `owner()` on `owner_of`.
async fn verify_recorded_owner(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    section: &toml::Value,
    field: &str,
    owner_of: Address,
    field_label: &str,
    source_label: &str,
) {
    let Some(recorded) = section
        .get(field)
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<Address>().ok())
    else {
        result.report_error(&format!("{field_label} is missing or not an address"));
        return;
    };

    let provider = verifiers.network_verifier.get_l1_provider();
    match Ownable::new(owner_of, provider).owner().call().await {
        Ok(actual) if actual == recorded => {
            result.report_ok(&format!("{field_label} matches {source_label}"))
        }
        Ok(actual) => result.report_error(&format!(
            "{field_label} is {recorded}, but {source_label} is {actual}"
        )),
        Err(err) => result.report_error(&format!("Failed to read {source_label}: {err}")),
    }
}
