use alloy::{hex, primitives::U256, sol, sol_types::SolValue};
use std::collections::VecDeque;

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::utils::compute_selector;

sol! {
    #[derive(Debug)]
    struct UpgradeProposal {
        Call[] calls;
        address executor;
        bytes32 salt;
    }

    #[derive(Debug)]
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    #[derive(Debug)]
    struct CallList {
        Call[] elems;
    }
}

impl CallList {
    pub fn parse(hex_data: &str) -> Self {
        CallList::abi_decode_sequence(&hex::decode(hex_data).expect("Invalid hex"))
            .expect("Decoding calls failed")
    }

    /// Verifies that the `target` of each call corresponds to the 0th item in each of
    /// the `list_of_calls` tuple.
    /// Also, double checks that the selector of each call corresponds to the function
    /// signature in the 1th item in each of the tuple.
    pub fn verify(
        &self,
        list_of_calls: &[(&str, &str)],
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        let mut elems = VecDeque::from(self.elems.clone());
        let mut errors = 0;

        for &(target, method_name) in list_of_calls {
            match expect_simple_call(verifiers, elems.pop_front(), target, method_name) {
                Ok(msg) => result.report_ok(&msg),
                Err(msg) => {
                    result.report_error(&msg);
                    errors += 1;
                }
            }
        }

        if !elems.is_empty() {
            errors += 1;
            result.report_error(&format!(
                "Too many calls: expected {} but got {}.",
                list_of_calls.len(),
                list_of_calls.len() + elems.len()
            ));
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors)
        }
        Ok(())
    }
}

fn expect_simple_call(
    verifiers: &Verifiers,
    call: Option<Call>,
    target: &str,
    method_name: &str,
) -> Result<String, String> {
    let call = call.ok_or_else(|| {
        format!(
            "Expected call to: {} with data: {} not found",
            target, method_name
        )
    })?;

    let expected_target = verifiers
        .address_verifier
        .name_to_address
        .get(target)
        .ok_or_else(|| format!("Expected call target {} is not known", target))?;

    if &call.target != expected_target {
        let actual_target = verifiers.address_verifier.name_or_unknown(&call.target);
        return Err(format!(
            "Expected call to: {} with data: {} not found - instead the call is to {}",
            target, method_name, actual_target
        ));
    }

    if call.value != U256::ZERO {
        return Err(format!(
            "Expected call to {} with {} to have zero value, but got {}",
            target, method_name, call.value
        ));
    }

    let method_selector = compute_selector(method_name);

    if call.data.len() < 4 {
        return Err("Call data is too short".into());
    }

    let actual_selector = hex::encode(&call.data[0..4]);
    if actual_selector != method_selector {
        return Err(format!(
            "Expected call to: {} not found - instead the call selector was {}.",
            method_name, actual_selector
        ));
    }

    Ok(format!("Called {} with {}", target, method_name))
}
