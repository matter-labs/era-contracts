use std::path::{Path, PathBuf};
use std::str::FromStr;

use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_cli_common::{
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
    logger,
};
use protocol_cli_config::{
    forge_interface::{
        deploy_ecosystem::{
            input::{DeployL1Config, InitialDeploymentConfig},
            output::DeployL1CoreContractsOutput,
        },
        script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::utils::paths;

/// Anvil/Hardhat first default account private key.
/// Mnemonic: "test test test test test test test test test test test junk"
const DEV_PRIVATE_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/// How the forge script authenticates transactions.
enum SenderAuth {
    /// Sign with a private key (forge --private-key)
    PrivateKey(H256),
    /// Unlocked account on the node (forge --sender, no key)
    Unlocked(Address),
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubDeployArgs {
    #[clap(long, help = "Owner address for the deployed contracts (default: sender)")]
    pub owner: Option<Address>,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, help = "Private key for the sender")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Sender address (unlocked account mode if no private key)")]
    pub sender: Option<Address>,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,

    // Dev options
    #[clap(long, help = "Use dev defaults", default_value_t = false, help_heading = "Dev options")]
    pub dev: bool,
    #[clap(long, help = "Enable support for legacy bridge testing", default_value_t = false, help_heading = "Dev options")]
    pub with_legacy_bridge: bool,
    #[clap(long, help = "Era chain ID", default_value_t = 270, help_heading = "Dev options")]
    pub era_chain_id: u64,
}

/// Resolves authentication and sender address from CLI args.
/// Priority: --private-key > --dev > --sender (unlocked) > error
fn resolve_sender(args: &HubDeployArgs) -> anyhow::Result<(SenderAuth, Address)> {
    if let Some(pk) = args.private_key {
        let wallet = LocalWallet::from_bytes(pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid private key: {}", e))?;
        if let Some(sender) = args.sender {
            if sender != wallet.address() {
                anyhow::bail!(
                    "Sender address does not match private key: got {:#x}, want {:#x}",
                    sender,
                    wallet.address()
                );
            }
        }
        Ok((SenderAuth::PrivateKey(pk), wallet.address()))
    } else if args.dev {
        let pk = H256::from_str(DEV_PRIVATE_KEY)?;
        let wallet = LocalWallet::from_bytes(pk.as_bytes()).unwrap();
        Ok((SenderAuth::PrivateKey(pk), wallet.address()))
    } else if let Some(sender) = args.sender {
        Ok((SenderAuth::Unlocked(sender), sender))
    } else {
        anyhow::bail!("Either --private-key, --dev, or --sender must be provided");
    }
}

pub async fn run(args: HubDeployArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path_buf = paths::path_from_root("l1-contracts");
    let foundry_scripts_path = foundry_scripts_path_buf.as_path();

    let (auth, sender) = resolve_sender(&args)?;
    let owner = args.owner.unwrap_or(sender);

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    let initial_deployment_config = InitialDeploymentConfig::default();

    logger::info("Deploying hub contracts...");
    let script_output = deploy_contracts(
        shell,
        foundry_scripts_path,
        &mut runner,
        &args.forge_args.script,
        args.l1_rpc_url.clone(),
        auth,
        owner,
        &initial_deployment_config,
        args.era_chain_id,
        args.with_legacy_bridge,
        true,
    )
    .await?;

    let plan = build_plan(&script_output, &runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    logger::outro("Hub contracts deployed");
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn deploy_contracts(
    shell: &Shell,
    foundry_scripts_path: &Path,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    auth: SenderAuth,
    owner: Address,
    initial_deployment_config: &InitialDeploymentConfig,
    era_chain_id: u64,
    support_l2_legacy_shared_bridge_test: bool,
    broadcast: bool,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    let deploy_config_path: PathBuf =
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.input(&foundry_scripts_path);

    let deploy_config = DeployL1Config::new(
        owner,
        initial_deployment_config,
        era_chain_id,
        support_l2_legacy_shared_bridge_test,
    );
    deploy_config.save(shell, deploy_config_path)?;

    let mut forge = Forge::new(&foundry_scripts_path)
        .script(
            &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url.to_string())
        .with_slow();

    match auth {
        SenderAuth::PrivateKey(pk) => {
            forge = forge.with_private_key(pk);
        }
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
        }
    }

    if broadcast {
        forge = forge.with_broadcast();
    }
    runner.run(shell, forge)?;

    let script_output = DeployL1CoreContractsOutput::read(
        shell,
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    Ok(script_output)
}

fn build_plan(output: &DeployL1CoreContractsOutput, runner: &ForgeRunner) -> serde_json::Value {
    let deployed = &output.deployed_addresses;

    // Collect transactions from runner
    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "hub-deploy",
        "artifacts": {
            "create2_factory_addr": format!("{:#x}", output.contracts.create2_factory_addr),
            "create2_factory_salt": format!("{:#x}", output.contracts.create2_factory_salt),
            "core_ecosystem_contracts": {
                "bridgehub_proxy_addr": format!("{:#x}", deployed.bridgehub.bridgehub_proxy_addr),
                "message_root_proxy_addr": format!("{:#x}", deployed.bridgehub.message_root_proxy_addr),
                "transparent_proxy_admin_addr": format!("{:#x}", deployed.transparent_proxy_admin_addr),
                "stm_deployment_tracker_proxy_addr": format!("{:#x}", deployed.bridgehub.ctm_deployment_tracker_proxy_addr),
                "native_token_vault_addr": format!("{:#x}", deployed.native_token_vault_addr),
                "chain_asset_handler_proxy_addr": format!("{:#x}", deployed.bridgehub.chain_asset_handler_proxy_addr),
            },
            "bridges": {
                "erc20": {
                    "l1_address": format!("{:#x}", deployed.bridges.erc20_bridge_proxy_addr),
                },
                "shared": {
                    "l1_address": format!("{:#x}", deployed.bridges.shared_bridge_proxy_addr),
                },
                "l1_nullifier_addr": format!("{:#x}", deployed.bridges.l1_nullifier_proxy_addr),
            },
            "l1": {
                "governance_addr": format!("{:#x}", deployed.governance_addr),
                "chain_admin_addr": format!("{:#x}", deployed.chain_admin),
                "access_control_restriction_addr": format!("{:#x}", deployed.access_control_restriction_addr),
            },
        },
        "transactions": transactions,
    })
}
