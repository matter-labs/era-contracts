//! Stage 2 — post-upgrade governance calls.
//!
//! Canonical shape:
//!   `[ unpauseMigration, (checkProtocolUpgradePresence, checkMigrationsUnpaused) × N CTMs ]`
//!
//! v31 carried two settlement-layer sections around this core (a decommission prefix and a
//! bring-up appendix); v33 has neither, so stage 2 is exactly the core.

use crate::upgrade_verification::{
    artifacts::EcosystemUpgradeArtifact,
    verifiers::{VerificationResult, Verifiers},
};

use super::helpers::{required_ctm_address, verify_call_by_address, verify_call_by_name};
use super::GovernanceStage2Calls;

impl GovernanceStage2Calls {
    /// Stage 2: `unpauseMigration` then per-CTM
    /// (`checkProtocolUpgradePresence`, `checkMigrationsUnpaused`).
    pub(crate) async fn verify_artifact(
        &self,
        artifact: &EcosystemUpgradeArtifact,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Gov stage 2 calls ===");

        let mut errors = 0;
        let expected_call_count = 1 + artifact.ctms.len() * 2;

        // Call 0 — ChainAssetHandler.unpauseMigration() re-enables cross-chain
        // migrations now that impls are swapped.
        errors += verify_call_by_name(
            &self.calls,
            0,
            "chain_asset_handler_proxy",
            "unpauseMigration()",
            verifiers,
            result,
        );

        // Per-CTM (2 calls per CTM, in artifact order):
        //   +0 stage-validator.checkProtocolUpgradePresence()
        //   +1 stage-validator.checkMigrationsUnpaused()
        for (ctm_index, ctm) in artifact.ctms.iter().enumerate() {
            let validator_label = format!("{}.upgrade_stage_validator", ctm.flavor.label());
            let Some(validator) = required_ctm_address(
                ctm,
                &["deployed_addresses", "upgrade_stage_validator"],
                result,
            ) else {
                errors += 2;
                continue;
            };

            let block = 1 + ctm_index * 2;
            errors += verify_call_by_address(
                &self.calls,
                block,
                validator,
                &validator_label,
                "checkProtocolUpgradePresence()",
                verifiers,
                result,
            );
            errors += verify_call_by_address(
                &self.calls,
                block + 1,
                validator,
                &validator_label,
                "checkMigrationsUnpaused()",
                verifiers,
                result,
            );
        }

        match self.calls.elems.len().cmp(&expected_call_count) {
            std::cmp::Ordering::Less => {
                result.report_error(&format!(
                    "Too few calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Greater => {
                result.report_error(&format!(
                    "Too many calls: expected {} but got {}.",
                    expected_call_count,
                    self.calls.elems.len()
                ));
                errors += 1;
            }
            std::cmp::Ordering::Equal => {}
        }

        if errors > 0 {
            anyhow::bail!("{} errors", errors);
        }
        Ok(())
    }
}
