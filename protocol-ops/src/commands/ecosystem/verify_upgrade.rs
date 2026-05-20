use std::path::PathBuf;
use std::str::FromStr;

use alloy::primitives::FixedBytes;
use clap::Parser;

use crate::{
    commands::dev::execute_safe::ExecutedBundle,
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

    /// Gateway RPC URL used by read-only gateway-side checks.
    #[clap(long, alias = "gw-rpc")]
    pub gw_rpc_url: String,

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
    pub era_chain_id: u64,

    /// Path to the executed-bundle JSON written by `dev execute-safe --out`.
    /// Phase 6 (deployment provenance) replays this log to reconstruct
    /// CREATE2 / TUPP deployments and verify each named v31 implementation
    /// was deployed from the expected init bytecode + constructor args (the
    /// immutables-aware check that Phase 5's runtime-hash comparison cannot
    /// do). Required.
    #[clap(long)]
    pub executed_bundles: PathBuf,

    /// Address of the Create2Factory used by the prepare scripts. The
    /// default matches the factory address used by the v31 stage env
    /// (`environments/stage/stage.yaml`).
    #[clap(long, default_value = "0x4e59b44847b379578588920cA78FbF26c0B4956C")]
    pub create2_factory: String,

    /// CREATE2 salt(s) used by the prepare scripts. Accept multiple via repeated
    /// `--create2-salt 0xAA --create2-salt 0xBB ...` or a comma-separated list
    /// `--create2-salt 0xAA,0xBB,0xCC`. Multiple salts are required when the
    /// prepare flow generates a fresh random salt per sub-script
    /// (`v31_upgrade_inner.rs` defaults to `H256::random()` per core / per-CTM /
    /// per-GW-prep when no `--create2-factory-salt` is pinned). PUVT accepts
    /// any CREATE2 factory tx whose salt matches one of the provided values.
    /// Required.
    #[clap(long, value_delimiter = ',', num_args = 1..)]
    pub create2_salt: Vec<String>,

    /// Expected ZK token asset ID (`keccak256(abi.encode(l1ChainId, 0x10004, zkTokenL1Address))`).
    /// When provided, `FixedForceDeploymentsData.zkTokenAssetId` is verified against this value
    /// instead of only checked for non-zero. Recommended for production verification runs.
    #[clap(long)]
    pub zk_token_asset_id: Option<FixedBytes<32>>,
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    logger::step("Verifying ecosystem upgrade artifacts");
    logger::info(format!("Ecosystem TOML: {}", args.ecosystem_toml.display()));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Gateway RPC URL: {}", args.gw_rpc_url));
    if let Some(contracts_commit) = &args.contracts_commit {
        logger::info(format!("Contracts commit: {contracts_commit}"));
    } else {
        logger::info("Contracts hashes: local repository AllContractsHashes.json");
    }
    logger::info(format!("Representative ZK chain ID: {}", args.era_chain_id));

    let artifact = EcosystemUpgradeArtifact::read(&args.ecosystem_toml)?;
    artifact_shape::verify(&artifact)?;

    // Read the executed-bundle log produced by `dev execute-safe --out`.
    // Multiple invocations of `dev execute-safe` against the same path
    // accumulate into a single file, so we only need to read one path here.
    logger::info(format!(
        "Executed bundle: {}",
        args.executed_bundles.display()
    ));
    let raw = std::fs::read_to_string(&args.executed_bundles).map_err(|err| {
        anyhow::anyhow!("failed to read {}: {err}", args.executed_bundles.display())
    })?;
    let executed_bundle: ExecutedBundle = serde_json::from_str(&raw).map_err(|err| {
        anyhow::anyhow!(
            "failed to parse executed-bundle JSON {}: {err}",
            args.executed_bundles.display()
        )
    })?;

    let create2_factory = alloy::primitives::Address::from_str(&args.create2_factory)
        .map_err(|err| anyhow::anyhow!("invalid --create2-factory address: {err}"))?;
    if args.create2_salt.is_empty() {
        anyhow::bail!("at least one --create2-salt is required");
    }
    let create2_salts: Vec<FixedBytes<32>> = args
        .create2_salt
        .iter()
        .map(|s| {
            FixedBytes::<32>::from_str(s)
                .map_err(|err| anyhow::anyhow!("invalid --create2-salt `{s}`: {err}"))
        })
        .collect::<anyhow::Result<_>>()?;

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        &artifact,
        &args.l1_rpc_url,
        &args.gw_rpc_url,
        args.contracts_commit.as_deref(),
        args.era_chain_id,
        &executed_bundle,
        create2_factory,
        create2_salts,
        args.zk_token_asset_id,
        &mut result,
    )
    .await;

    result.result = if result.errors == 0 && result.warnings == 0 {
        "upgrade calldata verified".to_string()
    } else if result.errors == 0 {
        format!(
            "upgrade calldata verified with {} warning(s)",
            result.warnings
        )
    } else {
        format!(
            "verification failed: {} error(s), {} warning(s)",
            result.errors, result.warnings
        )
    };
    logger::outro(format!("{}", result));
    verification_result?;
    result.ensure_success()
}
