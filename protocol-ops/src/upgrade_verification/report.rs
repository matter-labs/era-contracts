use std::fmt::{self, Display};

use colored::Colorize;

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

    #[allow(dead_code)]
    pub(crate) fn report_ok(&self, info: &str) {
        println!("{} {}", "[OK]: ".green(), info);
    }

    #[allow(dead_code)]
    pub(crate) fn report_warn(&mut self, warn: &str) {
        self.warnings += 1;
        println!("{} {}", "[WARN]:".yellow(), warn);
    }

    #[allow(dead_code)]
    pub(crate) fn report_error(&mut self, error: &str) {
        self.errors += 1;
        println!("{} {}", "[ERROR]:".red(), error);
    }

    pub(crate) fn ensure_success(&self) -> anyhow::Result<()> {
        if self.errors > 0 {
            anyhow::bail!(
                "verify-upgrade failed with {} error(s) and {} warning(s)",
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
                "ERROR".red(),
                self.errors,
                self.warnings,
                self.result
            )
        } else if self.warnings > 0 {
            write!(
                f,
                "{} warnings: {} - result: {}",
                "WARN".yellow(),
                self.warnings,
                self.result
            )
        } else {
            write!(f, "{} - result: {}", "OK".green(), self.result)
        }
    }
}
