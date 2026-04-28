use std::path::{Path, PathBuf};

use clap::Parser;

use crate::{
    common::logger,
    upgrade_verification::{
        artifact_shape, artifacts::PreparedUpgradeArtifacts, verifiers::VerificationResult,
    },
};

const DEFAULT_CORE_TOML_FILE: &str = "v31-upgrade-core.toml";
const DEFAULT_CTM_TOML_FILE: &str = "v31-upgrade-ctm.toml";

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

    /// Path to the v31 core upgrade TOML produced by `upgrade-prepare`.
    /// Defaults to `v31-upgrade-core.toml` next to `--ecosystem-toml`.
    #[clap(long)]
    pub core_toml: Option<PathBuf>,

    /// Path to the v31 CTM upgrade TOML produced by `upgrade-prepare`.
    /// Defaults to `v31-upgrade-ctm.toml` next to `--ecosystem-toml`.
    #[clap(long)]
    pub ctm_toml: Option<PathBuf>,
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    logger::step("Verifying ecosystem upgrade artifacts");
    logger::info(format!("Ecosystem TOML: {}", args.ecosystem_toml.display()));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));

    let core_toml = args
        .core_toml
        .unwrap_or_else(|| sibling_path(&args.ecosystem_toml, DEFAULT_CORE_TOML_FILE));
    let ctm_toml = args
        .ctm_toml
        .unwrap_or_else(|| sibling_path(&args.ecosystem_toml, DEFAULT_CTM_TOML_FILE));
    logger::info(format!("Core TOML: {}", core_toml.display()));
    logger::info(format!("CTM TOML: {}", ctm_toml.display()));

    let artifacts = PreparedUpgradeArtifacts::read(&args.ecosystem_toml, &core_toml, &ctm_toml)?;
    artifact_shape::verify(&artifacts)?;

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        &artifacts,
        &args.l1_rpc_url,
        &mut result,
    )
    .await;

    logger::outro(format!("{}", result));
    verification_result?;
    result.ensure_success()
}

fn sibling_path(base: &Path, file_name: &str) -> PathBuf {
    base.parent()
        .unwrap_or_else(|| Path::new(""))
        .join(file_name)
}
