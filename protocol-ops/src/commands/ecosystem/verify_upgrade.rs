use std::path::PathBuf;

use alloy::primitives::{Address, FixedBytes};
use clap::{Parser, ValueEnum};

use crate::common::env_config::{default_protocol_ops_out_dir, EnvConfig};
use crate::{
    common::logger,
    upgrade_verification::{
        artifact_shape, artifacts::EcosystemUpgradeArtifact, verifiers::VerificationResult,
        versions::v31::utils::transactions_log,
    },
};

/// Verify prepared ecosystem upgrade artifacts.
///
/// This command is intentionally read-only. It consumes the TOML produced by
/// `ecosystem upgrade-prepare`, walks the append-only `transactions.txt`
/// emitted alongside, and performs validation locally without running forge
/// scripts or creating an anvil fork.
#[derive(Debug, Clone, Parser)]
pub struct VerifyUpgradeArgs {
    /// Environment whose permanent-values and v31 input TOMLs define verification constants.
    #[clap(long, value_enum)]
    pub env: VerifyUpgradeEnv,

    /// L1 RPC URL used by deployment provenance to fetch each CREATE2 deployment tx
    /// and by later phases for read-only on-chain checks.
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

    /// Path to the append-only `transactions.txt` emitted by every prepare
    /// broadcast (see `dev execute-safe::append_transaction_hash`). Each
    /// non-blank line is a 0x-prefixed L1 tx hash. We fetch each tx
    /// via L1 RPC, filter successful CREATE2-factory deploys, identify the
    /// deployed contract via `AllContractsHashes.json`, and feed the
    /// `(addr → name, ctor_args)` map that `expect_create2_params` consumes.
    /// Stale entries (from older regens whose bytecode is no longer in
    /// AllContractsHashes) are silently skipped.
    ///
    /// Defaults to `<l1-contracts>/upgrade-envs/v0.31.0-interopB/output/<env>/transactions.txt`
    #[clap(long)]
    pub transactions_log: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum VerifyUpgradeEnv {
    Stage,
    Testnet,
    Mainnet,
}

impl VerifyUpgradeEnv {
    fn as_str(self) -> &'static str {
        match self {
            Self::Stage => "stage",
            Self::Testnet => "testnet",
            Self::Mainnet => "mainnet",
        }
    }
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    let env = args.env.as_str();
    let env_cfg = EnvConfig::load(env)?;
    let era_chain_id = env_cfg.era_chain_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing top-level `era_chain_id`",
            env_cfg.v31_input_path.display()
        )
    })?;
    let legacy_gateway_chain_id = env_cfg.legacy_gateway_chain_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing `[legacy_gateway] chain_id`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let l1_chain_id = env_cfg.l1_chain_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing top-level `l1_chain_id`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let zk_token_asset_id = env_cfg.zk_token_asset_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing top-level `zk_token_asset_id`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let zk_token_asset_id = FixedBytes::<32>::from_slice(zk_token_asset_id.as_bytes());
    let create2_factory_eth = env_cfg.create2_factory().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing `[permanent_contracts] create2_factory_addr`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let create2_factory = Address::from_slice(create2_factory_eth.as_bytes());

    // Collect every pinned CREATE2 salt declared in the env config — the Core
    // salt from `[contracts] create2_factory_salt` plus the per-CTM salts under
    // `[create2_factory_salts]`. PUVT hard-errors per deploy whose salt isn't
    // in this set.
    let mut expected_salts: Vec<FixedBytes<32>> = Vec::new();
    if let Some(core_salt) = env_cfg.v31_create2_factory_salt()? {
        expected_salts.push(FixedBytes::<32>::from_slice(core_salt.as_bytes()));
    }
    for salt in env_cfg.v31_create2_factory_salt_per_ctm()?.values() {
        expected_salts.push(FixedBytes::<32>::from_slice(salt.as_bytes()));
    }

    let transactions_log_path = match args.transactions_log.clone() {
        Some(path) => path,
        None => default_protocol_ops_out_dir(env)?.join("transactions.txt"),
    };

    logger::step("Verifying ecosystem upgrade artifacts");
    logger::info(format!("Env: {env}"));
    logger::info(format!(
        "Permanent values: {}",
        env_cfg.permanent_values_path.display()
    ));
    logger::info(format!("V31 input: {}", env_cfg.v31_input_path.display()));
    logger::info(format!("Ecosystem TOML: {}", args.ecosystem_toml.display()));
    logger::info(format!(
        "Transactions log: {}",
        transactions_log_path.display()
    ));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("Gateway RPC URL: {}", args.gw_rpc_url));
    if let Some(contracts_commit) = &args.contracts_commit {
        logger::info(format!("Contracts commit: {contracts_commit}"));
    } else {
        logger::info("Contracts hashes: local repository AllContractsHashes.json");
    }
    logger::info(format!("Representative ZK chain ID: {era_chain_id}"));
    logger::info(format!(
        "Legacy Gateway chain ID: {legacy_gateway_chain_id}"
    ));
    logger::info(format!("L1 chain ID (expected): {l1_chain_id}"));
    logger::info(format!("CREATE2 factory: {create2_factory}"));
    logger::info(format!("ZK token asset ID: {zk_token_asset_id}"));

    let artifact = EcosystemUpgradeArtifact::read(&args.ecosystem_toml)?;
    artifact_shape::verify(&artifact)?;

    let tx_hashes = transactions_log::read(&transactions_log_path)?;
    logger::info(format!(
        "Loaded {} transaction hash(es) from {}",
        tx_hashes.len(),
        transactions_log_path.display()
    ));

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        &artifact,
        &args.l1_rpc_url,
        &args.gw_rpc_url,
        args.contracts_commit.as_deref(),
        era_chain_id,
        legacy_gateway_chain_id,
        l1_chain_id,
        &tx_hashes,
        create2_factory,
        &expected_salts,
        zk_token_asset_id,
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
