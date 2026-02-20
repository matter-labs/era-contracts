use std::path::PathBuf;

use clap::Parser;
use ethers::{
    contract::BaseContract,
    middleware::Middleware,
    signers::{LocalWallet, Signer},
    types::{Address, H256},
    utils::hex,
};
use lazy_static::lazy_static;
use tokio::task::block_in_place;
use crate::common::{
    ethereum::get_ethers_provider,
    forge::{resolve_execution, ExecutionMode, Forge, ForgeArgs, ForgeContext, ForgeRunner, SenderAuth},
    logger,
};
use crate::config::{
    forge_interface::{
        register_chain::{
            input::{NewChainParams, RegisterChainL1Config},
            output::RegisterChainOutput,
        },
        script_params::REGISTER_CHAIN_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, VMOption};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::IREGISTERZKCHAINABI_ABI;
use crate::admin_functions::{accept_admin, set_da_validator_pair, AdminScriptMode};
use crate::utils::paths;

lazy_static! {
    static ref REGISTER_CHAIN_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
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
    #[clap(long, default_value_t = false)]
    pub with_legacy_bridge: bool,

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
}

/// Output from chain registration.
#[derive(Debug, Clone)]
pub struct ChainInitOutput {
    pub diamond_proxy: Address,
    pub chain_admin: Address,
}

/// Register a chain on the CTM.
pub fn register_chain(
    ctx: &mut ForgeContext,
    input: &ChainInitInput,
) -> anyhow::Result<RegisterChainOutput> {
    let deploy_config = RegisterChainL1Config::new(
        &input.chain_params,
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

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
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
    };

    // Step 1: Register chain (as bridgehub admin)
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
    logger::info(format!("Chain registered. Diamond proxy: {:#x}", diamond_proxy));

    // Step 2: Accept admin of chain (as owner)
    logger::info("Accepting admin of chain...");
    let owner_wallet = owner_auth.to_wallet()?;
    {
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
    }

    // Step 3: Set DA validator pair (as owner)
    logger::info("Setting DA validator pair...");
    let commitment_scheme = match args.da_mode {
        DAValidatorType::Rollup => match args.vm_type {
            VMOption::EraVM => L2DACommitmentScheme::BlobsAndPubdataKeccak256,
            VMOption::ZKSyncOsVM => L2DACommitmentScheme::BlobsZKSyncOS,
        },
        DAValidatorType::Avail | DAValidatorType::Eigen => L2DACommitmentScheme::PubdataKeccak256,
        DAValidatorType::NoDA => L2DACommitmentScheme::EmptyNoDA,
    };

    {
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
    }

    if let Some(out_path) = &args.out {
        let result = build_output(&init_input, &register_output, &runner);
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
    output: &RegisterChainOutput,
    runner: &ForgeRunner,
) -> serde_json::Value {
    let runs: Vec<_> = runner.runs().iter().map(|r| json!({
        "script": r.script.display().to_string(),
        "run": r.payload,
    })).collect();

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
            "chain_admin_addr": format!("{:#x}", output.chain_admin_addr),
        },
    })
}
