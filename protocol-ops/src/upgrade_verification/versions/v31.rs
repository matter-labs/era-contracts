use crate::upgrade_verification::{
    artifacts::PreparedUpgradeArtifacts, report::VerificationResult,
};

pub(crate) async fn verify(
    _artifacts: &PreparedUpgradeArtifacts,
    _l1_rpc_url: &str,
    result: &mut VerificationResult,
) -> anyhow::Result<()> {
    result.print_info("== Config verification ==");

    // The next steps in this module should mirror PUVT's `UpgradeOutput::verify`:
    // decode stage calls, verify stage ordering/selectors, decode setNewVersionUpgrade,
    // and validate the embedded L2 upgrade transaction.

    Ok(())
}
