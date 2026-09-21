//! Regression checks for tracer-observed bootloader memory writes.
//!
//! A count-only check misses reordered hooks, removed parameter stores and a store moved into
//! a near-call helper. Capture the writes before execution so the parameter snapshot is exactly
//! what the server observes when the trigger fires. No server VM fixes are needed by this tracer.

use std::collections::BTreeMap;

use crate::hook::{
    OperatorHookWrite, HOOK_ACCOUNT_VALIDATION_ENTERED, HOOK_ASK_OPERATOR_FOR_REFUND,
    HOOK_CATCH_NEAR_CALL, HOOK_DEBUG_LOG, HOOK_DEBUG_RETURNDATA, HOOK_EXECUTION_RESULT,
    HOOK_FINAL_L2_STATE_INFO, HOOK_NOTIFY_ABOUT_REFUND, HOOK_PAYMASTER_VALIDATION_ENTERED,
    HOOK_PUBDATA_REQUESTED, HOOK_TX_HAS_ENDED, HOOK_VALIDATION_EXITED, HOOK_VALIDATION_STEP_ENDED,
    VM_HOOK_PARAMS,
};

// `callstack.inner` includes the initial frame below the bootloader root frame.
const ROOT_FRAME_DEPTH: usize = 1;
const VALIDATION_FRAME_DEPTH: usize = ROOT_FRAME_DEPTH + 1;

const PER_TRANSACTION_HOOKS: [u32; 5] = [
    HOOK_VALIDATION_STEP_ENDED,
    HOOK_EXECUTION_RESULT,
    HOOK_ASK_OPERATOR_FOR_REFUND,
    HOOK_NOTIFY_ABOUT_REFUND,
    HOOK_TX_HAS_ENDED,
];

// Complete non-debug sequence of src/test_transactions/{0,1}.json, including the second tx's
// caught near-call failure and final pubdata request. If fixtures change, review this explicitly;
// deriving it from the observed trace would hide bugs.
const PRODUCTION_FIXTURE_HOOKS: [u32; 21] = [
    HOOK_ACCOUNT_VALIDATION_ENTERED,
    HOOK_VALIDATION_EXITED,
    HOOK_ACCOUNT_VALIDATION_ENTERED,
    HOOK_VALIDATION_EXITED,
    HOOK_VALIDATION_STEP_ENDED,
    HOOK_EXECUTION_RESULT,
    HOOK_ASK_OPERATOR_FOR_REFUND,
    HOOK_NOTIFY_ABOUT_REFUND,
    HOOK_TX_HAS_ENDED,
    HOOK_ACCOUNT_VALIDATION_ENTERED,
    HOOK_VALIDATION_EXITED,
    HOOK_ACCOUNT_VALIDATION_ENTERED,
    HOOK_VALIDATION_EXITED,
    HOOK_VALIDATION_STEP_ENDED,
    HOOK_CATCH_NEAR_CALL,
    HOOK_EXECUTION_RESULT,
    HOOK_ASK_OPERATOR_FOR_REFUND,
    HOOK_NOTIFY_ABOUT_REFUND,
    HOOK_TX_HAS_ENDED,
    HOOK_FINAL_L2_STATE_INFO,
    HOOK_PUBDATA_REQUESTED,
];

fn required_parameter_count(hook: u32) -> usize {
    match hook {
        HOOK_ASK_OPERATOR_FOR_REFUND => VM_HOOK_PARAMS as usize,
        HOOK_EXECUTION_RESULT | HOOK_DEBUG_LOG => 2,
        HOOK_NOTIFY_ABOUT_REFUND | HOOK_DEBUG_RETURNDATA => 1,
        _ => 0,
    }
}

fn requires_root_frame(hook: u32) -> bool {
    PER_TRANSACTION_HOOKS.contains(&hook)
        || matches!(hook, HOOK_FINAL_L2_STATE_INFO | HOOK_PUBDATA_REQUESTED)
}

/// Checks successful integration runs, including variants that intentionally change tx data.
pub fn check_operator_hooks(writes: &[OperatorHookWrite], tx_count: u32) -> Result<(), String> {
    let mut counts = BTreeMap::<u32, u32>::new();
    let mut pending = [None; VM_HOOK_PARAMS as usize];
    let mut transaction_sequence = Vec::new();

    for write in writes {
        match write {
            OperatorHookWrite::Parameter {
                index,
                value,
                depth,
            } => {
                pending[*index] = Some((*value, *depth));
            }
            OperatorHookWrite::Trigger { id, params, depth } => {
                *counts.entry(*id).or_default() += 1;
                if requires_root_frame(*id) && *depth != ROOT_FRAME_DEPTH {
                    return Err(format!(
                        "hook {id} fired at depth {depth}, expected root depth {ROOT_FRAME_DEPTH}"
                    ));
                }
                for index in 0..required_parameter_count(*id) {
                    let Some((value, parameter_depth)) = pending[index] else {
                        return Err(format!("hook {id} parameter {index} was not written since the preceding trigger"));
                    };
                    if value != params[index] {
                        return Err(format!(
                            "hook {id} parameter {index} snapshot differs from its preceding write"
                        ));
                    }
                    if parameter_depth != *depth {
                        return Err(format!("hook {id} parameter {index} was written at depth {parameter_depth}, trigger depth {depth}"));
                    }
                }
                // A stale value from a preceding hook must not satisfy the next hook's contract.
                pending.fill(None);
                if PER_TRANSACTION_HOOKS.contains(id) {
                    transaction_sequence.push(*id);
                }
            }
        }
    }

    let expected: Vec<_> = (0..tx_count).flat_map(|_| PER_TRANSACTION_HOOKS).collect();
    if transaction_sequence != expected {
        return Err(format!("per-transaction hook order differs: expected {expected:?}, got {transaction_sequence:?}"));
    }
    let count = |id| counts.get(&id).copied().unwrap_or_default();
    let entered = count(HOOK_ACCOUNT_VALIDATION_ENTERED) + count(HOOK_PAYMASTER_VALIDATION_ENTERED);
    let exited = count(HOOK_VALIDATION_EXITED);
    if entered == 0 || entered != exited {
        return Err(format!(
            "validation entered {entered} times but exited {exited} times"
        ));
    }
    Ok(())
}

/// Validation hooks legitimately occur inside their existing transaction near call, unlike
/// root-sensitive operator hooks. Check their exact fixture depth without flattening that call.
pub fn check_production_operator_hooks(
    writes: &[OperatorHookWrite],
    tx_count: u32,
) -> Result<(), String> {
    check_operator_hooks(writes, tx_count)?;
    let mut sequence = Vec::new();
    for write in writes {
        if let OperatorHookWrite::Trigger { id, depth, .. } = write {
            if matches!(*id, HOOK_DEBUG_LOG | HOOK_DEBUG_RETURNDATA) {
                continue;
            }
            if matches!(
                *id,
                HOOK_ACCOUNT_VALIDATION_ENTERED
                    | HOOK_PAYMASTER_VALIDATION_ENTERED
                    | HOOK_VALIDATION_EXITED
            ) && *depth != VALIDATION_FRAME_DEPTH
            {
                return Err(format!("validation hook {id} fired at depth {depth}, expected {VALIDATION_FRAME_DEPTH}"));
            }
            sequence.push(*id);
        }
    }
    if sequence != PRODUCTION_FIXTURE_HOOKS {
        return Err(format!("production fixture hook sequence differs: expected {PRODUCTION_FIXTURE_HOOKS:?}, got {sequence:?}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use zksync_types::U256;

    const FIXTURE_TX_COUNT: u32 = 2;

    // Synthetic traces isolate the checker itself. Actual bytecode is exercised by main.rs.
    fn valid_trace() -> Vec<OperatorHookWrite> {
        let mut writes = Vec::new();
        for id in PRODUCTION_FIXTURE_HOOKS {
            let depth = if matches!(id, HOOK_ACCOUNT_VALIDATION_ENTERED | HOOK_VALIDATION_EXITED) {
                VALIDATION_FRAME_DEPTH
            } else {
                ROOT_FRAME_DEPTH
            };
            let mut params = [U256::zero(); VM_HOOK_PARAMS as usize];
            for (index, value) in params
                .iter_mut()
                .enumerate()
                .take(required_parameter_count(id))
            {
                *value = U256::from(index + 1);
                writes.push(OperatorHookWrite::Parameter {
                    index,
                    value: *value,
                    depth,
                });
            }
            writes.push(OperatorHookWrite::Trigger { id, params, depth });
        }
        writes
    }

    #[test]
    fn accepts_root_hooks_and_existing_nested_validation() {
        assert_eq!(
            check_production_operator_hooks(&valid_trace(), FIXTURE_TX_COUNT),
            Ok(())
        );
    }

    #[test]
    fn rejects_missing_hook() {
        let mut writes = valid_trace();
        writes.retain(|write| {
            !matches!(
                write,
                OperatorHookWrite::Trigger {
                    id: HOOK_VALIDATION_STEP_ENDED,
                    ..
                }
            )
        });
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("order differs"));
    }

    #[test]
    fn rejects_reordered_hooks_even_with_identical_counts() {
        let mut writes = valid_trace();
        // The parameterless final hooks isolate ordering from parameter checks.
        let last = writes.len() - 1;
        writes.swap(last, last - 1);
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("sequence differs"));
    }

    #[test]
    fn rejects_missing_parameter_even_when_memory_keeps_the_value() {
        let mut writes = valid_trace();
        let index = writes
            .iter()
            .position(|write| matches!(write, OperatorHookWrite::Parameter { .. }))
            .unwrap();
        writes.remove(index);
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("was not written"));
    }

    #[test]
    fn rejects_parameter_snapshot_mismatch() {
        let mut writes = valid_trace();
        for write in &mut writes {
            if let OperatorHookWrite::Trigger {
                id: HOOK_EXECUTION_RESULT,
                params,
                ..
            } = write
            {
                params[0] = U256::zero();
                break;
            }
        }
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("snapshot differs"));
    }

    #[test]
    fn rejects_extra_store_helper_frame() {
        let mut writes = valid_trace();
        for write in &mut writes {
            if let OperatorHookWrite::Trigger {
                id: HOOK_PUBDATA_REQUESTED,
                depth,
                ..
            } = write
            {
                *depth += 1;
            }
        }
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("expected root depth"));
    }

    #[test]
    fn rejects_extra_validation_helper_frame() {
        let mut writes = valid_trace();
        for write in &mut writes {
            if let OperatorHookWrite::Trigger {
                id: HOOK_ACCOUNT_VALIDATION_ENTERED,
                depth,
                ..
            } = write
            {
                *depth += 1;
            }
        }
        assert!(check_production_operator_hooks(&writes, FIXTURE_TX_COUNT)
            .unwrap_err()
            .contains("validation hook"));
    }
}
