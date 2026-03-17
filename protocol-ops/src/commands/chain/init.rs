use std::path::{Path, PathBuf};

use clap::Parser;
use ethers::{
    contract::BaseContract,
    middleware::Middleware,
    types::{Address, H256, U256},
    utils::hex,
};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use tokio::task::block_in_place;
use xshell::Shell;

use crate::abi::{
    IDEPLOYL2CONTRACTSABI_ABI, IDEPLOYPAYMASTERABI_ABI, IENABLEEVMEMULATORABI_ABI,
    IREGISTERONALLCHAINSABI_ABI, IREGISTERZKCHAINABI_ABI, ISETUPLEGACYBRIDGEABI_ABI,
};
use crate::admin_functions::{
    accept_admin, make_permanent_rollup, set_da_validator_pair, unpause_deposits, AdminScriptMode,
};
use crate::commands::output::CommandEnvelope;
use crate::common::{
    ethereum::get_ethers_provider,
    forge::{
        resolve_execution, resolve_owner_auth, resolve_secondary_auth, ExecutionMode, Forge,
        ForgeArgs, ForgeContext, ForgeRunner, ForgeScriptArgs, SenderAuth,
    },
    logger,
    traits::{FileConfigTrait, ReadConfig, SaveConfig},
};
use crate::config::{
    forge_interface::{
        deploy_l2_contracts::output::{
            ConsensusRegistryOutput, DefaultL2UpgradeOutput, Multicall3Output,
            TimestampAsserterOutput,
        },
        permanent_values::PermanentValuesConfig,
        register_chain::{
            input::{NewChainParams, RegisterChainL1Config},
            output::RegisterChainOutput,
        },
        script_params::{
            DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS, DEPLOY_PAYMASTER_SCRIPT_PARAMS,
            ENABLE_EVM_EMULATOR_PARAMS, REGISTER_CHAIN_SCRIPT_PARAMS,
            REGISTER_ON_ALL_CHAINS_SCRIPT_PARAMS, SETUP_LEGACY_BRIDGE,
        },
    }
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, VMOption};
use crate::common::paths;

lazy_static! {
    static ref REGISTER_CHAIN_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
    static ref DEPLOY_L2_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYL2CONTRACTSABI_ABI.clone());
    static ref DEPLOY_PAYMASTER_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYPAYMASTERABI_ABI.clone());
    static ref REGISTER_ON_ALL_CHAINS_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERONALLCHAINSABI_ABI.clone());
    static ref ENABLE_EVM_EMULATOR_FUNCTIONS: BaseContract = BaseContract::from(IENABLEEVMEMULATORABI_ABI.clone());
    static ref SETUP_LEGACY_BRIDGE_FUNCTIONS: BaseContract = BaseContract::from(ISETUPLEGACYBRIDGEABI_ABI.clone());
}

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainInitArgs {
    // Input
    /// CTM (Chain Type Manager) proxy address
    #[clap(long, help_heading = "Input")]
    pub ctm_proxy: Address,
    /// L1 DA validator address
    #[clap(long, help_heading = "Input")]
    pub l1_da_validator: Address,
    /// Chain ID
    #[clap(long, help_heading = "Input")]
    pub chain_id: u64,
    /// Commit operator address
    #[clap(long, help_heading = "Input")]
    pub commit_operator: Address,
    /// Prove operator address
    #[clap(long, help_heading = "Input")]
    pub prove_operator: Address,
    /// Execute operator address
    #[clap(long, help_heading = "Input")]
    pub execute_operator: Option<Address>,
    /// VM type: zksyncos or eravm
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM, help_heading = "Input")]
    pub vm_type: VMOption,

    // Signers
    /// Sender address
    #[clap(long, help_heading = "Signers")]
    pub sender: Option<Address>,
    /// Owner address for the chain (default: sender)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    // Auth
    /// Sender private key
    #[clap(long, visible_alias = "pk", help_heading = "Auth")]
    pub private_key: Option<H256>,
    /// Owner private key
    #[clap(long, visible_alias = "owner-pk", help_heading = "Auth")]
    pub owner_private_key: Option<H256>,
    /// Bridgehub admin private key
    #[clap(long, visible_alias = "bridgehub-admin-pk", help_heading = "Auth")]
    pub bridgehub_admin_private_key: Option<H256>,

    // Execution
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545", help_heading = "Execution")]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,

    // Output
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

    // Advanced input
    /// Token multiplier setter address
    #[clap(long, default_value = "0x0000000000000000000000000000000000000000", help_heading = "Advanced input")]
    pub token_multiplier_setter: Option<Address>,
    /// Base token address (default: ETH = 0x0...01)
    #[clap(long, default_value = "0x0000000000000000000000000000000000000001", help_heading = "Advanced input")]
    pub base_token_addr: Address,
    /// Base token price ratio relative to ETH (numerator/denominator)
    /// e.g. "4000/1" means: 1 ETH = 4000 base tokens
    #[clap(long, default_value = "1/1", help_heading = "Advanced input")]
    pub base_token_price_ratio: String,
    /// Data availability mode
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup, help_heading = "Advanced input")]
    pub da_mode: DAValidatorType,
    /// Governance address (for deploy_l2_contracts)
    #[clap(long, help_heading = "Advanced input")]
    pub governance_addr: Option<Address>,
    /// Keep deposits paused after init
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub pause_deposits: bool,
    /// Enable EVM emulator on the chain
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub evm_emulator: bool,
    /// Deploy testnet paymaster contract
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub deploy_paymaster: bool,
    /// Make the chain a permanent rollup (irreversible)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub make_permanent_rollup: bool,
    /// Skip L2 deployments via priority transactions
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub skip_priority_txs: bool,
    /// Enable support for legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// CREATE2 factory address
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_addr: Option<Address>,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: ChainInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (price_ratio_num, price_ratio_den) = parse_ratio(&args.base_token_price_ratio)?;

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);
    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));

    let owner_auth = resolve_owner_auth(
        owner, args.owner_private_key, sender, &sender_auth, is_simulation,
    )?;

    let bridgehub_admin_auth = resolve_secondary_auth(
        args.bridgehub_admin_private_key,
        "Bridgehub admin (for chain registration)",
        &sender_auth,
    )?;

    if is_simulation {
        logger::info(format!("Simulation mode: forking {} via anvil", args.l1_rpc_url));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);

    // Derive bridgehub address from CTM proxy
    logger::info(format!("Querying bridgehub from CTM proxy {:#x}...", args.ctm_proxy));
    let bridgehub = query_bridgehub(effective_rpc, args.ctm_proxy)?;
    logger::info(format!("Bridgehub: {:#x}", bridgehub));

    let mut runner = ForgeRunner::new();

    // Build chain params
    let chain_params = NewChainParams {
        chain_id: L2ChainId::from(args.chain_id as u32),
        base_token_addr: args.base_token_addr,
        base_token_gas_price_multiplier_numerator: price_ratio_num,
        base_token_gas_price_multiplier_denominator: price_ratio_den,
        owner,
        commit_operator: args.commit_operator,
        prove_operator: args.prove_operator,
        _execute_operator: args.execute_operator,
        _token_multiplier_setter: args.token_multiplier_setter,
        da_mode: args.da_mode,
    };

    let init_input = ChainInitInput {
        ctm_proxy: args.ctm_proxy,
        l1_da_validator: args.l1_da_validator,
        chain_params: chain_params.clone(),
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    // Step 1: Register chain (as bridgehub admin)
    logger::info(format!("Initializing chain {} ...", args.chain_id));
    logger::info(format!("Owner: {:#x}", owner));
    logger::info(format!("CTM proxy: {:#x}", args.ctm_proxy));

    let register_output = {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &bridgehub_admin_auth,
        };
        register_chain(&mut ctx, &init_input)?
    };

    let diamond_proxy = register_output.diamond_proxy_addr;
    let chain_admin = register_output.chain_admin_addr;
    let mut full_output = FullChainInitOutput::from_register(&register_output);
    logger::info("Chain registered.");
    logger::info(format!("  Diamond proxy: {:#x}", diamond_proxy));
    logger::info(format!("  ChainAdmin:    {:#x}", chain_admin));

    // Step 2: Accept admin of chain (as owner)
    logger::info("Accepting admin of chain...");
    let owner_wallet = owner_auth.to_wallet()?;
    accept_admin(
        shell,
        &mut runner,
        foundry_scripts_path.as_path(),
        chain_admin,
        &owner_wallet,
        diamond_proxy,
        &args.forge_args.script,
        effective_rpc.to_string(),
    )
    .await?;

    // Step 3: Unpause deposits (unless pause_deposits is set, as owner)
    if !args.pause_deposits {
        logger::info("Unpausing deposits...");
        unpause_deposits(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            AdminScriptMode::Broadcast(owner_wallet.clone()),
            args.chain_id,
            bridgehub,
            effective_rpc.to_string(),
        )
        .await?;
    }

    // Step 4: Set DA validator pair (as owner)
    logger::info("Setting DA validator pair...");
    let commitment_scheme = match args.da_mode {
        DAValidatorType::Rollup => match args.vm_type {
            VMOption::EraVM => L2DACommitmentScheme::BlobsAndPubdataKeccak256,
            VMOption::ZKSyncOsVM => L2DACommitmentScheme::BlobsZKSyncOS,
        },
        DAValidatorType::Avail | DAValidatorType::Eigen => L2DACommitmentScheme::PubdataKeccak256,
        DAValidatorType::NoDA => L2DACommitmentScheme::EmptyNoDA,
    };

    set_da_validator_pair(
        shell,
        &mut runner,
        &args.forge_args.script,
        foundry_scripts_path.as_path(),
        AdminScriptMode::Broadcast(owner_wallet.clone()),
        args.chain_id,
        bridgehub,
        args.l1_da_validator,
        commitment_scheme,
        effective_rpc.to_string(),
    )
    .await?;

    // Step 5: Enable EVM emulator (if requested, as owner)
    if args.evm_emulator {
        logger::info("Enabling EVM emulator...");
        enable_evm_emulator_step(
            shell, &mut runner, &args.forge_args.script, foundry_scripts_path.as_path(),
            &owner_auth, chain_admin, diamond_proxy, effective_rpc,
        )?;
    }

    // Step 6: Deploy L2 contracts (if not skipping priority txs)
    if !args.skip_priority_txs {
        let governance = args.governance_addr.unwrap_or(owner);

        logger::info("Deploying L2 contracts...");
        let l2_output = deploy_l2_contracts_step(
            shell, &mut runner, &args.forge_args.script, foundry_scripts_path.as_path(),
            &sender_auth, bridgehub, args.chain_id, governance, owner, args.da_mode,
            args.with_legacy_bridge, effective_rpc,
        )?;
        full_output.l2_default_upgrader = Some(l2_output.l2_default_upgrader);
        full_output.consensus_registry_proxy = Some(l2_output.consensus_registry_proxy);
        full_output.multicall3 = Some(l2_output.multicall3);
        full_output.timestamp_asserter = Some(l2_output.timestamp_asserter);

        // Step 7: Deploy paymaster (if requested)
        if args.deploy_paymaster {
            logger::info("Deploying paymaster...");
            let paymaster_addr = deploy_paymaster_step(
                shell, &mut runner, &args.forge_args.script, foundry_scripts_path.as_path(),
                &sender_auth, bridgehub, args.chain_id, effective_rpc,
            )?;
            full_output.paymaster_addr = Some(paymaster_addr);
            logger::info(format!("Paymaster deployed at: {:#x}", paymaster_addr));
        }

        // Step 8: Register on all chains
        logger::info("Registering chain on all other chains...");
        register_on_all_chains_step(
            shell, &mut runner, &args.forge_args.script, foundry_scripts_path.as_path(),
            &sender_auth, bridgehub, args.chain_id, effective_rpc,
        )?;
    }

    // Step 9: Make permanent rollup (if requested, as owner)
    if args.make_permanent_rollup {
        logger::info("Making chain a permanent rollup...");
        make_permanent_rollup(
            shell, &mut runner, foundry_scripts_path.as_path(), chain_admin,
            &owner_wallet, diamond_proxy, &args.forge_args.script, effective_rpc.to_string(),
        )
        .await?;
    }

    // Step 10: Setup legacy bridge (if requested)
    if args.with_legacy_bridge && !args.skip_priority_txs {
        logger::info("Setting up legacy bridge...");
        setup_legacy_bridge_step(
            shell, &mut runner, &args.forge_args.script, foundry_scripts_path.as_path(),
            &sender_auth, bridgehub, args.chain_id, effective_rpc,
        )?;
    }

    if let Some(out_path) = &args.out {
        let input_echo = ChainInitInputEcho {
            chain_id: init_input.chain_params.chain_id.as_u64(),
            ctm_proxy: init_input.ctm_proxy,
            bridgehub,
            l1_da_validator: init_input.l1_da_validator,
            owner: init_input.chain_params.owner,
            base_token_addr: init_input.chain_params.base_token_addr,
            da_mode: init_input.chain_params.da_mode,
            vm_type: args.vm_type,
            simulate: args.simulate,
        };
        let output_data = ChainInitOutputData::from_full_output(&full_output);
        let envelope = CommandEnvelope::new("chain.init", input_echo, output_data, &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!(
            "Chain init simulation complete — DiamondProxy: {:#x}, ChainAdmin: {:#x}",
            diamond_proxy, chain_admin
        ));
    } else {
        logger::outro(format!(
            "DiamondProxy deployed at: {:#x}, ChainAdmin deployed at: {:#x}",
            diamond_proxy, chain_admin
        ));
    }

    drop(execution_mode);
    Ok(())
}

// ── Library functions ───────────────────────────────────────────────────────

/// Register a chain on the CTM.
pub fn register_chain(
    ctx: &mut ForgeContext,
    input: &ChainInitInput,
) -> anyhow::Result<RegisterChainOutput> {
    let salt = input.create2_factory_salt.unwrap_or(H256::zero());
    let permanent_values = PermanentValuesConfig::new(input.create2_factory_addr, salt);
    permanent_values.save(ctx.shell, PermanentValuesConfig::path(ctx.foundry_scripts_path))?;

    let deploy_config = RegisterChainL1Config::new(
        &input.chain_params,
        input.create2_factory_addr.unwrap_or(Address::zero()),
        input.create2_factory_salt,
        input.with_legacy_bridge,
    )?;

    let input_path = REGISTER_CHAIN_SCRIPT_PARAMS.input(ctx.foundry_scripts_path);
    deploy_config.save(ctx.shell, input_path)?;

    let calldata = REGISTER_CHAIN_FUNCTIONS
        .encode("run", (input.ctm_proxy, input.chain_params.chain_id.as_u64()))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(&REGISTER_CHAIN_SCRIPT_PARAMS.script(), ctx.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(ctx.l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match ctx.auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    logger::info("Registering chain on CTM...");
    ctx.runner.run(ctx.shell, forge)?;

    let output_path = REGISTER_CHAIN_SCRIPT_PARAMS.output(ctx.foundry_scripts_path);
    RegisterChainOutput::read(ctx.shell, output_path)
}

/// Parse a ratio string like "4000/1" into (numerator, denominator).
fn parse_ratio(s: &str) -> anyhow::Result<(u64, u64)> {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() != 2 {
        anyhow::bail!("Invalid ratio format '{}'. Expected 'numerator/denominator' (e.g. '4000/1')", s);
    }
    let num: u64 = parts[0].trim().parse()
        .map_err(|_| anyhow::anyhow!("Invalid numerator '{}' in ratio '{}'", parts[0].trim(), s))?;
    let den: u64 = parts[1].trim().parse()
        .map_err(|_| anyhow::anyhow!("Invalid denominator '{}' in ratio '{}'", parts[1].trim(), s))?;
    if den == 0 {
        anyhow::bail!("Denominator cannot be zero in ratio '{}'", s);
    }
    Ok((num, den))
}

/// Query the bridgehub address from a CTM proxy contract via `BRIDGE_HUB()`.
fn query_bridgehub(rpc_url: &str, ctm_proxy: Address) -> anyhow::Result<Address> {
    let provider = get_ethers_provider(rpc_url)?;
    let calldata = ethers::types::Bytes::from(hex::decode("5d4edca7").unwrap());
    let tx: ethers::types::transaction::eip2718::TypedTransaction =
        ethers::types::TransactionRequest::new()
            .to(ctm_proxy)
            .data(calldata)
            .into();
    let fut = provider.call(&tx, None);
    let result = if let Ok(handle) = tokio::runtime::Handle::try_current() {
        block_in_place(|| handle.block_on(fut))?
    } else {
        tokio::runtime::Runtime::new()
            .map_err(|e| anyhow::anyhow!("Failed to create Tokio runtime: {}", e))?
            .block_on(fut)?
    };
    if result.len() < 32 {
        anyhow::bail!("Invalid response from BRIDGE_HUB() call on CTM proxy {:#x}", ctm_proxy);
    }
    Ok(Address::from_slice(&result[12..32]))
}

// ── Step helpers ────────────────────────────────────────────────────────────

fn enable_evm_emulator_step(
    shell: &Shell, runner: &mut ForgeRunner, forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path, auth: &SenderAuth, chain_admin: Address,
    diamond_proxy: Address, l1_rpc_url: &str,
) -> anyhow::Result<()> {
    let calldata = ENABLE_EVM_EMULATOR_FUNCTIONS
        .encode("chainAllowEvmEmulation", (chain_admin, diamond_proxy))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&ENABLE_EVM_EMULATOR_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_broadcast();

    match auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    runner.run(shell, forge)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn deploy_l2_contracts_step(
    shell: &Shell, runner: &mut ForgeRunner, forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path, auth: &SenderAuth, bridgehub: Address, chain_id: u64,
    governance: Address, consensus_registry_owner: Address, da_mode: DAValidatorType,
    with_legacy_bridge: bool, l1_rpc_url: &str,
) -> anyhow::Result<FullL2DeployOutput> {
    let function_name = if with_legacy_bridge { "runWithLegacyBridge" } else { "run" };
    let calldata = DEPLOY_L2_FUNCTIONS
        .encode(function_name, (
            bridgehub, U256::from(chain_id), governance, consensus_registry_owner,
            U256::from(da_mode.to_u8()),
        ))
        .map_err(|e| anyhow::anyhow!("Failed to encode deploy_l2 calldata: {}", e))?;

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    runner.run(shell, forge)?;

    let output_path = DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.output(foundry_scripts_path);
    let upgrader_output = DefaultL2UpgradeOutput::read(shell, &output_path)?;
    let consensus_output = ConsensusRegistryOutput::read(shell, &output_path)?;
    let multicall3_output = Multicall3Output::read(shell, &output_path)?;
    let timestamp_output = TimestampAsserterOutput::read(shell, &output_path)?;

    Ok(FullL2DeployOutput {
        l2_default_upgrader: upgrader_output.l2_default_upgrader,
        consensus_registry_proxy: consensus_output.consensus_registry_proxy,
        multicall3: multicall3_output.multicall3,
        timestamp_asserter: timestamp_output.timestamp_asserter,
    })
}

fn deploy_paymaster_step(
    shell: &Shell, runner: &mut ForgeRunner, forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path, auth: &SenderAuth, bridgehub: Address, chain_id: u64,
    l1_rpc_url: &str,
) -> anyhow::Result<Address> {
    let calldata = DEPLOY_PAYMASTER_FUNCTIONS
        .encode("run", (bridgehub, U256::from(chain_id)))
        .map_err(|e| anyhow::anyhow!("Failed to encode deploy_paymaster calldata: {}", e))?;

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&DEPLOY_PAYMASTER_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    runner.run(shell, forge)?;

    let output_path = DEPLOY_PAYMASTER_SCRIPT_PARAMS.output(foundry_scripts_path);
    let output = DeployPaymasterOutput::read(shell, output_path)?;
    Ok(output.paymaster)
}

fn register_on_all_chains_step(
    shell: &Shell, runner: &mut ForgeRunner, forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path, auth: &SenderAuth, bridgehub: Address, chain_id: u64,
    l1_rpc_url: &str,
) -> anyhow::Result<()> {
    let calldata = REGISTER_ON_ALL_CHAINS_FUNCTIONS
        .encode("registerOnOtherChains", (bridgehub, U256::from(chain_id)))
        .map_err(|e| anyhow::anyhow!("Failed to encode register_on_all_chains calldata: {}", e))?;

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&REGISTER_ON_ALL_CHAINS_SCRIPT_PARAMS.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    runner.run(shell, forge)?;
    Ok(())
}

fn setup_legacy_bridge_step(
    shell: &Shell, runner: &mut ForgeRunner, forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path, auth: &SenderAuth, bridgehub: Address, chain_id: u64,
    l1_rpc_url: &str,
) -> anyhow::Result<()> {
    let calldata = SETUP_LEGACY_BRIDGE_FUNCTIONS
        .encode("run", (bridgehub, U256::from(chain_id)))
        .map_err(|e| anyhow::anyhow!("Failed to encode setup_legacy_bridge calldata: {}", e))?;

    let mut forge = Forge::new(foundry_scripts_path)
        .script(&SETUP_LEGACY_BRIDGE.script(), forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match auth {
        SenderAuth::PrivateKey(pk) => forge = forge.with_private_key(*pk),
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked()
        }
    }

    runner.run(shell, forge)?;
    Ok(())
}

// ── Internal structs ────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct ChainInitInput {
    pub ctm_proxy: Address,
    pub l1_da_validator: Address,
    pub chain_params: NewChainParams,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

#[derive(Debug, Clone, Default)]
pub struct FullChainInitOutput {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
    pub l2_default_upgrader: Option<Address>,
    pub consensus_registry_proxy: Option<Address>,
    pub multicall3: Option<Address>,
    pub timestamp_asserter: Option<Address>,
    pub paymaster_addr: Option<Address>,
}

impl FullChainInitOutput {
    fn from_register(output: &RegisterChainOutput) -> Self {
        Self {
            diamond_proxy_addr: output.diamond_proxy_addr,
            governance_addr: output.governance_addr,
            chain_admin_addr: output.chain_admin_addr,
            access_control_restriction_addr: output.access_control_restriction_addr,
            chain_proxy_admin_addr: output.chain_proxy_admin_addr,
            l2_legacy_shared_bridge_addr: output.l2_legacy_shared_bridge_addr,
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone)]
struct FullL2DeployOutput {
    l2_default_upgrader: Address,
    consensus_registry_proxy: Address,
    multicall3: Address,
    timestamp_asserter: Address,
}

#[derive(Debug, Deserialize, Clone)]
struct DeployPaymasterOutput {
    paymaster: Address,
}

impl FileConfigTrait for DeployPaymasterOutput {}

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ChainInitInputEcho {
    pub chain_id: u64,
    pub ctm_proxy: Address,
    pub bridgehub: Address,
    pub l1_da_validator: Address,
    pub owner: Address,
    pub base_token_addr: Address,
    pub da_mode: DAValidatorType,
    pub vm_type: VMOption,
    pub simulate: bool,
}

#[derive(Serialize)]
pub struct ChainInitL2Contracts {
    pub l2_default_upgrader: Address,
    pub consensus_registry_addr: Address,
    pub multicall3_addr: Address,
    pub timestamp_asserter_addr: Address,
}

#[derive(Serialize)]
pub struct ChainInitOutputData {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
    pub l2_contracts: Option<ChainInitL2Contracts>,
    pub paymaster_addr: Option<Address>,
}

impl ChainInitOutputData {
    pub fn from_full_output(output: &FullChainInitOutput) -> Self {
        let l2_contracts = match (
            output.l2_default_upgrader, output.consensus_registry_proxy,
            output.multicall3, output.timestamp_asserter,
        ) {
            (Some(upgrader), Some(consensus), Some(multicall3), Some(ts_asserter)) => {
                Some(ChainInitL2Contracts {
                    l2_default_upgrader: upgrader,
                    consensus_registry_addr: consensus,
                    multicall3_addr: multicall3,
                    timestamp_asserter_addr: ts_asserter,
                })
            }
            _ => None,
        };

        Self {
            diamond_proxy_addr: output.diamond_proxy_addr,
            governance_addr: output.governance_addr,
            chain_admin_addr: output.chain_admin_addr,
            access_control_restriction_addr: output.access_control_restriction_addr,
            chain_proxy_admin_addr: output.chain_proxy_admin_addr,
            l2_legacy_shared_bridge_addr: output.l2_legacy_shared_bridge_addr,
            l2_contracts,
            paymaster_addr: output.paymaster_addr,
        }
    }
}
