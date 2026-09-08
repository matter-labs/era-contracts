use std::path::PathBuf;

use alloy::primitives::{keccak256, Address, FixedBytes};
use clap::{Parser, ValueEnum};

use crate::common::env_config::{default_protocol_ops_out_dir, EnvConfig, GovernanceKind};
use crate::{
    common::logger,
    upgrade_verification::{
        artifact_shape, artifacts::EcosystemUpgradeArtifact, verifiers::VerificationResult,
        versions::v31::utils::transactions_log,
    },
};

use super::zk_governance::GOV_SALT_SEED;

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

    /// Optional era-contracts commit to load contract metadata from GitHub.
    /// If omitted, the local checkout is the authority for AllContractsHashes.json
    /// and SystemConfig.json; verify that the checkout matches the reviewed commit.
    #[clap(long)]
    pub contracts_commit: Option<String>,

    /// zk-governance commit to load PUH / Guardians / SecurityCouncil / EUB
    /// bytecode metadata from GitHub.
    #[clap(long)]
    pub zk_governance_commit: String,

    /// Path to the append-only `transactions.txt` emitted by every prepare
    /// broadcast (see `dev execute-safe::append_transaction_hash`). Each
    /// non-blank line is a 0x-prefixed L1 tx hash. We fetch each tx
    /// via L1 RPC, filter successful CREATE2-factory deploys, identify the
    /// deployed contract via `AllContractsHashes.json`, and feed the
    /// `(addr → name, ctor_args)` map that `expect_create2_params` consumes.
    /// Stale entries (from older regens whose bytecode is no longer in
    /// AllContractsHashes) are silently skipped.
    ///
    /// Defaults to `<l1-contracts>/upgrade-envs/v0.33.0-atomic-interop/output/<env>/transactions.txt`
    #[clap(long)]
    pub transactions_log: Option<PathBuf>,

    /// Print the ABI-encoded `UpgradeProposal { calls, executor: 0x0, salt: 0x0 }`
    /// for each governance stage (0/1/2) so an operator can byte-compare against
    /// the on-chain submitted governance proposal bytes. When set, the rest of
    /// the verifier is skipped.
    #[clap(long)]
    pub display_upgrade_data: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum VerifyUpgradeEnv {
    Stage,
    Testnet,
    Mainnet,
}

impl VerifyUpgradeEnv {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stage => "stage",
            Self::Testnet => "testnet",
            Self::Mainnet => "mainnet",
        }
    }

    pub fn is_mainnet(self) -> bool {
        matches!(self, Self::Mainnet)
    }

    pub fn is_stage(self) -> bool {
        matches!(self, Self::Stage)
    }
}

pub async fn run(args: VerifyUpgradeArgs) -> anyhow::Result<()> {
    let env = args.env.as_str();
    let env_cfg = EnvConfig::load(env)?;
    let era_chain_id = env_cfg.era_chain_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing top-level `era_chain_id`",
            env_cfg.upgrade_input_path.display()
        )
    })?;
    let legacy_gateway_chain_id = env_cfg.legacy_gateway_chain_id().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing `[legacy_gateway] chain_id`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let legacy_gateway_chain_intervals = env_cfg.legacy_gateway_chain_intervals().to_vec();
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
    let create2_factory = env_cfg.create2_factory().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing `[permanent_contracts] create2_factory_addr`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let new_gateway = env_cfg.new_gateway().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing required `[new_gateway]` config for v31 verification",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let new_gateway_chain_id = new_gateway.chain_id;
    let new_gateway_representative_chain_id = new_gateway.ctm_representative_chain_id;

    // Collect every pinned CREATE2 salt declared in the env config — the Core
    // salt from `[contracts] create2_factory_salt` plus the per-CTM salts under
    // `[create2_factory_salts]`. PUVT hard-errors per deploy whose salt isn't
    // in this set.
    let mut expected_salts: Vec<FixedBytes<32>> = Vec::new();
    if let Some(core_salt) = env_cfg.create2_factory_salt_for_upgrade()? {
        expected_salts.push(core_salt);
    }
    for salt in env_cfg.create2_factory_salt_for_upgrade_per_ctm()?.values() {
        expected_salts.push(*salt);
    }
    if env_cfg.governance_kind() == GovernanceKind::Puh {
        // The PUH/Guardians/SecurityCouncil/EmergencyUpgradeBoard redeploy uses
        // a single shared salt (`keccak256(GOV_SALT_SEED)`) for all four — see
        // `puh_guardians::deploy_puh_guardians`. They have distinct init code,
        // so one salt is collision-free.
        expected_salts.push(keccak256(GOV_SALT_SEED));
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
    logger::info(format!(
        "V31 input: {}",
        env_cfg.upgrade_input_path.display()
    ));
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
    logger::info(format!(
        "zk-governance commit: {}",
        args.zk_governance_commit
    ));
    logger::info(format!("Representative ZK chain ID: {era_chain_id}"));
    logger::info(format!(
        "Legacy Gateway chain ID: {legacy_gateway_chain_id}"
    ));
    logger::info(format!("New Gateway chain ID: {new_gateway_chain_id}"));
    logger::info(format!(
        "New Gateway representative chain ID: {new_gateway_representative_chain_id}"
    ));
    logger::info(format!("L1 chain ID (expected): {l1_chain_id}"));
    logger::info(format!("CREATE2 factory: {create2_factory}"));
    logger::info(format!("ZK token asset ID: {zk_token_asset_id}"));

    let artifact = EcosystemUpgradeArtifact::read(&args.ecosystem_toml)?;
    artifact_shape::verify(&artifact)?;

    if args.display_upgrade_data {
        print_encoded_upgrade_data("Stage0", &artifact.governance_calls.stage0_calls);
        print_encoded_upgrade_data("Stage1", &artifact.governance_calls.stage1_calls);
        print_encoded_upgrade_data("Stage2", &artifact.governance_calls.stage2_calls);
        return Ok(());
    }

    let tx_hashes = transactions_log::read(&transactions_log_path)?;
    logger::info(format!(
        "Loaded {} transaction hash(es) from {}",
        tx_hashes.len(),
        transactions_log_path.display()
    ));

    let mut result = VerificationResult::default();

    let verification_result = crate::upgrade_verification::versions::v31::verify(
        args.env,
        &artifact,
        &args.l1_rpc_url,
        &args.gw_rpc_url,
        args.contracts_commit.as_deref(),
        args.zk_governance_commit.as_str(),
        era_chain_id,
        legacy_gateway_chain_id,
        &legacy_gateway_chain_intervals,
        new_gateway_chain_id,
        new_gateway_representative_chain_id,
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

fn print_encoded_upgrade_data(label: &str, stage_calls_hex: &str) {
    use crate::upgrade_verification::versions::v31::elements::call_list::{
        CallList, UpgradeProposal,
    };
    use alloy::sol_types::SolValue;

    let calls = CallList::parse(stage_calls_hex);
    let proposal = UpgradeProposal {
        calls: calls.elems,
        executor: Address::ZERO,
        salt: FixedBytes::<32>::ZERO,
    };
    println!(
        "{label} encoded upgrade data = 0x{}",
        alloy::hex::encode(proposal.abi_encode())
    );
}
