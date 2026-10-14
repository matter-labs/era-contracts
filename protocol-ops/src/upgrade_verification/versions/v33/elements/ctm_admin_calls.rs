//! `[ctms.<flavor>.ctm_admin_calls]` — the ChainAdmin-executed bundle that
//! swaps each CTM's `ServerNotifier` implementation, and accepts the
//! ServerNotifier's ownership when it is still pending to that ChainAdmin.
//!
//! The bundle is one `ChainAdmin.multicall` of one or two calls
//! (`DefaultCTMUpgrade.prepareUpgradeServerNotifierCall`):
//!   1. `ProxyAdmin.upgrade(serverNotifier, newImpl)`;
//!   2. only when the ServerNotifier's `pendingOwner()` is the ChainAdmin that
//!      owns its ProxyAdmin: `serverNotifier.acceptOwnership()`. A CTM deployed
//!      by `DeployCTM` leaves that Ownable2Step transfer dangling, and the
//!      ChainAdmin executing this multicall is exactly the pending owner.
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

use super::super::utils::network_verifier::{ChainTypeManager, Ownable, Ownable2Step};
use super::call_list::Call;
use super::governance_stage_calls::{acceptOwnershipCall, ctm_address, upgradeCall};

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

    let (call, accept_call) = match calls.as_slice() {
        [call] => (call, None),
        [call, accept_call] => (call, Some(accept_call)),
        _ => {
            result.report_error(&format!(
                "ctms.{label}.ctm_admin_calls must hold the ServerNotifier upgrade and at most a \
                 trailing acceptOwnership(), got {} calls",
                calls.len()
            ));
            return;
        }
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

    // The optional trailing acceptOwnership(): its shape, and whether the
    // ServerNotifier's ownership state calls for it.
    if let Some(accept_call) = accept_call {
        for error in accept_ownership_call_shape_errors(accept_call, server_notifier_proxy) {
            result.report_error(&format!("ctms.{label}.ctm_admin_calls: {error}"));
        }
    }
    let provider = verifiers.network_verifier.get_l1_provider();
    let chain_admin = match Ownable::new(expected_target, provider.clone())
        .owner()
        .call()
        .await
    {
        Ok(owner) => owner,
        Err(err) => {
            result.report_error(&format!(
                "Failed to read ServerNotifier ProxyAdmin {expected_target} owner(): {err}"
            ));
            return;
        }
    };
    let server_notifier = Ownable2Step::new(server_notifier_proxy, provider);
    let (owner, pending_owner) = match (
        server_notifier.owner().call().await,
        server_notifier.pendingOwner().call().await,
    ) {
        (Ok(owner), Ok(pending_owner)) => (owner, pending_owner),
        (Err(err), _) | (_, Err(err)) => {
            result.report_error(&format!(
                "Failed to read {label} ServerNotifier {server_notifier_proxy} owner()/pendingOwner(): {err}"
            ));
            return;
        }
    };
    let upgrade_applied = verifiers
        .network_verifier
        .get_proxy_implementation(server_notifier_proxy)
        .await
        == decoded.implementation;
    match accept_ownership_expectation(
        accept_call.is_some(),
        chain_admin,
        ServerNotifierOwnership {
            owner,
            pending_owner,
            upgrade_applied,
        },
    ) {
        Ok(verdict) => result.report_ok(&format!("{label} ctm_admin_calls: {verdict}")),
        Err(error) => result.report_error(&format!("ctms.{label}.ctm_admin_calls: {error}")),
    }

    result.report_ok(&format!(
        "{label} ctm_admin_calls upgrades ServerNotifier {server_notifier_proxy} to {} via ProxyAdmin {expected_target}",
        decoded.implementation
    ));
}

/// Shape errors of the trailing call: it must be `acceptOwnership()` — the bare
/// selector, no arguments — on the CTM's own ServerNotifier proxy, sending no
/// value. Anything else would let the ChainAdmin accept ownership of, or call,
/// some other contract.
fn accept_ownership_call_shape_errors(call: &Call, server_notifier_proxy: Address) -> Vec<String> {
    let mut errors = Vec::new();
    if call.target != server_notifier_proxy {
        errors.push(format!(
            "second call targets {}, expected the ServerNotifier proxy {server_notifier_proxy}",
            call.target
        ));
    }
    if call.data.as_ref() != acceptOwnershipCall::SELECTOR.as_slice() {
        errors.push(format!(
            "second call must be exactly acceptOwnership() (0x{}), got 0x{}",
            hex::encode(acceptOwnershipCall::SELECTOR),
            hex::encode(&call.data)
        ));
    }
    if call.value != U256::ZERO {
        errors.push(format!(
            "second call must send no value, got {}",
            call.value
        ));
    }
    errors
}

/// Live ownership of a CTM's ServerNotifier, as far as the bundle cares.
#[derive(Debug, Clone, Copy)]
struct ServerNotifierOwnership {
    owner: Address,
    pending_owner: Address,
    /// The proxy already points at the implementation the bundle installs, i.e.
    /// the bundle has been executed on this chain (e.g. replayed on a fork).
    upgrade_applied: bool,
}

/// Whether a bundle with (`has_accept`) or without a trailing
/// `acceptOwnership()` matches the ServerNotifier's ownership relative to
/// `chain_admin` (the owner of its ProxyAdmin, which executes the multicall).
///
/// Before execution this mirrors the generator: the accept is present exactly
/// when the transfer is pending to the ChainAdmin, and without it the
/// ChainAdmin must already own the ServerNotifier. After execution the
/// multicall is atomic, so the upgrade having landed means a carried accept
/// succeeded; either way the ChainAdmin must end up the owner.
fn accept_ownership_expectation(
    has_accept: bool,
    chain_admin: Address,
    state: ServerNotifierOwnership,
) -> Result<&'static str, String> {
    let ServerNotifierOwnership {
        owner,
        pending_owner,
        upgrade_applied,
    } = state;
    if upgrade_applied {
        if owner != chain_admin {
            return Err(format!(
                "the bundle has been executed, but the ServerNotifier is owned by {owner}, not the \
                 ChainAdmin {chain_admin}"
            ));
        }
        if !has_accept && pending_owner == chain_admin {
            return Err(format!(
                "the ServerNotifier's ownership is still pending to the ChainAdmin {chain_admin} \
                 and the bundle does not accept it"
            ));
        }
        return Ok(if has_accept {
            "executed; the ServerNotifier's pending ownership was accepted by the ChainAdmin"
        } else {
            "executed; the ServerNotifier stays owned by the ChainAdmin"
        });
    }
    match (has_accept, pending_owner == chain_admin) {
        (true, true) => Ok(
            "accepts the ServerNotifier ownership that is pending to the ChainAdmin executing the bundle",
        ),
        (true, false) => Err(format!(
            "carries acceptOwnership(), but the ServerNotifier's pendingOwner() is {pending_owner}, \
             not the ChainAdmin {chain_admin}; the multicall would revert"
        )),
        (false, true) => Err(format!(
            "the ServerNotifier's ownership is pending to the ChainAdmin {chain_admin}, but the \
             bundle does not accept it, leaving the transfer dangling"
        )),
        (false, false) if owner == chain_admin => {
            Ok("the ServerNotifier is already owned by the ChainAdmin; nothing to accept")
        }
        (false, false) => Err(format!(
            "the ServerNotifier is neither pending to nor owned by the ChainAdmin {chain_admin} \
             (owner {owner}, pendingOwner {pending_owner})"
        )),
    }
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

#[cfg(test)]
mod tests {
    use alloy::primitives::Bytes;

    use super::*;

    const CHAIN_ADMIN: Address = Address::repeat_byte(0xca);
    const SERVER_NOTIFIER: Address = Address::repeat_byte(0x5e);
    const STRANGER: Address = Address::repeat_byte(0x55);

    fn state(
        owner: Address,
        pending_owner: Address,
        upgrade_applied: bool,
    ) -> ServerNotifierOwnership {
        ServerNotifierOwnership {
            owner,
            pending_owner,
            upgrade_applied,
        }
    }

    fn accept_call(target: Address, data: Vec<u8>, value: u64) -> Call {
        Call {
            target,
            value: U256::from(value),
            data: Bytes::from(data),
        }
    }

    #[test]
    fn a_well_formed_accept_has_no_shape_errors() {
        let call = accept_call(SERVER_NOTIFIER, acceptOwnershipCall::SELECTOR.to_vec(), 0);
        assert!(accept_ownership_call_shape_errors(&call, SERVER_NOTIFIER).is_empty());
    }

    /// Another target, extra calldata, or value each make the trailing call
    /// something other than the ServerNotifier's own acceptOwnership().
    #[test]
    fn a_malformed_accept_is_rejected() {
        let selector = acceptOwnershipCall::SELECTOR.to_vec();
        let wrong_target = accept_call(STRANGER, selector.clone(), 0);
        assert_eq!(
            accept_ownership_call_shape_errors(&wrong_target, SERVER_NOTIFIER).len(),
            1
        );
        let mut with_args = selector.clone();
        with_args.extend_from_slice(&[0; 32]);
        let extra_data = accept_call(SERVER_NOTIFIER, with_args, 0);
        assert_eq!(
            accept_ownership_call_shape_errors(&extra_data, SERVER_NOTIFIER).len(),
            1
        );
        let other_call = accept_call(SERVER_NOTIFIER, upgradeCall::SELECTOR.to_vec(), 0);
        assert_eq!(
            accept_ownership_call_shape_errors(&other_call, SERVER_NOTIFIER).len(),
            1
        );
        let with_value = accept_call(SERVER_NOTIFIER, selector, 1);
        assert_eq!(
            accept_ownership_call_shape_errors(&with_value, SERVER_NOTIFIER).len(),
            1
        );
    }

    #[test]
    fn before_execution_the_accept_is_required_exactly_when_ownership_is_pending() {
        // Pending to the ChainAdmin: the two-call form is right, the one-call form dangles.
        let pending = state(STRANGER, CHAIN_ADMIN, false);
        assert!(accept_ownership_expectation(true, CHAIN_ADMIN, pending).is_ok());
        let err = accept_ownership_expectation(false, CHAIN_ADMIN, pending).unwrap_err();
        assert!(err.contains("dangling"), "{err}");

        // Already owned by the ChainAdmin: nothing to accept, and an accept would revert.
        let owned = state(CHAIN_ADMIN, Address::ZERO, false);
        assert!(accept_ownership_expectation(false, CHAIN_ADMIN, owned).is_ok());
        let err = accept_ownership_expectation(true, CHAIN_ADMIN, owned).unwrap_err();
        assert!(err.contains("would revert"), "{err}");
    }

    /// Neither pending to nor owned by the ChainAdmin is the state the generator refuses.
    #[test]
    fn before_execution_a_foreign_server_notifier_is_rejected_in_both_forms() {
        let foreign = state(STRANGER, STRANGER, false);
        assert!(accept_ownership_expectation(false, CHAIN_ADMIN, foreign).is_err());
        assert!(accept_ownership_expectation(true, CHAIN_ADMIN, foreign).is_err());
    }

    /// Once the multicall has run (e.g. replayed on a rehearsal fork), the
    /// ChainAdmin must own the ServerNotifier whichever form was used.
    #[test]
    fn after_execution_the_chain_admin_must_own_the_server_notifier() {
        let accepted = state(CHAIN_ADMIN, Address::ZERO, true);
        assert!(accept_ownership_expectation(true, CHAIN_ADMIN, accepted).is_ok());
        assert!(accept_ownership_expectation(false, CHAIN_ADMIN, accepted).is_ok());

        let still_pending = state(STRANGER, CHAIN_ADMIN, true);
        assert!(accept_ownership_expectation(false, CHAIN_ADMIN, still_pending).is_err());
        assert!(accept_ownership_expectation(true, CHAIN_ADMIN, still_pending).is_err());
    }
}
