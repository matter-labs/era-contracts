use std::path::{Path, PathBuf};
use std::str::FromStr;

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use ethers::contract::BaseContract;
use ethers::types::Address;
use protocol_cli_common::{
    contracts::encode_ntv_asset_id,
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
    logger,
};
use protocol_cli_config::{
    forge_interface::{
        deploy_l2_contracts::{
            input::DeployL2ContractsInput,
            output::{
                ConsensusRegistryOutput, DefaultL2UpgradeOutput, InitializeBridgeOutput,
                Multicall3Output, TimestampAsserterOutput,
            },
        },
        register_chain::{
            input::{NewChainParams, RegisterChainL1Config},
            output::RegisterChainOutput,
        },
        script_params::{DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS, REGISTER_CHAIN_SCRIPT_PARAMS},
    },
    traits::{get_or_create_config, ReadConfig, SaveConfig},
    ContractsConfig, CoreContractsConfig, WalletsConfig,
};
use protocol_cli_types::{DAValidatorType, L1Network, L2ChainId, L2DACommitmentScheme, VMOption};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::admin_functions::{accept_admin, set_da_validator_pair, AdminScriptMode};
use crate::abi::{IREGISTERZKCHAINABI_ABI};
use crate::utils::{
    forge::{fill_forge_private_key, WalletOwner},
    paths, runlog,
};

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainInitArgs {
    #[clap(long, help = "Chain owner address")]
    pub owner: Option<String>,
    #[clap(
        long,
        help = "Commit operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub commit_operator: Option<String>,
    #[clap(
        long,
        help = "Prove operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub prove_operator: Option<String>,
    #[clap(
        long,
        help = "Execute operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub execute_operator: Option<String>,
    #[clap(
        long,
        help = "Token multiplier setter address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub token_multiplier_setter: Option<String>,

    #[clap(long, help = "Deployer address")]
    pub deployer: Option<String>,
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    #[clap(long, help = "Chain ID", default_value_t = 271)]
    pub chain_id: i64,
    #[clap(
        long,
        help = "Base token address",
        default_value = "0x0000000000000000000000000000000000000001"
    )]
    pub base_token_addr: String,
    #[clap(long, help = "Base token multiplier numerator", default_value_t = 1)]
    pub base_token_gas_price_multiplier_numerator: u64,
    #[clap(long, help = "Base token multiplier denominator", default_value_t = 1)]
    pub base_token_gas_price_multiplier_denominator: u64,
    #[clap(long, value_enum, help = "Data availability mode", default_value_t = DAValidatorType::Rollup)]
    pub da_mode: DAValidatorType,

    #[clap(long, default_value_t = false)]
    pub legacy_bridge: bool,

    #[clap(long)]
    pub ecosystem_contracts_path: PathBuf,
    #[clap(long)]
    pub chain_contracts_path: PathBuf,
    #[clap(long)]
    pub ecosystem_wallets_path: PathBuf,
    #[clap(long)]
    pub chain_wallets_path: PathBuf,

    #[clap(long, default_value_t = false)]
    pub plan: bool,
    #[clap(long)]
    pub out_plan: Option<PathBuf>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: ChainInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let genesis_path = paths::path_from_root("etc/genesis.yaml");
    let foundry_scripts_path_buf = paths::path_from_root("l1-contracts");
    let foundry_scripts_path = foundry_scripts_path_buf.as_path();

    // TODO: owner, deployer should be derived from wallets if not provided
    let ecosystem_contracts =
        CoreContractsConfig::read(shell, args.ecosystem_contracts_path.clone())?;
    // let mut chain_contracts = get_or_create_config(shell, args.chain_contracts_path.clone(), ContractsConfig::default)?;
    let ecosystem_wallets = WalletsConfig::read(shell, args.ecosystem_wallets_path.clone())?;
    let chain_wallets = WalletsConfig::read(shell, args.chain_wallets_path.clone())?;

    let owner = chain_wallets.clone().governor.address;
    let deployer = chain_wallets.clone().deployer.unwrap().address;
    let commit_operator = chain_wallets.clone().operator.address;
    let prove_operator = chain_wallets.clone().blob_operator.address;
    let execute_operator = if let Some(execute_operator) = args.execute_operator {
        Some(Address::from_str(&execute_operator).context("Invalid execute operator address")?)
    } else {
        None
    };
    let token_multiplier_setter =
        if let Some(token_multiplier_setter) = args.token_multiplier_setter {
            Some(
                Address::from_str(&token_multiplier_setter)
                    .context("Invalid token multiplier setter address")?,
            )
        } else {
            None
        };

    let vm_option = VMOption::ZKSyncOsVM;

    // Chain parameters
    let chain_params = NewChainParams {
        chain_id: L2ChainId::from(args.chain_id as u32),
        base_token_addr: Address::from_str(&args.base_token_addr)
            .context("Invalid base token address")?,
        base_token_gas_price_multiplier_numerator: args.base_token_gas_price_multiplier_numerator,
        base_token_gas_price_multiplier_denominator: args
            .base_token_gas_price_multiplier_denominator,
        owner: owner,
        commit_operator: commit_operator,
        prove_operator: prove_operator,
        execute_operator: execute_operator,
        token_multiplier_setter: token_multiplier_setter,
        da_mode: args.da_mode,
    };

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    logger::info("Initializing chain...");
    // Deploy L1 contracts
    init_chain(
        shell,
        foundry_scripts_path,
        &ecosystem_contracts,
        &ecosystem_wallets,
        &chain_wallets,
        args.chain_contracts_path.clone(),
        &chain_params,
        &mut runner,
        args.forge_args.script.clone(),
        args.l1_rpc_url.clone(),
        deployer,
        args.legacy_bridge,
        vm_option,
    )
    .await?;
    if let Ok(dir) = runlog::persist_runner_session(&runner, "chain-init") {
        logger::info(format!("Runs saved to: {}", dir.display()));
    }
    logger::outro("Chain initialized");
    Ok(())
}

/// Initializes chain contracts:
async fn init_chain(
    shell: &Shell,
    foundry_scripts_path: &Path,
    ecosystem_contracts: &CoreContractsConfig,
    ecosystem_wallets: &WalletsConfig,
    chain_wallets: &WalletsConfig,
    chain_contracts_path: PathBuf,
    chain_params: &NewChainParams,
    runner: &mut ForgeRunner,
    forge_args: ForgeScriptArgs,
    l1_rpc_url: String,
    deployer: Address,
    support_l2_legacy_shared_bridge_test: bool,
    vm_option: VMOption,
) -> anyhow::Result<()> {
    logger::step("Deploying chain contracts...");
    let mut chain_contracts = register_chain(
        shell,
        foundry_scripts_path,
        ecosystem_contracts,
        ecosystem_wallets,
        chain_wallets,
        chain_params,
        runner,
        &forge_args,
        l1_rpc_url.clone(),
        deployer,
        support_l2_legacy_shared_bridge_test,
        vm_option,
        None,
        true,
    )
    .await?;
    chain_contracts.save(shell, chain_contracts_path.clone())?;

    logger::step("Accepting ownership of chain contracts...");
    accept_admin(
        shell,
        runner,
        foundry_scripts_path,
        chain_contracts.l1.chain_admin_addr,
        &chain_wallets.governor,
        chain_contracts.l1.diamond_proxy_addr,
        &forge_args,
        l1_rpc_url.clone(),
    )
    .await?;

    logger::step("Setting DA validator pair...");
    let l1_da_validator_addr =
        get_l1_da_validator(ecosystem_contracts, chain_params.da_mode, vm_option)?;
    let commitment_scheme = match chain_params.da_mode {
        DAValidatorType::Rollup => {
            if vm_option.is_zksync_os() {
                L2DACommitmentScheme::BlobsZKSyncOS
            } else {
                L2DACommitmentScheme::BlobsAndPubdataKeccak256
            }
        }
        DAValidatorType::Avail | DAValidatorType::Eigen => L2DACommitmentScheme::PubdataKeccak256,
        DAValidatorType::NoDA => L2DACommitmentScheme::EmptyNoDA,
    };
    set_da_validator_pair(
        shell,
        runner,
        &forge_args,
        foundry_scripts_path,
        AdminScriptMode::Broadcast(chain_wallets.governor.clone()),
        chain_params.chain_id.as_u64(),
        ecosystem_contracts
            .core_ecosystem_contracts
            .bridgehub_proxy_addr,
        l1_da_validator_addr,
        commitment_scheme,
        l1_rpc_url.clone(),
    )
    .await?;

    if !vm_option.is_zksync_os() {
        logger::step("Deploying L2 contracts...");
        deploy_l2_contracts(
            shell,
            foundry_scripts_path,
            ecosystem_contracts,
            ecosystem_wallets,
            &mut chain_contracts,
            chain_wallets,
            chain_params,
            runner,
            &forge_args,
            l1_rpc_url.clone(),
            deployer,
            support_l2_legacy_shared_bridge_test,
            None,
            true,
        )
        .await?;
    }
    chain_contracts.save(shell, chain_contracts_path.clone())?;

    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn register_chain(
    shell: &Shell,
    foundry_scripts_path: &Path,
    ecosystem_contracts: &CoreContractsConfig,
    ecosystem_wallets: &WalletsConfig,
    chain_wallets: &WalletsConfig,
    chain_params: &NewChainParams,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    deployer: Address,
    support_l2_legacy_shared_bridge_test: bool,
    vm_option: VMOption,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<ContractsConfig> {
    let deploy_config_path = REGISTER_CHAIN_SCRIPT_PARAMS.input(&foundry_scripts_path);
    let deploy_config = RegisterChainL1Config::new(
        chain_params,
        ecosystem_contracts,
        support_l2_legacy_shared_bridge_test,
        vm_option,
    )?;
    deploy_config.save(shell, deploy_config_path)?;

    // Prepare calldata for the register chain script
    let register_chain_contract = BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
    let ctm = ecosystem_contracts.ctm(vm_option);
    let calldata = register_chain_contract
        .encode(
            "run",
            (
                ctm.state_transition_proxy_addr,
                chain_params.chain_id.as_u64(),
            ),
        )
        .with_context(|| {
            format!(
                "Failed to encode calldata for register_chain. CTM address: {:?}, Chain ID: {}",
                ctm.state_transition_proxy_addr,
                chain_params.chain_id.as_u64()
            )
        })?;    

    let mut forge = Forge::new(&foundry_scripts_path)
        .script(&REGISTER_CHAIN_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_calldata(&calldata)
        .with_slow();

    if let Some(address) = sender {
        forge = forge.with_sender(address);
    } else {
        forge = fill_forge_private_key(
            forge,
            Some(&ecosystem_wallets.governor),
            WalletOwner::Governor,
        )?;
    }

    if broadcast {
        forge = forge.with_broadcast();
    }

    runner.run(shell, forge)?;
    let register_chain_output = RegisterChainOutput::read(
        shell,
        REGISTER_CHAIN_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    let l1_network = L1Network::Localhost;
    let chain_contracts = ecosystem_contracts.chain_contracts_from_output(
        &register_chain_output,
        chain_params,
        vm_option,
        l1_network,
    );
    Ok(chain_contracts)
}

async fn deploy_l2_contracts(
    shell: &Shell,
    foundry_scripts_path: &Path,
    ecosystem_contracts: &CoreContractsConfig,
    ecosystem_wallets: &WalletsConfig,
    chain_contracts: &mut ContractsConfig,
    chain_wallets: &WalletsConfig,
    chain_params: &NewChainParams,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    deployer: Address,
    support_l2_legacy_shared_bridge_test: bool,
    sender: Option<String>,
    broadcast: bool,
) -> anyhow::Result<()> {
    let deploy_config_path = DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.input(&foundry_scripts_path);

    let deploy_config = DeployL2ContractsInput::new(
        chain_params,
        &chain_contracts,
        ecosystem_wallets.governor.address,
        L2ChainId::from(270),
    )?;
    deploy_config.save(shell, deploy_config_path)?;

    let mut forge = Forge::new(&foundry_scripts_path)
        .script(
            &DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url)
        .with_slow();

    if let Some(address) = sender {
        forge = forge.with_sender(address);
    } else {
        forge = fill_forge_private_key(
            forge,
            Some(&ecosystem_wallets.governor),
            WalletOwner::Governor,
        )?;
    }

    if broadcast {
        forge = forge.with_broadcast();
    }

    runner.run(shell, forge)?;

    let out_path = DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.output(&foundry_scripts_path);
    chain_contracts.set_l2_shared_bridge(&InitializeBridgeOutput::read(shell, &out_path)?)?;
    chain_contracts.set_default_l2_upgrade(&DefaultL2UpgradeOutput::read(shell, &out_path)?)?;
    chain_contracts.set_consensus_registry(&ConsensusRegistryOutput::read(shell, &out_path)?)?;
    chain_contracts.set_multicall3(&Multicall3Output::read(shell, &out_path)?)?;
    chain_contracts
        .set_timestamp_asserter_addr(&TimestampAsserterOutput::read(shell, &out_path)?)?;
    Ok(())
}

pub(crate) fn get_l1_da_validator(
    ecosystem_contracts: &CoreContractsConfig,
    da_mode: DAValidatorType,
    vm_option: VMOption,
) -> anyhow::Result<Address> {
    let ctm = ecosystem_contracts.ctm(vm_option);
    let l1_da_validator_contract = match da_mode {
        DAValidatorType::Rollup => {
            if vm_option.is_zksync_os() {
                ctm.blobs_zksync_os_l1_da_validator_addr.context("l1 blobs zksync os da validator")?
            } else {
                ctm.rollup_l1_da_validator_addr
            }
        }
        DAValidatorType::NoDA => ctm.no_da_validium_l1_validator_addr,
        DAValidatorType::Avail => ctm.avail_l1_da_validator_addr,
        DAValidatorType::Eigen => ctm.no_da_validium_l1_validator_addr,
    };
    Ok(l1_da_validator_contract)
}
