//! The reporting surface every verifier writes to, and the rule that decides whether a run
//! passed.
//!
//! Split out of [`verifiers`](super::verifiers) — which is otherwise entirely v31 machinery (the
//! address book, the bytecode fetcher, the network verifier and the `expect_*` helpers built on
//! them) — so that the registry-driven verifier does not depend on the v31 tree for its one
//! shared piece. When the v31 tree is retired, `verifiers.rs` goes with it and this module stays.
//!
//! The v31 `expect_*` helpers remain inherent methods on [`VerificationResult`], declared in
//! `verifiers.rs` alongside the `Verifiers` context they all take.
//!
//! # Errors versus warnings
//!
//! Only errors fail a run ([`VerificationResult::ensure_success`]). So anything a reviewer could
//! not establish — code the reviewed commit does not produce, an object whose construction could
//! not be re-derived, a call the review does not account for — is an ERROR, never a warning: a
//! warning rides along with a successful review and reads, afterwards, exactly like a check that
//! passed. Warnings are for things a reviewer chose not to check (an optional input they did not
//! supply) and for facts worth surfacing that do not bear on whether the upgrade is what it
//! claims.

use console::style;
use std::fmt::{self, Display};

#[derive(Default)]
pub(crate) struct VerificationResult {
    pub(crate) result: String,
    pub(crate) warnings: u64,
    pub(crate) errors: u64,
}

impl VerificationResult {
    pub(crate) fn print_info(&self, info: &str) {
        println!("{}", info);
    }

    pub(crate) fn report_ok(&self, info: &str) {
        println!("{} {}", style("[OK]: ").green(), info);
    }

    pub(crate) fn report_warn(&mut self, warn: &str) {
        self.warnings += 1;
        println!("{} {}", style("[WARN]:").yellow(), warn);
    }

    pub(crate) fn report_error(&mut self, error: &str) {
        self.errors += 1;
        println!("{} {}", style("[ERROR]:").red(), error);
    }

    pub(crate) fn ensure_success(&self) -> anyhow::Result<()> {
        if self.errors > 0 {
            anyhow::bail!(
                "verification failed with {} error(s) and {} warning(s)",
                self.errors,
                self.warnings
            );
        }

        Ok(())
    }
}

impl Display for VerificationResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.errors > 0 {
            write!(
                f,
                "{} errors: {}, warnings: {} - result: {}",
                style("ERROR").red(),
                self.errors,
                self.warnings,
                self.result
            )
        } else if self.warnings > 0 {
            write!(
                f,
                "{} warnings: {} - result: {}",
                style("WARN").yellow(),
                self.warnings,
                self.result
            )
        } else {
            write!(f, "{} - result: {}", style("OK").green(), self.result)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule the whole tool turns on: an error fails the run, a warning does not.
    #[test]
    fn only_errors_fail_a_run() {
        let mut result = VerificationResult::default();
        assert!(result.ensure_success().is_ok());
        result.report_warn("an optional input was not supplied");
        assert!(
            result.ensure_success().is_ok(),
            "a warning must not fail a run — which is why nothing unverifiable may be one"
        );
        result.report_error("the object's construction could not be re-derived");
        assert!(result.ensure_success().is_err());
    }

    #[test]
    fn counts_accumulate_across_reports() {
        let mut result = VerificationResult::default();
        result.report_error("a");
        result.report_error("b");
        result.report_warn("c");
        assert_eq!((result.errors, result.warnings), (2, 1));
    }
}
