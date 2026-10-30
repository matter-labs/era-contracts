//! The one rule every registry package kind holds its bundle to: the calls other than the
//! executor legs ARE the package's governance-phase declarations, one for one and in declared
//! order, every declaration present — the shape the merge emits, and the one its own
//! `check_bundle_provenance` holds each prepare to through the same matcher
//! ([`DeclaredCalls`]). The bootstrap's derived run and a replacement's `forward` are declared
//! like any other call. A call the kind's authority rule already refused is left out of the
//! matching, so a declaration of it reports as never carried.

use std::ops::Range;

use crate::common::external_actions::{Accounted, DeclaredCalls, ExternalAction};
use crate::common::governance_calls::GovernanceCall;
use crate::upgrade_verification::report::VerificationResult;

/// The calls a package kind derives itself, for the report.
pub(super) struct DerivedRun<'a> {
    /// Bundle indices of the derived calls, when found.
    pub(super) at: Option<Range<usize>>,
    /// Names them as a whole: "the legs", "the derived run", "the forward".
    pub(super) name: &'a str,
    /// Names one of them: "a leg of this upgrade", "derived by the sequence", "the forward".
    pub(super) member: &'a str,
    /// Whether the run's calls are among those judged, as declarations like any other (the
    /// bootstrap's derived run, a replacement's forward), rather than left out (the legs).
    pub(super) declared: bool,
}

/// `calls` — the bundle minus the executor legs and minus any call the kind's authority rule
/// already refused, with bundle indices — against `declared`. Returns whether they account
/// exactly.
pub(super) fn judge_declared_calls(
    calls: &[(usize, &GovernanceCall)],
    declared: &[ExternalAction],
    run: &DerivedRun<'_>,
    result: &mut VerificationResult,
) -> bool {
    let account = DeclaredCalls::match_calls(calls.iter().map(|(_, call)| *call), declared);
    let in_run =
        |index: usize| run.declared && run.at.as_ref().is_some_and(|at| at.contains(&index));
    for ((index, call), accounted) in calls.iter().zip(&account.calls) {
        let selector = alloy::hex::encode(call.data.get(..4).unwrap_or_default());
        match accounted {
            Accounted::Declared(i) => {
                let side = match &run.at {
                    Some(at) if at.contains(index) => "in",
                    Some(at) if *index < at.start => "before",
                    Some(_) => "after",
                    None => "beside",
                };
                result.print_info(&format!(
                    "  call {index} -> declared external action `{}` on {} (selector \
                     0x{selector}, value {}), {side} {}",
                    account.actions[*i].label, call.target, call.value, run.name
                ));
            }
            Accounted::Repeat => result.report_error(&format!(
                "call {index} to {} (selector 0x{selector}, value {}) repeats a declared \
                 governance external action more often than it is declared: each declaration \
                 accounts for exactly one call",
                call.target, call.value
            )),
            Accounted::Undeclared if in_run(*index) => result.report_error(&format!(
                "call {index} of {} to {} (selector 0x{selector}) is not declared: the prepares \
                 declare every call of the bundle but the executor legs, so this package is not \
                 the one they produced",
                run.name, call.target
            )),
            Accounted::Undeclared => result.report_error(&format!(
                "call {index} to {} (selector 0x{selector}, value {}) is neither {} nor a \
                 declared governance external action: the bundle carries an instruction no part \
                 of this review accounts for",
                call.target, call.value, run.member
            )),
        }
    }
    for &i in &account.unclaimed {
        result.report_error(&format!(
            "the package declares a governance external action the bundle never carries — {}: \
             the declaration a reviewer reads describes a call governance would not sign",
            account.actions[i].describe()
        ));
    }
    if !account.in_order {
        result.report_error(
            "the declared governance external actions appear out of their declared order: the \
             prepares emit them in declaration order, so a reordered bundle is not the one they \
             produced",
        );
    }
    let exact = account.is_exact();
    if exact && !calls.is_empty() {
        result.report_ok(&if run.declared {
            format!(
                "every call of the bundle, {} included, is a declared governance external action, \
                 one for one and in declared order",
                run.name
            )
        } else {
            format!(
                "every call outside {} is a declared governance external action, one for one and \
                 in declared order",
                run.name
            )
        });
    }
    exact
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Address, U256};

    fn call(byte: u8) -> GovernanceCall {
        GovernanceCall {
            target: Address::repeat_byte(byte),
            value: U256::ZERO,
            data: vec![0xaa, 0xbb, 0xcc, byte],
        }
    }

    fn judge(calls: &[(usize, &GovernanceCall)], declared: bool) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_declared_calls(
            calls,
            &[],
            &DerivedRun {
                at: Some(1..3),
                name: "the run",
                member: "part of the run",
                declared,
            },
            &mut result,
        );
        result
    }

    /// An undeclared call inside a run whose calls are declarations (the bootstrap's, a
    /// replacement's forward) is a package the prepares did not produce; one inside a run of
    /// legs, which are never declarations, is an undeclared extra like any other.
    #[test]
    fn an_undeclared_call_in_the_run_is_named_by_what_the_run_is() {
        let stray = call(0x11);
        let result = judge(&[(1, &stray)], true);
        assert_eq!(result.errors, 1);
        assert!(result.has_error("call 1 of the run to"));
        assert!(result.has_error("is not declared"));

        let result = judge(&[(1, &stray)], false);
        assert_eq!(result.errors, 1);
        assert!(result.has_error("is neither part of the run nor a declared"));
    }
}
