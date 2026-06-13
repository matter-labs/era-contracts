use std::path::PathBuf;

use alloy::primitives::{Address, FixedBytes};
use clap::Parser;

use crate::{
    common::{
        env_config::{default_protocol_ops_out_dir, EnvConfig},
        logger,
    },
    upgrade_verification::{
        verifiers::VerificationResult,
        versions::{
            v31::utils::{
                bytecode_verifier::BytecodeVerifier, network_verifier::NetworkVerifier,
                transactions_log,
            },
            v31_stage_patch::{self, StagePatchVerificationInput},
        },
    },
};

use super::verify_upgrade::VerifyUpgradeEnv;
const STAGE_PATCH_DEFAULT_CREATE2_FACTORY_SALT: &str =
    "0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5";

/// Verify the small v31 stage emergency patch.
///
/// This is intentionally much narrower than `verify-upgrade`: it checks only
/// the ValidatorTimelock restore deployment and emergency-board call.
#[derive(Debug, Clone, Parser)]
pub struct VerifyV31StagePatchArgs {
    /// Environment whose permanent-values define the CREATE2 factory.
    #[clap(long, value_enum)]
    pub env: VerifyUpgradeEnv,

    /// L1 RPC URL used to fetch CREATE2 deployment transactions.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Final EmergencyUpgradeBoard.executeEmergencyUpgrade(...) calldata for
    /// the ValidatorTimelock restore patch.
    #[clap(long)]
    pub execute_calldata: String,

    /// Optional era-contracts commit to load contract metadata from GitHub.
    /// If omitted, local AllContractsHashes.json is used.
    #[clap(long)]
    pub contracts_commit: Option<String>,

    /// Path to the append-only transactions.txt containing the CREATE2 deploy txs.
    ///
    /// Defaults to `<l1-contracts>/upgrade-envs/v0.31.0-interopB/output/<env>/transactions.txt`.
    #[clap(long)]
    pub transactions_log: Option<PathBuf>,
}

pub async fn run(args: VerifyV31StagePatchArgs) -> anyhow::Result<()> {
    anyhow::ensure!(
        args.env.is_stage(),
        "verify-v31-stage-patch is currently stage-specific; pass --env stage"
    );

    let env = args.env.as_str();
    let env_cfg = EnvConfig::load(env)?;
    let create2_factory = env_cfg.create2_factory().ok_or_else(|| {
        anyhow::anyhow!(
            "{} is missing `[permanent_contracts] create2_factory_addr`",
            env_cfg.permanent_values_path.display()
        )
    })?;
    let create2_factory = Address::from_slice(create2_factory.as_bytes());
    let bridgehub = Address::from_slice(env_cfg.bridgehub().as_bytes());
    let stage_patch_default_salt = STAGE_PATCH_DEFAULT_CREATE2_FACTORY_SALT
        .parse::<FixedBytes<32>>()
        .map_err(|err| anyhow::anyhow!("invalid stage patch default CREATE2 salt: {err}"))?;
    let expected_salts = vec![stage_patch_default_salt];

    let transactions_log_path = match args.transactions_log.clone() {
        Some(path) => path,
        None => default_protocol_ops_out_dir(env)?.join("transactions.txt"),
    };

    logger::step("Verifying v31 stage emergency patch");
    logger::info(format!("Env: {env}"));
    logger::info(format!(
        "Permanent values: {}",
        env_cfg.permanent_values_path.display()
    ));
    logger::info(format!(
        "Transactions log: {}",
        transactions_log_path.display()
    ));
    logger::info(format!("L1 RPC URL: {}", args.l1_rpc_url));
    logger::info(format!("CREATE2 factory: {create2_factory}"));
    logger::info(format!(
        "Allowed CREATE2 salts: {}",
        expected_salts
            .iter()
            .map(|salt| format!("{salt}"))
            .collect::<Vec<_>>()
            .join(", ")
    ));
    if let Some(contracts_commit) = &args.contracts_commit {
        logger::info(format!("Contracts commit: {contracts_commit}"));
    } else {
        logger::info("Contracts hashes: local repository AllContractsHashes.json");
    }

    let tx_hashes = transactions_log::read(&transactions_log_path)?;
    logger::info(format!(
        "Loaded {} transaction hash(es) from {}",
        tx_hashes.len(),
        transactions_log_path.display()
    ));

    let bytecode_verifier = match args.contracts_commit.as_deref() {
        Some(commit) => BytecodeVerifier::init_from_github(commit).await,
        None => BytecodeVerifier::init_from_local()?,
    };
    let mut network_verifier = NetworkVerifier::new_l1_only(args.l1_rpc_url).await?;
    let mut result = VerificationResult::default();

    network_verifier
        .populate_create2_from_transactions_log(
            &tx_hashes,
            &create2_factory,
            &bridgehub,
            &expected_salts,
            &bytecode_verifier,
            &mut result,
        )
        .await;
    result.report_ok(&format!(
        "Loaded {} CREATE2 deployments from transactions log",
        network_verifier.create2_known_bytecodes.len()
    ));

    v31_stage_patch::verify(
        StagePatchVerificationInput {
            execute_calldata: &args.execute_calldata,
            network_verifier: &network_verifier,
        },
        &mut result,
    )?;

    result.result = if result.errors == 0 && result.warnings == 0 {
        "v31 stage patch calldata verified".to_string()
    } else if result.errors == 0 {
        format!(
            "v31 stage patch calldata verified with {} warning(s)",
            result.warnings
        )
    } else {
        format!(
            "verification failed: {} error(s), {} warning(s)",
            result.errors, result.warnings
        )
    };

    logger::outro(format!("{}", result));
    result.ensure_success()
}
