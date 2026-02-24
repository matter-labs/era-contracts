use std::path::{Path, PathBuf};

use clap::Parser;
use ethers::{
    contract::BaseContract,
    middleware::Middleware,
    signers::{LocalWallet, Signer},
    types::{Address, H256, U256},
    utils::hex,
};
use lazy_static::lazy_static;
use tokio::task::block_in_place;
use crate::common::{
    ethereum::get_ethers_provider,
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeContext, ForgeRunner, ForgeScriptArgs, SenderAuth},
    logger,
};
use crate::config::{
    forge_interface::{
        deploy_l2_contracts::output::{
            ConsensusRegistryOutput, DefaultL2UpgradeOutput,
            Multicall3Output, TimestampAsserterOutput,
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
    },
    traits::{FileConfigTrait, ReadConfig, SaveConfig},
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, VMOption};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::{
    IDEPLOYL2CONTRACTSABI_ABI, IDEPLOYPAYMASTERABI_ABI, IENABLEEVMEMULATORABI_ABI,
    IREGISTERONALLCHAINSABI_ABI, IREGISTERZKCHAINABI_ABI, ISETUPLEGACYBRIDGEABI_ABI,
};
use crate::admin_functions::{
    accept_admin, make_permanent_rollup, set_da_validator_pair, unpause_deposits, AdminScriptMode,
};
use crate::utils::paths;

lazy_static! {
    static ref REGISTER_CHAIN_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
    static ref DEPLOY_L2_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYL2CONTRACTSABI_ABI.clone());
    static ref DEPLOY_PAYMASTER_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYPAYMASTERABI_ABI.clone());
    static ref REGISTER_ON_ALL_CHAINS_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERONALLCHAINSABI_ABI.clone());
    static ref ENABLE_EVM_EMULATOR_FUNCTIONS: BaseContract = BaseContract::from(IENABLEEVMEMULATORABI_ABI.clone());
    static ref SETUP_LEGACY_BRIDGE_FUNCTIONS: BaseContract = BaseContract::from(ISETUPLEGACYBRIDGEABI_ABI.clone());
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainInitArgs {
    /// CTM (Chain Type Manager) proxy address
    #[clap(long)]
    pub ctm_proxy: Address,

    /// L1 DA validator address
    #[clap(long)]
    pub l1_da_validator: Address,

    /// Owner address for the chain (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    /// Commit operator address
    #[clap(long)]
    pub commit_operator: Address,

    /// Prove operator address
    #[clap(long)]
    pub prove_operator: Address,

    /// Execute operator address
    #[clap(long)]
    pub execute_operator: Option<Address>,

    /// Token multiplier setter address (default: zero address)
    #[clap(long)]
    pub token_multiplier_setter: Option<Address>,

    /// Chain ID
    #[clap(long)]
    pub chain_id: u64,

    /// Base token address (default: ETH = 0x0...01)
    #[clap(long, default_value = "0x0000000000000000000000000000000000000001")]
    pub base_token_addr: Address,

    /// Base token price ratio relative to ETH (numerator/denominator).
    /// Used to calculate fees for priority transactions.
    /// e.g. "4000/1" means 1 base token ~ 1/4000 ETH.
    #[clap(long, default_value = "1/1")]
    pub base_token_price_ratio: String,

    /// Data availability mode
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup)]
    pub da_mode: DAValidatorType,

    /// VM type (EraVM or ZKSyncOsVM)
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM)]
    pub vm_type: VMOption,

    /// Enable support for legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub with_legacy_bridge: bool,

    /// Governance address (for deploy_l2_contracts)
    #[clap(long)]
    pub governance_addr: Option<Address>,

    /// Keep deposits paused after init (default: false = unpause)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub pause_deposits: bool,

    /// Enable EVM emulator on the chain
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub evm_emulator: bool,

    /// Deploy testnet paymaster contract
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub deploy_paymaster: bool,

    /// Make the chain a permanent rollup (irreversible)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub make_permanent_rollup: bool,

    /// Skip L2 deployments via priority transactions
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true")]
    pub skip_priority_txs: bool,


    // Private keys
    /// Sender private key (for registration)
    #[clap(long, visible_alias = "pk")]
    pub private_key: Option<H256>,

    /// Sender address (for simulation)
    #[clap(long)]
    pub sender: Option<Address>,

    /// Owner private key (for accepting ownership)
    #[clap(long, alias = "owner-pk")]
    pub owner_private_key: Option<H256>,

    /// Bridgehub admin private key (for registering chain)
    #[clap(long, alias = "bridgehub-admin-pk")]
    pub bridgehub_admin_private_key: Option<H256>,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    #[clap(long, help = "Simulate against anvil fork (no on-chain changes)")]
    pub simulate: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,

    // Create2 factory options
    #[clap(long, help = "CREATE2 factory address (if already deployed)", help_heading = "CREATE2 options")]
    pub create2_factory_addr: Option<Address>,
    #[clap(long, help = "CREATE2 factory salt (random by default)", help_heading = "CREATE2 options")]
    pub create2_factory_salt: Option<H256>,

    // Output
    #[clap(long, help = "Write full JSON output to file", help_heading = "Output")]
    pub out: Option<PathBuf>,
}

/// Input parameters for chain initialization.
#[derive(Debug, Clone)]
pub struct ChainInitInput {
    pub ctm_proxy: Address,
    pub bridgehub: Address,
    pub l1_da_validator: Address,
    pub chain_params: NewChainParams,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

/// Accumulated output from the full chain init flow.
#[derive(Debug, Clone, Default)]
pub struct FullChainInitOutput {
    // From register_chain
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,

    // From deploy_l2_contracts
    pub l2_default_upgrader: Option<Address>,
    pub consensus_registry_proxy: Option<Address>,
    pub multicall3: Option<Address>,
    pub timestamp_asserter: Option<Address>,

    // From deploy_paymaster
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

/// Register a chain on the CTM.
pub fn register_chain(
    ctx: &mut ForgeContext,
    input: &ChainInitInput,
) -> anyhow::Result<RegisterChainOutput> {
    // Update permanent-values.toml so Forge scripts use the correct factory
    let salt = input.create2_factory_salt.unwrap_or(H256::zero());
    let permanent_values = PermanentValuesConfig::new(input.create2_factory_addr, salt);
    permanent_values.save(ctx.shell, PermanentValuesConfig::path(ctx.foundry_scripts_path))?;

    let deploy_config = RegisterChainL1Config::new(
        &input.chain_params,
        input.create2_factory_addr.unwrap_or(Address::zero()),
        input.create2_factory_salt,
        input.with_legacy_bridge,
    )?;

    // Write input config
    let input_path = REGISTER_CHAIN_SCRIPT_PARAMS.input(ctx.foundry_scripts_path);
    deploy_config.save(ctx.shell, input_path)?;

    // Encode calldata for run(ctm_proxy, chain_id)
    let calldata = REGISTER_CHAIN_FUNCTIONS
        .encode(
            "run",
            (input.ctm_proxy, input.chain_params.chain_id.as_u64()),
        )
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    // Build forge command
    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(&REGISTER_CHAIN_SCRIPT_PARAMS.script(), ctx.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(ctx.l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match ctx.auth {
        SenderAuth::PrivateKey(pk) => {
            forge = forge.with_private_key(*pk);
        }
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
        }
    }

    logger::info("Registering chain on CTM...");
    ctx.runner.run(ctx.shell, forge)?;

    // Read output
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
    // BRIDGE_HUB() selector = keccak256("BRIDGE_HUB()")[..4] = 0x5d4edca7
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

// ---- Helper functions for individual steps ----

/// Enable EVM emulator on the chain (via EnableEvmEmulator.s.sol).
fn enable_evm_emulator_step(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path,
    auth: &SenderAuth,
    chain_admin: Address,
    diamond_proxy: Address,
    l1_rpc_url: &str,
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

/// Deploy L2 contracts via priority transactions (DeployL2Contracts.sol).
#[allow(clippy::too_many_arguments)]
fn deploy_l2_contracts_step(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path,
    auth: &SenderAuth,
    bridgehub: Address,
    chain_id: u64,
    governance: Address,
    consensus_registry_owner: Address,
    da_mode: DAValidatorType,
    with_legacy_bridge: bool,
    l1_rpc_url: &str,
) -> anyhow::Result<FullL2DeployOutput> {
    // Encode calldata: run(bridgehub, chainId, governance, consensusRegistryOwner, daValidatorType)
    // or runWithLegacyBridge(...) if legacy bridge is enabled
    let function_name = if with_legacy_bridge {
        "runWithLegacyBridge"
    } else {
        "run"
    };
    let calldata = DEPLOY_L2_FUNCTIONS
        .encode(
            function_name,
            (
                bridgehub,
                U256::from(chain_id),
                governance,
                consensus_registry_owner,
                U256::from(da_mode.to_u8()),
            ),
        )
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

    // Read output - the script writes multiple output sections to the same file
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

/// Output from deploy_l2_contracts.
#[derive(Debug, Clone)]
struct FullL2DeployOutput {
    l2_default_upgrader: Address,
    consensus_registry_proxy: Address,
    multicall3: Address,
    timestamp_asserter: Address,
}

/// Output from deploy paymaster script.
#[derive(Debug, Deserialize, Clone)]
struct DeployPaymasterOutput {
    paymaster: Address,
}

impl FileConfigTrait for DeployPaymasterOutput {}

/// Deploy testnet paymaster contract (DeployPaymaster.s.sol).
fn deploy_paymaster_step(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path,
    auth: &SenderAuth,
    bridgehub: Address,
    chain_id: u64,
    l1_rpc_url: &str,
) -> anyhow::Result<Address> {
    // Encode calldata: run(bridgehub, chainId)
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

    // Read output
    let output_path = DEPLOY_PAYMASTER_SCRIPT_PARAMS.output(foundry_scripts_path);
    let output = DeployPaymasterOutput::read(shell, output_path)?;
    Ok(output.paymaster)
}

/// Register chain on all other chains (RegisterOnAllChains.s.sol).
fn register_on_all_chains_step(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path,
    auth: &SenderAuth,
    bridgehub: Address,
    chain_id: u64,
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

/// Setup legacy bridge (SetupLegacyBridge.s.sol).
fn setup_legacy_bridge_step(
    shell: &Shell,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    foundry_scripts_path: &Path,
    auth: &SenderAuth,
    bridgehub: Address,
    chain_id: u64,
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

// ---- Main run function ----

pub async fn run(args: ChainInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (price_ratio_num, price_ratio_den) = parse_ratio(&args.base_token_price_ratio)?;

    let chain_id = args.chain_id;
    let commit_operator = args.commit_operator;
    let prove_operator = args.prove_operator;
    let execute_operator = args.execute_operator;
    let token_multiplier_setter = args.token_multiplier_setter;

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));

    // Resolve owner auth for accept_admin step
    let owner_auth = if let Some(owner_pk) = args.owner_private_key {
        let local_wallet = LocalWallet::from_bytes(owner_pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid owner private key: {}", e))?;
        if local_wallet.address() != owner {
            anyhow::bail!(
                "Owner private key does not match owner address: got {:#x}, want {:#x}",
                local_wallet.address(),
                owner
            );
        }
        SenderAuth::PrivateKey(owner_pk)
    } else if owner == sender {
        sender_auth.clone()
    } else if is_simulation {
        // In simulation mode, all addresses are unlocked
        SenderAuth::Unlocked(owner)
    } else {
        anyhow::bail!(
            "Owner ({:#x}) differs from sender ({:#x}), --owner-private-key is required",
            owner,
            sender
        );
    };

    // Resolve bridgehub admin auth for registration step
    let bridgehub_admin_auth = if let Some(admin_pk) = args.bridgehub_admin_private_key {
        let local_wallet = LocalWallet::from_bytes(admin_pk.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid bridgehub admin private key: {}", e))?;
        logger::info(format!(
            "Bridgehub admin (for chain registration): {:#x}",
            local_wallet.address()
        ));
        SenderAuth::PrivateKey(admin_pk)
    } else {
        // Default to sender auth
        sender_auth.clone()
    };

    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);

    // Derive bridgehub address from CTM proxy
    logger::info(format!("Querying bridgehub from CTM proxy {:#x}...", args.ctm_proxy));
    let bridgehub = query_bridgehub(effective_rpc, args.ctm_proxy)?;
    logger::info(format!("Bridgehub: {:#x}", bridgehub));

    let mut runner = ForgeRunner::new();

    // Build chain params
    let chain_params = NewChainParams {
        chain_id: L2ChainId::from(chain_id as u32),
        base_token_addr: args.base_token_addr,
        base_token_gas_price_multiplier_numerator: price_ratio_num,
        base_token_gas_price_multiplier_denominator: price_ratio_den,
        owner,
        commit_operator,
        prove_operator,
        execute_operator,
        token_multiplier_setter,
        da_mode: args.da_mode,
    };

    let init_input = ChainInitInput {
        ctm_proxy: args.ctm_proxy,
        bridgehub,
        l1_da_validator: args.l1_da_validator,
        chain_params: chain_params.clone(),
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    // Register chain (as bridgehub admin)
    logger::info(format!("Initializing chain {} ...", chain_id));
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

    // Accept admin of chain (as owner)
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

    // Unpause deposits (unless pause_deposits is set, as owner)
    if !args.pause_deposits {
        logger::info("Unpausing deposits...");
        unpause_deposits(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            AdminScriptMode::Broadcast(owner_wallet.clone()),
            chain_id,
            bridgehub,
            effective_rpc.to_string(),
        )
        .await?;
    }

    // Set DA validator pair (as owner)
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
        chain_id,
        bridgehub,
        args.l1_da_validator,
        commitment_scheme,
        effective_rpc.to_string(),
    )
    .await?;

    // Enable EVM emulator (if requested, as owner)
    if args.evm_emulator {
        logger::info("Enabling EVM emulator...");
        enable_evm_emulator_step(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            &owner_auth,
            chain_admin,
            diamond_proxy,
            effective_rpc,
        )?;
    }

    // Deploy L2 contracts (if not skipping priority txs)
    if !args.skip_priority_txs {
        let governance = args.governance_addr.unwrap_or(owner);

        logger::info("Deploying L2 contracts...");
        let l2_output = deploy_l2_contracts_step(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            &sender_auth,
            bridgehub,
            chain_id,
            governance,
            owner,
            args.da_mode,
            args.with_legacy_bridge,
            effective_rpc,
        )?;
        full_output.l2_default_upgrader = Some(l2_output.l2_default_upgrader);
        full_output.consensus_registry_proxy = Some(l2_output.consensus_registry_proxy);
        full_output.multicall3 = Some(l2_output.multicall3);
        full_output.timestamp_asserter = Some(l2_output.timestamp_asserter);

        // Deploy paymaster (if requested)
        if args.deploy_paymaster {
            logger::info("Deploying paymaster...");
            let paymaster_addr = deploy_paymaster_step(
                shell,
                &mut runner,
                &args.forge_args.script,
                foundry_scripts_path.as_path(),
                &sender_auth,
                bridgehub,
                chain_id,
                effective_rpc,
            )?;
            full_output.paymaster_addr = Some(paymaster_addr);
            logger::info(format!("Paymaster deployed at: {:#x}", paymaster_addr));
        }

        // Register on all chains
        logger::info("Registering chain on all other chains...");
        register_on_all_chains_step(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            &sender_auth,
            bridgehub,
            chain_id,
            effective_rpc,
        )?;
    }

    // Make permanent rollup (if requested, as owner)
    if args.make_permanent_rollup {
        logger::info("Making chain a permanent rollup...");
        make_permanent_rollup(
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
    }

    // Setup legacy bridge (if requested)
    if args.with_legacy_bridge && !args.skip_priority_txs {
        logger::info("Setting up legacy bridge...");
        setup_legacy_bridge_step(
            shell,
            &mut runner,
            &args.forge_args.script,
            foundry_scripts_path.as_path(),
            &sender_auth,
            bridgehub,
            chain_id,
            effective_rpc,
        )?;
    }

    if let Some(out_path) = &args.out {
        let result = build_output(&init_input, &full_output, &runner);
        let result_json = serde_json::to_string_pretty(&result)?;
        std::fs::write(out_path, &result_json)?;
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

fn build_output(
    input: &ChainInitInput,
    output: &FullChainInitOutput,
    runner: &ForgeRunner,
) -> serde_json::Value {
    let runs: Vec<_> = runner.runs().iter().map(|r| json!({
        "script": r.script.display().to_string(),
        "run": r.payload,
    })).collect();

    let mut l2_contracts = serde_json::Value::Null;
    if let (Some(upgrader), Some(consensus), Some(multicall3), Some(ts_asserter)) = (
        output.l2_default_upgrader,
        output.consensus_registry_proxy,
        output.multicall3,
        output.timestamp_asserter,
    ) {
        l2_contracts = json!({
            "l2_default_upgrader": format!("{:#x}", upgrader),
            "consensus_registry_addr": format!("{:#x}", consensus),
            "multicall3_addr": format!("{:#x}", multicall3),
            "timestamp_asserter_addr": format!("{:#x}", ts_asserter),
        });
    }

    json!({
        "command": "chain.init",
        "runs": runs,
        "input": {
            "chain_id": input.chain_params.chain_id.as_u64(),
            "ctm_proxy": format!("{:#x}", input.ctm_proxy),
            "bridgehub": format!("{:#x}", input.bridgehub),
            "l1_da_validator": format!("{:#x}", input.l1_da_validator),
            "owner": format!("{:#x}", input.chain_params.owner),
            "base_token_addr": format!("{:#x}", input.chain_params.base_token_addr),
            "da_mode": format!("{:?}", input.chain_params.da_mode),
        },
        "output": {
            "diamond_proxy_addr": format!("{:#x}", output.diamond_proxy_addr),
            "governance_addr": format!("{:#x}", output.governance_addr),
            "chain_admin_addr": format!("{:#x}", output.chain_admin_addr),
            "access_control_restriction_addr": format!("{:#x}", output.access_control_restriction_addr),
            "chain_proxy_admin_addr": format!("{:#x}", output.chain_proxy_admin_addr),
            "l2_legacy_shared_bridge_addr": output.l2_legacy_shared_bridge_addr.map(|a| format!("{:#x}", a)),
            "l2_contracts": l2_contracts,
            "paymaster_addr": output.paymaster_addr.map(|a| format!("{:#x}", a)),
        },
    })
}
