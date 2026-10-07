//! Regression check for the operator VM hooks emitted by the bootloader.
//!
//! The bootloader reports progress to the server by writing to a memory slot that the server's
//! tracer watches and that the bootloader itself never reads back. From the compiler's point of
//! view those writes are dead stores, and an optimizer may legitimately drop all but the last one
//! in a sequence: zksolc 1.5.15+ does exactly that when they are plain `mstore`s, which silently
//! removed `EXECUTION_RESULT`, `NOTIFY_ABOUT_REFUND` and `VALIDATION_STEP_ENDED` from the
//! production bootloader. The pinned DSE limits preserve these stores in the caller frame,
//! and this check makes the expected hook sequence explicit so that a regression shows up
//! as a failed test instead of a sequencer that quietly stops seeing transaction results.

use std::collections::BTreeMap;

use crate::hook::{
    HOOK_ACCOUNT_VALIDATION_ENTERED, HOOK_ASK_OPERATOR_FOR_REFUND, HOOK_EXECUTION_RESULT,
    HOOK_NOTIFY_ABOUT_REFUND, HOOK_PAYMASTER_VALIDATION_ENTERED, HOOK_TX_HAS_ENDED,
    HOOK_VALIDATION_EXITED, HOOK_VALIDATION_STEP_ENDED,
};

/// Hooks the bootloader must emit exactly once for every processed transaction.
const PER_TRANSACTION_HOOKS: [(u32, &str); 5] = [
    (HOOK_VALIDATION_STEP_ENDED, "VALIDATION_STEP_ENDED"),
    (HOOK_TX_HAS_ENDED, "TX_HAS_ENDED"),
    (HOOK_ASK_OPERATOR_FOR_REFUND, "ASK_OPERATOR_FOR_REFUND"),
    (HOOK_NOTIFY_ABOUT_REFUND, "NOTIFY_ABOUT_REFUND"),
    (HOOK_EXECUTION_RESULT, "EXECUTION_RESULT"),
];

/// Checks that a bootloader run over `tx_count` transactions emitted the operator hooks the
/// server relies on: the per-transaction hooks exactly once per transaction, and every
/// validation-entered hook matched by a validation-exited one.
pub fn check_operator_hooks(counts: &BTreeMap<u32, u32>, tx_count: u32) -> Result<(), String> {
    let count = |hook_id: u32| counts.get(&hook_id).copied().unwrap_or(0);
    let mut problems = Vec::new();

    for (hook_id, name) in PER_TRANSACTION_HOOKS {
        let emitted = count(hook_id);
        if emitted != tx_count {
            problems.push(format!(
                "hook {hook_id} ({name}) emitted {emitted} times, expected {tx_count}"
            ));
        }
    }

    let entered = count(HOOK_ACCOUNT_VALIDATION_ENTERED) + count(HOOK_PAYMASTER_VALIDATION_ENTERED);
    let exited = count(HOOK_VALIDATION_EXITED);
    if entered == 0 || entered != exited {
        problems.push(format!(
            "validation entered {entered} times but exited {exited} times"
        ));
    }

    if problems.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "operator VM hook sequence is broken for {tx_count} transactions: {}. All hook counts: {counts:?}",
            problems.join("; ")
        ))
    }
}
