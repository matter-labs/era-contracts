use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::Parser;
use ethers::{contract::BaseContract, types::Address};
use lazy_static::lazy_static;
use protocol_cli_common::{
    logger,
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
};
use protocol_cli_config::{
    forge_interface::{
        deploy_ecosystem::input::InitialDeploymentConfig,
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        script_params::{
            DEPLOY_CTM_SCRIPT_PARAMS,
            REGISTER_CTM_SCRIPT_PARAMS,
        },
    },
    traits::{ReadConfig, SaveConfig, get_or_create_config},
    CoreContractsConfig, WalletsConfig,
};
use protocol_cli_types::{L1Network, VMOption};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::abi::{IDEPLOYCTMABI_ABI, IREGISTERCTMABI_ABI};
use crate::admin_functions::{accept_admin, accept_owner, AdminScriptOutputInner, AdminScriptOutput};
use crate::utils::{forge::{fill_forge_private_key, WalletOwner}, runlog};

lazy_static! {
    static ref DEPLOY_CTM_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYCTMABI_ABI.clone());
}

lazy_static! {
    static ref REGISTER_CTM_FUNCTIONS: BaseContract =
        BaseContract::from(IREGISTERCTMABI_ABI.clone());
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmDeployArgs {
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    #[clap(long, default_value_t = false)]
    pub legacy_bridge: bool,

    #[clap(long, default_value = "ZKSyncOsVM")]
    pub vm_option: String,

    #[clap(long, default_value_t = true)]
    pub reuse_gov_and_admin: bool,

    #[clap(long)]
    pub contracts_path: PathBuf,
    #[clap(long)]
    pub wallets_path: PathBuf,

    #[clap(long)]
    pub foundry_contracts_path: PathBuf,

    #[clap(long, default_value_t = false)]
    pub plan: bool,
    #[clap(long)]
    pub out_plan: Option<PathBuf>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: CtmDeployArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = args.foundry_contracts_path.as_path();
    let vm_option = match args.vm_option.as_str() {
        "EraVM" => VMOption::EraVM,
        "ZKSyncOsVM" => VMOption::ZKSyncOsVM,
        _ => anyhow::bail!("Invalid VM option"),
    };

    let mut contracts: CoreContractsConfig = get_or_create_config(
        shell,
        args.contracts_path.clone(),
        CoreContractsConfig::default,
    )?;
    let wallets = WalletsConfig::read(shell, args.wallets_path.clone())?;

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    let initial_deployment_config = InitialDeploymentConfig::default();

    let reuse_gov_and_admin = args.reuse_gov_and_admin;

    // Deploy CTM
    logger::info("Deploying CTM...");
    let bridgehub_proxy_addr = contracts.bridgehub_proxy_addr();
    init_ctm(
        shell,
        foundry_scripts_path,
        &mut contracts,
        &wallets,
        &mut runner,
        args.forge_args.script.clone(),
        args.l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        &initial_deployment_config,
        args.legacy_bridge,
        vm_option,
        reuse_gov_and_admin,
    )
    .await?;
    contracts.save(shell, args.contracts_path.clone())?;

    logger::outro("CTM deployed");
    if let Ok(dir) = runlog::persist_runner_session(&runner, "ctm-deploy") {
        logger::info(format!("Runs saved to: {}", dir.display()));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn init_ctm(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: ForgeScriptArgs,
    l1_rpc_url: String,
    bridgehub_proxy_addr: Address,
    initial_deployment_config: &InitialDeploymentConfig,
    support_l2_legacy_shared_bridge_test: bool,
    vm_option: VMOption,
    reuse_gov_and_admin: bool,
) -> anyhow::Result<()> {
    deploy_new_ctm_and_accept_admin(
        shell,
        foundry_scripts_path,
        contracts,
        wallets,
        runner,
        &forge_args,
        l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        initial_deployment_config,
        support_l2_legacy_shared_bridge_test,
        vm_option,
        reuse_gov_and_admin,
        None,
        true,
    )
    .await?;

    logger::step("Registering CTM on Bridgehub...");
    register_ctm_on_existing_bh(
        shell,
        foundry_scripts_path,
        wallets,
        runner,
        &forge_args,
        l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        contracts.ctm(vm_option).state_transition_proxy_addr,
        None,
        true,
    )
    .await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn deploy_new_ctm_and_accept_admin(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    bridgehub_proxy_addr: Address,
    initial_deployment_config: &InitialDeploymentConfig,
    support_l2_legacy_shared_bridge_test: bool,
    vm_option: VMOption,
    reuse_gov_and_admin: bool,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<()> {
    logger::step("Deploying new CTM...");
    deploy_new_ctm(
        shell,
        foundry_scripts_path,
        contracts,
        wallets,
        runner,
        forge_args,
        l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        initial_deployment_config,
        support_l2_legacy_shared_bridge_test,
        vm_option,
        reuse_gov_and_admin,
        sender,
        broadcast,
    )
    .await?;

    logger::step("Accepting ownership of CTM...");
    // Accept owner and admin roles
    let ctm = contracts.ctm(vm_option);
    accept_owner(
        shell,
        runner,
        foundry_scripts_path,
        contracts.l1.governance_addr,
        &wallets.governor,
        ctm.state_transition_proxy_addr,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    accept_admin(
        shell,
        runner,
        foundry_scripts_path,
        contracts.l1.chain_admin_addr,
        &wallets.governor,
        ctm.state_transition_proxy_addr,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn deploy_new_ctm(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    bridgehub_proxy_addr: Address,
    initial_deployment_config: &InitialDeploymentConfig,
    support_l2_legacy_shared_bridge_test: bool,
    vm_option: VMOption,
    reuse_gov_and_admin: bool,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<()> {
    let deploy_config_path: PathBuf = DEPLOY_CTM_SCRIPT_PARAMS.input(&foundry_scripts_path);
    let l1_network = L1Network::Localhost;

    let deploy_config = DeployCTMConfig::new(
        wallets.governor.address,
        initial_deployment_config,
        false, // testnet_verifier - not used in zkstack_cli pattern
        l1_network,
        support_l2_legacy_shared_bridge_test,
        vm_option,
    );
    deploy_config.save(shell, deploy_config_path)?;

    let calldata = DEPLOY_CTM_FUNCTIONS
        .encode("runWithBridgehub", (bridgehub_proxy_addr, reuse_gov_and_admin))
        .unwrap();

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&DEPLOY_CTM_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_slow();

    if let Some(address) = sender {
        forge = forge.with_sender(address);
    } else {
        forge = fill_forge_private_key(
            forge,
            wallets.deployer.as_ref(),
            WalletOwner::Deployer,
        )?;
    }

    if broadcast {
        forge = forge.with_broadcast();
    }

    runner.run(shell, forge)?;

    let script_output = DeployCTMOutput::read(
        shell,
        DEPLOY_CTM_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    contracts.update_from_ctm_output(&script_output, vm_option);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn register_ctm_on_existing_bh(
    shell: &Shell,
    foundry_scripts_path: &Path,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    bridgehub_proxy_addr: Address,
    ctm_address: Address,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<AdminScriptOutput> {
    let calldata = REGISTER_CTM_FUNCTIONS
        .encode(
            "registerCTM",
            (bridgehub_proxy_addr, ctm_address, broadcast),
        )
        .unwrap();

    let mut forge = Forge::new(&foundry_scripts_path)
        .script(&REGISTER_CTM_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_slow();

    if let Some(address) = sender {
        forge = forge.with_sender(address);
    } else {
        forge = fill_forge_private_key(
            forge,
            Some(&wallets.governor),
            WalletOwner::Governor,
        )?;
    }

    if broadcast {
        forge = forge.with_broadcast();
    }
    runner.run(shell, forge)?;

    let script_output = AdminScriptOutputInner::read(
        shell,
        REGISTER_CTM_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    Ok(script_output.into())
}
