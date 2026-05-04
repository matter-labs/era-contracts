use std::path::PathBuf;

use clap::Parser;

use crate::{
    common::logger,
    upgrade_verification::{
        artifact_shape, artifacts::EcosystemUpgradeArtifact, verifiers::VerificationResult,
    },
};

/// Verify prepared ecosystem upgrade artifacts.
///
/// This command is intentionally read-only. It consumes the TOML produced by
/// `ecosystem upgrade-prepare` and performs validation locally without running
/// forge scripts or creating an anvil fork.
#[derive(Debug, Clone, Parser)]
pub struct VerifyUpgradeArgs {
    /// L1 RPC URL used by later verification phases for read-only on-chain checks.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Path to the v31 ecosystem upgrade TOML produced by `upgrade-prepare`.
    #[clap(long)]
    pub ecosystem_toml: PathBuf,
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    logger::step("Verifying ecosystem upgrade artifacts");
    logger::info(format!("Ecosystem TOML: {}", args.ecosystem_toml.display()));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));

    let artifact = EcosystemUpgradeArtifact::read(&args.ecosystem_toml)?;
    artifact_shape::verify(&artifact)?;

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        &artifact,
        &args.l1_rpc_url,
        &mut result,
    )
    .await;

    logger::outro(format!("{}", result));
    verification_result?;
    result.ensure_success()
}
