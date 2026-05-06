use std::path::PathBuf;

use clap::{Parser, ValueEnum};

use crate::{
    common::logger,
    upgrade_verification::{
        artifact_shape,
        artifacts::EcosystemUpgradeArtifact,
        verifiers::{GenesisConfigKind, VerificationResult},
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

    /// Optional era-contracts commit to load AllContractsHashes.json from GitHub.
    /// If omitted, AllContractsHashes.json is read from the repository root.
    #[clap(long)]
    pub contracts_commit: Option<String>,

    /// Existing ZK chain id used for live chain-specific checks.
    ///
    /// This mirrors the legacy PUVT `--era-chain-id` argument: the L1 RPC is
    /// used to read Bridgehub/diamond state, while this id selects which chain's
    /// diamond to inspect.
    #[clap(long, alias = "chain-id")]
    pub era_chain_id: Option<u64>,

    /// Which local v31 genesis config to load.
    #[clap(long, value_enum, default_value_t = VerifyUpgradeGenesisConfig::Era)]
    pub genesis_config: VerifyUpgradeGenesisConfig,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum VerifyUpgradeGenesisConfig {
    Era,
    ZksyncOs,
}

impl From<VerifyUpgradeGenesisConfig> for GenesisConfigKind {
    fn from(value: VerifyUpgradeGenesisConfig) -> Self {
        match value {
            VerifyUpgradeGenesisConfig::Era => Self::Era,
            VerifyUpgradeGenesisConfig::ZksyncOs => Self::ZksyncOs,
        }
    }
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    logger::step("Verifying ecosystem upgrade artifacts");
    logger::info(format!("Ecosystem TOML: {}", args.ecosystem_toml.display()));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Genesis config: {:?}", args.genesis_config));
    if let Some(contracts_commit) = &args.contracts_commit {
        logger::info(format!("Contracts commit: {contracts_commit}"));
    } else {
        logger::info("Contracts hashes: local repository AllContractsHashes.json");
    }
    if let Some(era_chain_id) = args.era_chain_id {
        logger::info(format!("Representative ZK chain ID: {era_chain_id}"));
    }

    let artifact = EcosystemUpgradeArtifact::read(&args.ecosystem_toml)?;
    artifact_shape::verify(&artifact)?;

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        &artifact,
        &args.l1_rpc_url,
        args.contracts_commit.as_deref(),
        args.era_chain_id,
        args.genesis_config.into(),
        &mut result,
    )
    .await;

    logger::outro(format!("{}", result));
    verification_result?;
    result.ensure_success()
}
