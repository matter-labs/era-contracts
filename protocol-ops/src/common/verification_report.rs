//! Shared pass / warn / fail reporter for the verification trees.
//!
//! Used by both `upgrade_verification` (the v31 PUVT, which verifies an
//! upgrade against its artifacts) and `deployment_verification` (which
//! verifies a freshly deployed ecosystem against a local contracts build).

use console::style;

pub(crate) struct VerificationResult {
    /// Command name used in the failure message, e.g. `verify-upgrade`.
    label: &'static str,
    pub(crate) result: String,
    pub(crate) warnings: u64,
    pub(crate) errors: u64,
}

impl Default for VerificationResult {
    fn default() -> Self {
        Self::labelled("verify-upgrade")
    }
}

impl VerificationResult {
    pub(crate) fn labelled(label: &'static str) -> Self {
        Self {
            label,
            result: String::new(),
            warnings: 0,
            errors: 0,
        }
    }

    pub(crate) fn print_info(&self, info: &str) {
        println!("{}", info);
    }

    /// Section heading, so long reports stay navigable.
    pub(crate) fn print_section(&self, title: &str) {
        println!();
        println!("{}", style(format!("── {title} ──")).bold());
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

    /// Reports `ok_msg` when `condition` holds and `err_msg` otherwise.
    pub(crate) fn expect(&mut self, condition: bool, ok_msg: &str, err_msg: &str) -> bool {
        if condition {
            self.report_ok(ok_msg);
        } else {
            self.report_error(err_msg);
        }
        condition
    }

    pub(crate) fn ensure_success(&self) -> anyhow::Result<()> {
        if self.errors > 0 {
            anyhow::bail!(
                "{} failed with {} error(s) and {} warning(s)",
                self.label,
                self.errors,
                self.warnings
            );
        }

        Ok(())
    }
}
