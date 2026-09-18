//! Cross-cutting verification primitives used by all three stages.
//!
//! - **Call-shape checks**: `verify_call_by_name`, `verify_call_by_address`
//!   validate `(target, selector, value=0)` on a single call from the
//!   `CallList`. Higher-level decoders run on top of these.
//! - **Address-book primitives**: `expect_named_address` / `expect_address_equal`
//!   for direct comparisons; `required_ctm_address` / `required_core_address`
//!   for navigating the artifact TOML by key path with proper error reporting.
//! - **Misc**: `expect_hex_equal` (blob equality with `0x` prefix tolerance),
//!   `verify_address_has_code` (RPC `eth_getCode` non-empty check), and
//!   `protocol_label` (display helper for `U256` protocol versions).

use std::str::FromStr;

use alloy::{
    hex,
    primitives::{Address, U256},
    providers::Provider,
};

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, EcosystemUpgradeArtifact},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::super::utils::compute_selector;
use super::super::protocol_version::ProtocolVersion;
use super::CallList;

pub(super) fn protocol_label(version: U256) -> String {
    format!("{} ({version})", ProtocolVersion::from(version))
}

pub(super) fn expect_named_address(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    address: &Address,
    expected_name: &str,
) -> usize {
    if result.expect_address(verifiers, address, expected_name) {
        0
    } else {
        1
    }
}

pub(super) fn expect_address_equal(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    actual: &Address,
    expected: Address,
    expected_label: &str,
) -> usize {
    if *actual == expected {
        result.report_ok(&format!("{expected_label} address matches"));
        0
    } else {
        result.report_error(&format!(
            "Expected {} to be {}, but got {} ({})",
            expected_label,
            expected,
            actual,
            verifiers.address_verifier.name_or_unknown(actual)
        ));
        1
    }
}

pub(super) fn expect_hex_equal(
    result: &mut VerificationResult,
    label: &str,
    expected: &str,
    actual_without_prefix: &str,
) -> usize {
    let expected_without_prefix = expected.strip_prefix("0x").unwrap_or(expected);
    if actual_without_prefix.eq_ignore_ascii_case(expected_without_prefix) {
        result.report_ok(&format!("{label} matches"));
        0
    } else {
        result.report_error(&format!(
            "{} mismatch. Expected: {}\nReceived: 0x{}",
            label, expected, actual_without_prefix
        ));
        1
    }
}

pub(super) fn verify_call_by_name(
    calls: &CallList,
    index: usize,
    target_name: &str,
    method_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(expected_target) = verifiers
        .address_verifier
        .name_to_address
        .get(target_name)
        .copied()
    else {
        result.report_error(&format!("Expected call target {target_name} is not known"));
        return 1;
    };

    verify_call_by_address(
        calls,
        index,
        expected_target,
        target_name,
        method_name,
        verifiers,
        result,
    )
}

pub(super) fn verify_call_by_address(
    calls: &CallList,
    index: usize,
    expected_target: Address,
    expected_label: &str,
    method_name: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let Some(call) = calls.elems.get(index) else {
        result.report_error(&format!(
            "Expected call #{index} to {expected_label} with {method_name} not found"
        ));
        return 1;
    };

    let mut errors = 0;
    if call.target != expected_target {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but target is {}",
            expected_label,
            method_name,
            verifiers.address_verifier.name_or_unknown(&call.target)
        ));
        errors += 1;
    }
    if call.value != U256::ZERO {
        result.report_error(&format!(
            "Expected call #{index} to {} with {} to have zero value, but got {}",
            expected_label, method_name, call.value
        ));
        errors += 1;
    }
    if call.data.len() < 4 {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but call data is too short",
            expected_label, method_name
        ));
        return errors + 1;
    }

    let expected_selector = compute_selector(method_name);
    let actual_selector = hex::encode(&call.data[0..4]);
    if actual_selector != expected_selector {
        result.report_error(&format!(
            "Expected call #{index} to {} with {}, but selector was {}",
            expected_label, method_name, actual_selector
        ));
        errors += 1;
    }

    if errors == 0 {
        result.report_ok(&format!("Called {expected_label} with {method_name}"));
    }
    errors
}

pub(super) fn required_ctm_address(
    ctm: &CtmArtifact,
    path: &[&str],
    result: &mut VerificationResult,
) -> Option<Address> {
    let path_label = format!("ctms.{}.{}", ctm.flavor.label(), path.join("."));
    let mut current = &ctm.value;
    for segment in path {
        let Some(next) = current.get(*segment) else {
            result.report_error(&format!("{path_label} is required"));
            return None;
        };
        current = next;
    }

    let Some(raw) = current.as_str() else {
        result.report_error(&format!("{path_label} must be an address string"));
        return None;
    };

    match Address::from_str(raw) {
        Ok(address) => Some(address),
        Err(err) => {
            result.report_error(&format!("{path_label} is not a valid address: {err}"));
            None
        }
    }
}

pub(super) fn required_core_address(
    artifact: &EcosystemUpgradeArtifact,
    path: &[&str],
    result: &mut VerificationResult,
) -> Option<Address> {
    let path_label = format!("core.{}", path.join("."));
    let mut current = &artifact.core;
    for segment in path {
        let Some(next) = current.get(*segment) else {
            result.report_error(&format!("{path_label} is required"));
            return None;
        };
        current = next;
    }

    let Some(raw) = current.as_str() else {
        result.report_error(&format!("{path_label} must be an address string"));
        return None;
    };

    match Address::from_str(raw) {
        Ok(address) => Some(address),
        Err(err) => {
            result.report_error(&format!("{path_label} is not a valid address: {err}"));
            None
        }
    }
}

/// Lightweight cross-check that `addr` has runtime code on L1. PUVT's
/// `create2_known_bytecodes` only maps addresses for which the deploy's
/// init bytecode matched a known contract in `AllContractsHashes.json` —
/// PUH/Guardians come from the `zk-governance` repo whose artifacts aren't
/// in that file, so we can't bytecode-verify them. The minimum useful
/// invariant is "the address actually has code" — proves the new impl /
/// guardians address wasn't a typo / dangling address.
pub(super) async fn verify_address_has_code(
    addr: &Address,
    label: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let provider = verifiers.network_verifier.get_l1_provider();
    match provider.get_code_at(*addr).await {
        Ok(code) if !code.is_empty() => {
            result.report_ok(&format!(
                "{label} {addr} is deployed (code size {} bytes)",
                code.len()
            ));
            0
        }
        Ok(_) => {
            result.report_error(&format!(
                "{label} {addr} has no code — governance call references an undeployed address"
            ));
            1
        }
        Err(err) => {
            result.report_warn(&format!(
                "Skipping code-presence check for {label} {addr}: {err}"
            ));
            0
        }
    }
}
