use alloy::{hex, sol, sol_types::SolValue};
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

    let address_from_call = verifiers
        .address_verifier
        .address_to_name
        .get(&call.target)
        .map(String::as_str)
        .unwrap_or_else(|| "Unknown");

    if target != address_from_call {
        return Err(format!(
            "Expected call to: {} with data: {} not found - instead the call is to {}",
            target, method_name, address_from_call
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
