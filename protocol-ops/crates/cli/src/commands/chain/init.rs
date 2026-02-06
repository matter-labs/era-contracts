use clap::Parser;
use ethers::{
    contract::BaseContract,
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use lazy_static::lazy_static;
use protocol_ops_common::{
    forge::{Forge, ForgeArgs, ForgeRunner},
    logger,
};
use protocol_ops_config::{
    forge_interface::{
        register_chain::{
            input::{NewChainParams, RegisterChainL1Config},
            output::RegisterChainOutput,
        },
        script_params::REGISTER_CHAIN_SCRIPT_PARAMS,
    },
    traits::{ReadConfig, SaveConfig},
};
use protocol_ops_types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, VMOption};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::abi::IREGISTERZKCHAINABI_ABI;
use crate::admin_functions::{accept_admin, set_da_validator_pair, AdminScriptMode};
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext, SenderAuth};
use crate::utils::paths;

lazy_static! {
    static ref REGISTER_CHAIN_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERZKCHAINABI_ABI.clone());
}

/// Default values for dev mode
const DEV_CHAIN_ID: u64 = 271;
const DEV_OPERATOR: &str = "0x0000000000000000000000000000000000000000";

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainInitArgs {
    /// CTM (Chain Type Manager) proxy address
    #[clap(long)]
    pub ctm_proxy: Address,

    /// Bridgehub proxy address
    #[clap(long)]
    pub bridgehub: Address,

    /// L1 rollup DA validator address
    #[clap(long)]
    pub rollup_da_validator: Address,

    /// L1 no-DA validium validator address
    #[clap(long)]
    pub no_da_validium_validator: Address,

    /// Owner address for the chain (default: sender)
    #[clap(long)]
    pub owner: Option<Address>,

    /// Commit operator address
    #[clap(long)]
    pub commit_operator: Option<Address>,

    /// Prove operator address
    #[clap(long)]
    pub prove_operator: Option<Address>,

    /// Execute operator address
    #[clap(long)]
    pub execute_operator: Option<Address>,

    /// Token multiplier setter address (default: zero address)
    #[clap(long)]
    pub token_multiplier_setter: Option<Address>,

    /// Chain ID
    #[clap(long)]
    pub chain_id: Option<u64>,

    /// Base token address (default: ETH = 0x0...01)
    #[clap(long, default_value = "0x0000000000000000000000000000000000000001")]
    pub base_token_addr: Address,

    /// Base token gas price multiplier numerator
    #[clap(long, default_value_t = 1)]
    pub base_token_gas_price_multiplier_numerator: u64,

    /// Base token gas price multiplier denominator
    #[clap(long, default_value_t = 1)]
    pub base_token_gas_price_multiplier_denominator: u64,

    /// Data availability mode
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup)]
    pub da_mode: DAValidatorType,

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

    // Dev options
    #[clap(long, help = "Use dev defaults", default_value_t = false, help_heading = "Dev options")]
    pub dev: bool,
}

/// Input parameters for chain initialization.
#[derive(Debug, Clone)]
pub struct ChainInitInput {
    pub ctm_proxy: Address,
    pub bridgehub: Address,
    pub rollup_da_validator: Address,
    pub no_da_validium_validator: Address,
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
        Address::zero(), // create2_factory_addr - will use default
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

pub async fn run(args: ChainInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    // Resolve chain_id
    let chain_id = if let Some(id) = args.chain_id {
        id
    } else if args.dev {
        DEV_CHAIN_ID
    } else {
        anyhow::bail!("--chain-id is required (or use --dev for default)");
    };

    // Resolve operators
    let zero_addr = Address::zero();
    let dev_operator = DEV_OPERATOR.parse::<Address>().unwrap();

    let commit_operator = args.commit_operator.unwrap_or_else(|| {
        if args.dev { dev_operator } else { zero_addr }
    });
    let prove_operator = args.prove_operator.unwrap_or_else(|| {
        if args.dev { dev_operator } else { zero_addr }
    });
    let execute_operator = args.execute_operator;
    let token_multiplier_setter = args.token_multiplier_setter;

    // Validate operators unless dev mode
    if !args.dev {
        if commit_operator == zero_addr {
            anyhow::bail!("--commit-operator is required (or use --dev for default)");
        }
        if prove_operator == zero_addr {
            anyhow::bail!("--prove-operator is required (or use --dev for default)");
        }
    }

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.dev, args.simulate, &args.l1_rpc_url)?;
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

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    // Build chain params
    let chain_params = NewChainParams {
        chain_id: L2ChainId::from(chain_id as u32),
        base_token_addr: args.base_token_addr,
        base_token_gas_price_multiplier_numerator: args.base_token_gas_price_multiplier_numerator,
        base_token_gas_price_multiplier_denominator: args.base_token_gas_price_multiplier_denominator,
        owner,
        commit_operator,
        prove_operator: prove_operator,
        execute_operator,
        token_multiplier_setter,
        da_mode: args.da_mode,
    };

    let init_input = ChainInitInput {
        ctm_proxy: args.ctm_proxy,
        bridgehub: args.bridgehub,
        rollup_da_validator: args.rollup_da_validator,
        no_da_validium_validator: args.no_da_validium_validator,
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
    let l1_da_validator = match args.da_mode {
        DAValidatorType::Rollup => args.rollup_da_validator,
        DAValidatorType::NoDA => args.no_da_validium_validator,
        DAValidatorType::Avail => args.no_da_validium_validator, // TODO: separate avail validator
        DAValidatorType::Eigen => args.no_da_validium_validator,
    };

    let commitment_scheme = match args.da_mode {
        DAValidatorType::Rollup => L2DACommitmentScheme::BlobsZKSyncOS, // Assuming ZKSyncOS
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
            args.bridgehub,
            l1_da_validator,
            commitment_scheme,
            effective_rpc.to_string(),
        )
        .await?;
    }

    // Build and output plan
    let plan = build_plan(&init_input, &register_output, &runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    if is_simulation {
        logger::outro("Chain init simulation complete (no on-chain changes)");
    } else {
        logger::outro("Chain initialized");
    }

    drop(execution_mode);

    Ok(())
}

fn build_plan(
    input: &ChainInitInput,
    output: &RegisterChainOutput,
    runner: &ForgeRunner,
) -> serde_json::Value {
    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "chain.init",
        "transactions": transactions,
        "input": {
            "chain_id": input.chain_params.chain_id.as_u64(),
            "ctm_proxy": format!("{:#x}", input.ctm_proxy),
            "bridgehub": format!("{:#x}", input.bridgehub),
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
