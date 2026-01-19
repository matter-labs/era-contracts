use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;
use ethers::{abi::parse_abi, contract::BaseContract, types::{Address, H256}};
use lazy_static::lazy_static;
use protocol_cli_common::{
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
    logger,
};
use protocol_cli_config::{
    forge_interface::{
        deploy_ecosystem::{
            input::{DeployL1Config, GenesisInput, InitialDeploymentConfig},
            output::DeployL1CoreContractsOutput,
        },
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        script_params::{
            DEPLOY_CTM_SCRIPT_PARAMS, DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
            REGISTER_CTM_SCRIPT_PARAMS,
        },
    },
    traits::{get_or_create_config, ReadConfig, SaveConfig},
    CoreContractsConfig, GenesisConfig, WalletsConfig,
};
use protocol_cli_types::{L1Network, VMOption};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::admin_functions::{
    accept_admin, accept_owner, AdminScriptOutput, AdminScriptOutputInner,
};
use crate::utils::{
    forge::{fill_forge_private_key, WalletOwner},
    paths, runlog,
};

lazy_static! {
    static ref DEPLOY_CTM_FUNCTIONS: BaseContract = BaseContract::from(
        parse_abi(&["function runWithBridgehub(address bridgehub, bool reuseGovAndAdmin) public",])
            .unwrap(),
    );
}

lazy_static! {
    static ref REGISTER_CTM_FUNCTIONS: BaseContract =
         BaseContract::from(parse_abi(&["function registerCTM(address bridgehub, address chainTypeManagerProxy, bool shouldSend) public",]).unwrap(),);
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemInitArgs {
    #[clap(long, help = "Address of the deployer")]
    pub deployer: Option<String>,
    #[clap(long, help = "Address of the ecosystem owner")]
    pub owner: Option<String>,

    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, help = "Salt for the deployment")]
    pub salt: Option<String>,
    #[clap(long, default_value_t = true)]
    pub with_testnet_verifier: bool,
    #[clap(long, default_value_t = false)]
    pub with_legacy_bridge: bool,

    #[clap(long)]
    pub contracts_path: PathBuf,
    #[clap(long)]
    pub wallets_path: PathBuf,

    #[clap(long, default_value_t = false)]
    pub plan: bool,
    #[clap(long)]
    pub out_plan: Option<PathBuf>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: EcosystemInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let genesis_path = paths::path_from_root("etc/genesis.yaml");
    let foundry_scripts_path_buf = paths::path_from_root("l1-contracts");
    let foundry_scripts_path = foundry_scripts_path_buf.as_path();
    let vm_option = VMOption::ZKSyncOsVM;
    let salt = args.salt.unwrap_or_else(|| format!("{:#x}", H256::random()));

    let mut contracts: CoreContractsConfig = get_or_create_config(
        shell,
        args.contracts_path.clone(),
        CoreContractsConfig::default,
    )?;
    let wallets = WalletsConfig::read(shell, args.wallets_path.clone())?;
    let owner = wallets.clone().governor.address;
    let deployer = wallets.clone().deployer.unwrap().address;
    // TODO: owner, deployer should be derived from wallets if not provided

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    let initial_deployment_config = InitialDeploymentConfig::default();
    let genesis_config = GenesisConfig::read(shell, &genesis_path).await?;
    let genesis_input = GenesisInput::new(&genesis_config, vm_option)?;

    // TODO: make this configurable
    let reuse_gov_and_admin = true;

    logger::info("Initializing ecosystem...");
    // Deploy core contracts
    init_core_contracts(
        shell,
        foundry_scripts_path,
        &mut contracts,
        &wallets,
        &mut runner,
        args.forge_args.script.clone(),
        args.l1_rpc_url.clone(),
        owner,
        deployer,
        salt.clone(),
        args.with_testnet_verifier,
        args.with_legacy_bridge,
        &initial_deployment_config,
        &genesis_input,
        vm_option,
    )
    .await?;
    contracts.save(shell, args.contracts_path.clone())?;

    // Deploy CTM
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
        owner,
        deployer,
        salt,
        args.with_testnet_verifier,
        args.with_legacy_bridge,
        &initial_deployment_config,
        &genesis_input,
        vm_option,
        reuse_gov_and_admin,
    )
    .await?;
    contracts.save(shell, args.contracts_path.clone())?;

    logger::outro("Ecosystem initialized");
    if let Ok(dir) = runlog::persist_runner_session(&runner, "ecosystem-init") {
        logger::info(format!("Runs saved to: {}", dir.display()));
    }
    Ok(())
}

/// Initializes ecosystem core contracts:
/// * Deploys core contracts
/// * Accepts owner and admin roles
async fn init_core_contracts(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: ForgeScriptArgs,
    l1_rpc_url: String,
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
    vm_option: VMOption,
) -> anyhow::Result<()> {
    logger::step("Deploying core contracts...");
    deploy_core_contracts(
        shell,
        foundry_scripts_path,
        contracts,
        &wallets,
        runner,
        &forge_args,
        l1_rpc_url.clone(),
        owner,
        deployer,
        salt,
        with_testnet_verifier,
        with_legacy_bridge,
        &initial_deployment_config,
        &genesis_input,
        vm_option,
        None,
        true,
    )
    .await?;

    logger::step("Accepting ownership of core contracts...");
    accept_owner(
        shell,
        runner,
        foundry_scripts_path,
        contracts.l1.governance_addr,
        &wallets.governor,
        contracts.core_ecosystem_contracts.bridgehub_proxy_addr,
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
        contracts.core_ecosystem_contracts.bridgehub_proxy_addr,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    // Note, that there is no admin in L1 asset router, so we do not
    // need to accept it
    accept_owner(
        shell,
        runner,
        foundry_scripts_path,
        contracts.l1.governance_addr,
        &wallets.governor,
        contracts.bridges.shared.l1_address,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    accept_owner(
        shell,
        runner,
        foundry_scripts_path,
        contracts.l1.governance_addr,
        &wallets.governor,
        contracts
            .core_ecosystem_contracts
            .stm_deployment_tracker_proxy_addr
            .context("stm_deployment_tracker_proxy_addr")?,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn deploy_core_contracts(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
    vm_option: VMOption,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<()> {
    let deploy_config_path: PathBuf =
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.input(&foundry_scripts_path);

    let era_chain_id = 270;
    let l1_network = L1Network::Localhost;

    let deploy_config = DeployL1Config::new(
        &genesis_input,
        &initial_deployment_config,
        owner,
        era_chain_id,
        with_testnet_verifier,
        l1_network,
        with_legacy_bridge,
        vm_option,
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

    if let Some(address) = sender {
        forge = forge.with_sender(address);
    } else {
        forge = fill_forge_private_key(forge, wallets.deployer.as_ref(), WalletOwner::Deployer)?;
    }

    if broadcast {
        forge = forge.with_broadcast();
    }
    runner.run(shell, forge)?;

    let script_output = DeployL1CoreContractsOutput::read(
        shell,
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    contracts.update_from_l1_output(&script_output);
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
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
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
        owner,
        deployer,
        salt.clone(),
        with_testnet_verifier,
        with_legacy_bridge,
        initial_deployment_config,
        genesis_input,
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
        contracts,
        wallets,
        runner,
        &forge_args,
        l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        contracts.ctm(vm_option).state_transition_proxy_addr,
        owner,
        deployer,
        salt.clone(),
        with_testnet_verifier,
        with_legacy_bridge,
        initial_deployment_config,
        genesis_input,
        vm_option,
        reuse_gov_and_admin,
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
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
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
        &wallets,
        runner,
        forge_args,
        l1_rpc_url.clone(),
        bridgehub_proxy_addr,
        owner,
        deployer,
        salt,
        with_testnet_verifier,
        with_legacy_bridge,
        initial_deployment_config,
        genesis_input,
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
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
    vm_option: VMOption,
    reuse_gov_and_admin: bool,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<()> {
    let deploy_config_path: PathBuf = DEPLOY_CTM_SCRIPT_PARAMS.input(&foundry_scripts_path);
    let era_chain_id = 270;
    let l1_network = L1Network::Localhost;

    let deploy_config = DeployCTMConfig::new(
        owner,
        &initial_deployment_config,
        with_testnet_verifier,
        l1_network,
        with_legacy_bridge,
        vm_option,
    );
    deploy_config.save(shell, deploy_config_path)?;

    let calldata = DEPLOY_CTM_FUNCTIONS
        .encode(
            "runWithBridgehub",
            (bridgehub_proxy_addr, reuse_gov_and_admin),
        )
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
        forge = fill_forge_private_key(forge, wallets.deployer.as_ref(), WalletOwner::Deployer)?;
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
    contracts: &mut CoreContractsConfig,
    wallets: &WalletsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    bridgehub_proxy_addr: Address,
    ctm_address: Address,
    owner: Address,
    deployer: Address,
    salt: String,
    with_testnet_verifier: bool,
    with_legacy_bridge: bool,
    initial_deployment_config: &InitialDeploymentConfig,
    genesis_input: &GenesisInput,
    vm_option: VMOption,
    reuse_gov_and_admin: bool,
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
        forge = fill_forge_private_key(forge, Some(&wallets.governor), WalletOwner::Governor)?;
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
